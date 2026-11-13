# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 变量别叫 state：shellcheck 把这份文件连着 probes.sh 一起分析，probes.sh 自己也读一个 dev.sh 提供的 state；
# 子壳体函数（fn() ( … )）里给 state 赋值，SC2031 就报在 probes.sh 上，CI 红。
#
# 变量：SMOKE_WEB_URL 是应用的网页入口（套件已去尾斜杠，但可能带路径，比如 SSO 登录页）；
#       拼 API 路径用 SMOKE_WEB_ORIGIN（只有 scheme://host:port，入口的路径不掺进来），别直接接在 SMOKE_WEB_URL 后面。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 只证明身份：用应用自己的"当前用户"接口断言认出的是用户管理员，不碰应用里的数据。
#       数据断言（是否配置过、有几条、内容对不对）全部交给 data_write / data_check：冒烟第 1 项会先装升级
#       起点写数据，身份探针再断言"数据目录是空的"就会红。接口回字段时也只看类型（如 configured 是布尔、
#       nodes 是数字），值和条数留给 data_check。
#       没有用户体系时写 IDENTITY_NA=1，并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
#       SSO 登录跳转不用自己写表单逻辑：dweb --sso 会从清单 webui.path 的入口出发（没写就是 /），提交核心
#       登录页的 JS 自动表单并跟完重定向，返回的页面已带应用的登录态。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 通知房间：申请了 notify 的插件把通知交给核心，核心以核心账号发进和主人的"Wonton"私聊。
# 数据：合并前要验证"升级/重装不丢用户数据"时写 data_write 和 data_check（两个都写才跑）：data_write 用随机标记写
#       一条数据并把标记原样存进 $SMOKE_STATE，data_check 读回标记去应用里找，对不上就打印看到了什么并返回非 0。
#       应用不存用户数据时写 DATA_NA=1（两项记 N/A）。
# 装之前要准备（如先配出口代理）：写 before_install。
# 设置：清单有 settings 时，冒烟装插件要填的值写 export SMOKE_SETTINGS=(名字=值 …)（如要用户同意许可的必填项），
#       不写进 Schema 的 default；临时多给几项用 scripts/dev.sh smoke --setting 名字=值。
# 探针自己起的容器（如一次性的对端服务）加上标签 wonton.instance=$SMOKE_INSTANCE，冒烟结束时随实例一起删掉。

# ezbookkeeping 的探针。sso=none：应用自己管登录（init 用核心生成的初始密码建号，初始密码在核心收存的
# 插件密钥里），探针读这份密码走应用自己的 authorize.json 建会话；init 建的是第一个账号，上游约定第一个
# 用户就是管理员，这里断言应用认出主人即可。
# 工具探针用只读的 query_all_accounts（无参）。应用数据是账本（SQLite），镜像升级不触数据层，升级/重装
# 保数据此前已由首版冒烟验证过，这里不写 data_write/data_check（两项记 N/A）。

EBK_ID="net.mayswind.ezbookkeeping"

ebk_owner_password() { # 核心收存的插件密钥（secrets/<插件id>.json）里有初始密码
  docker exec "wonton-$SMOKE_INSTANCE--core" cat "$SMOKE_DATA_DIR/plugins/secrets/$EBK_ID.json" 2>/dev/null |
    jq -r '(.values.owner_password // .owner_password // empty)'
}

ebk_token() { # 应用会话令牌：authorize.json，字段是 loginName（不是 username）
  local password resp
  password="$(ebk_owner_password)"
  [[ -n "$password" ]] || { echo "核心收存的插件密钥里没有 owner_password"; return 1; }
  resp="$(curl_t "$SMOKE_API_MAX_TIME" "$SMOKE_WEB_ORIGIN/api/authorize.json" --noproxy '*' \
    -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg u "$SMOKE_OWNER" --arg p "$password" '{loginName:$u,password:$p}')")" ||
    { echo "authorize.json 传输失败"; return 1; }
  jq -r '(.token // .result.token // empty)' <<<"$resp"
}

web_assert() { # 未登录时应用照常给出自己的登录页
  grep -qi 'ezbookkeeping'
}

identity_check() { # 应用自己的"当前用户"接口：认出的是主人（init 建的第一个账号，即管理员）
  local token me
  token="$(ebk_token)" || return 1
  [[ -n "$token" ]] || { echo "登录响应里没有令牌"; return 1; }
  me="$(curl_t "$SMOKE_API_MAX_TIME" "$SMOKE_WEB_ORIGIN/api/v1/users/profile/get.json" --noproxy '*' \
    -H "Authorization: Bearer $token")" || { echo "profile/get.json 传输失败"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" \
    '(.user.username // .result.user.username // .username // .result.username) == $u' <<<"$me" >/dev/null ||
    { echo "应用没认出用户 $SMOKE_OWNER：$(head -c 200 <<<"$me")"; return 1; }
}

# shellcheck disable=SC2034 # probes.sh 按名字读
MCP_TOOL="net.mayswind.ezbookkeeping__query_all_accounts"
# shellcheck disable=SC2034 # probes.sh 按名字读
MCP_ARGS='{}'

mcp_assert() { # 只读工具：应答不是错误就算通（新装实例账本为空是正常状态）
  local out
  out="$(cat)"
  [[ -n "$out" ]] || { echo "工具调用没有应答"; return 1; }
  jq -e '(.isError // false) == false' <<<"$out" >/dev/null ||
    { echo "工具应答报错：$(head -c 200 <<<"$out")"; return 1; }
}
