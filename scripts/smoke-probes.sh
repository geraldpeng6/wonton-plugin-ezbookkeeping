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

# ezbookkeeping 的探针。sso=none：应用自己管登录（init 用核心生成的初始密码建号），探针不重复登录链，
# 直接用 init 签发、核心收存的应用级用户令牌（mcp_token）调应用 API——它就是主人的用户令牌；
# init 建的是第一个账号，上游约定第一个用户就是管理员，这里断言应用认出主人即可。
# 工具探针用只读的 query_all_accounts（总线里的名字按插件 slug 用横线）。数据探针走应用 API 建一个
# 分类、账户和一笔带标记的支出，升级/重装后按 id 读回对标记。

EBK_ID="net.mayswind.ezbookkeeping"

ebk_app_token() { # init 签发的应用级用户令牌（核心收存在同一份密钥 JSON 里，值是 base64；标准解码失败再试 URL-safe）
  docker exec "wonton-$SMOKE_INSTANCE--core" cat "$SMOKE_DATA_DIR/core/plugins/secrets/$EBK_ID.json" 2>/dev/null |
    jq -r '(.values.mcp_token // .mcp_token // empty)' |
    { read -r raw; printf '%s' "$raw" | base64 -d 2>/dev/null || printf '%s' "$raw" | base64 -d --urlsafe 2>/dev/null; }
}

ebk_api() { # 带应用用户令牌的应用 API：<方法> <路径> [JSON 正文]，正文原样输出
  local method="$1" path="$2" body="${3:-}"
  local token
  token="$(ebk_app_token)"
  [[ -n "$token" ]] || { echo "核心收存的插件密钥里没有 mcp_token" >&2; return 1; }
  local args=(-X "$method" -H "Authorization: Bearer $token")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl_t "$SMOKE_API_MAX_TIME" "$SMOKE_WEB_ORIGIN$path" --noproxy '*' "${args[@]}"
}

web_assert() { # 未登录时应用照常给出自己的登录页
  grep -qi 'ezbookkeeping'
}

identity_check() { # 应用自己的"当前用户"接口：认出的是主人（init 建的第一个账号，即管理员）
  local me
  me="$(ebk_api GET /api/v1/users/profile/get.json)" || return 1
  jq -e --arg u "$SMOKE_OWNER" \
    '(.user.username // .result.user.username // .username // .result.username) == $u' <<<"$me" >/dev/null ||
    { echo "应用没认出用户 $SMOKE_OWNER：$(head -c 200 <<<"$me")"; return 1; }
}

mcp_check() { # tools/list 里有本插件工具，再真实调用一次，按注解的有无断言对应的行为。
  # 上游 2.1.1（现钉镜像）的 MCP 实现没有工具注解（上游 2026-11-12 才在 master 加，还没发带注解的版本），
  # readOnlyHint 按缺失处理：核心会把没标只读的工具先请主人确认，冒烟环境没有已配对的设备，应不了确认，
  # 调用应答就是「没能请你确认」的报错——探针断言这个行为。等上游发了带注解的版本、升镜像后
  # readOnlyHint 会是 true，走只读直通断言（到时候收紧）。
  local tool="net-mayswind-ezbookkeeping__query_all_accounts" ann out
  jq -e --arg t "$tool" 'any(.[]; .name == $t)' "$SMOKE_TOOLS" >/dev/null ||
    { echo "tools/list 里没有 $tool" >&2; return 1; }
  ann="$(jq -r --arg t "$tool" '.[] | select(.name == $t) | (.annotations.readOnlyHint // "missing")' "$SMOKE_TOOLS")"
  echo "readOnlyHint=$ann"
  # isError 时 mcp call 退出非 0、原因在标准错误，要合并着接。
  if out="$(mcp call "$SMOKE_MCP_URL" "$tool" '{}' 2>&1)"; then
    [[ -n "$out" ]] || { echo "工具调用没有应答" >&2; return 1; }
    if [[ "$ann" == true ]]; then
      echo "只读直通，应答：$(head -c 200 <<<"$out")"
    else
      echo "没标只读的工具没走确认就执行了，应答：$(head -c 200 <<<"$out")" >&2
      return 1
    fi
  else
    if [[ "$ann" == true ]]; then
      echo "只读工具应直接执行，实际失败：$(head -c 200 <<<"$out")" >&2
      return 1
    fi
    grep -q "没能请你确认" <<<"$out" ||
      { echo "没标只读的工具应走主人确认，实际失败：$(head -c 200 <<<"$out")" >&2; return 1; }
    echo "确认路径符合预期：$(head -c 200 <<<"$out")"
  fi
}

data_write() { # 建分类、账户和一笔带随机标记的支出，把"标记 交易id"写进 $SMOKE_STATE
  local marker category_id account_id resp
  marker="wonton-smoke-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  resp="$(ebk_api POST /api/v1/transaction/categories/add.json \
    "$(jq -nc --arg n "$marker" '{name:$n,type:2,parentId:"0",icon:"1",color:"000000"}')")" || return 1
  category_id="$(jq -r '(.id // .result.id // .categoryId // .result.categoryId // empty) | tostring' <<<"$resp")"
  [[ -n "$category_id" && "$category_id" != null ]] || { echo "建分类没回 id：$(head -c 200 <<<"$resp")"; return 1; }
  resp="$(ebk_api POST /api/v1/accounts/add.json \
    "$(jq -nc --arg n "$marker" '{name:$n,category:1,type:1,icon:"1",color:"000000",currency:"CNY",balance:"0"}')")" || return 1
  account_id="$(jq -r '(.id // .result.id // .accountId // .result.accountId // empty) | tostring' <<<"$resp")"
  [[ -n "$account_id" && "$account_id" != null ]] || { echo "建账户没回 id：$(head -c 200 <<<"$resp")"; return 1; }
  resp="$(ebk_api POST /api/v1/transactions/add.json \
    "$(jq -nc --arg c "$category_id" --arg a "$account_id" --arg m "$marker" \
      '{type:3,categoryId:$c,time:(now*1000|floor),utcOffset:480,sourceAccountId:$a,sourceAmount:100,comment:$m}')")" || return 1
  local tx_id
  tx_id="$(jq -r '(.id // .result.id // .transactionId // .result.transactionId // empty) | tostring' <<<"$resp")"
  [[ -n "$tx_id" && "$tx_id" != null ]] || { echo "建交易没回 id：$(head -c 200 <<<"$resp")"; return 1; }
  printf '%s %s' "$marker" "$tx_id" >"$SMOKE_STATE"
}

data_check() { # 按 data_write 存的交易 id 读回，核对标记原样还在
  local marker tx_id me
  read -r marker tx_id <"$SMOKE_STATE"
  [[ -n "$marker" && -n "$tx_id" ]] || { echo "SMOKE_STATE 里没有标记和交易 id"; return 1; }
  me="$(ebk_api GET "/api/v1/transactions/get.json?id=$tx_id")" || return 1
  jq -e --arg m "$marker" '(.comment // .result.comment) == $m' <<<"$me" >/dev/null ||
    { echo "交易 $tx_id 的备注不是 $marker：$(head -c 200 <<<"$me")"; return 1; }
}
