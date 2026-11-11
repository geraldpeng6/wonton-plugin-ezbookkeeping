# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 变量别叫 state：shellcheck 把这份文件连着 probes.sh 一起分析，probes.sh 自己也读一个 dev.sh 提供的 state；
# 子壳体函数（fn() ( … )）里给 state 赋值，SC2031 就报在 probes.sh 上，CI 红。
#
# 变量：两套冒烟环境（dev.sh smoke、正式 e2e 套件）都给的只有 SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、
#       SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE 和 web_get、dweb。SMOKE_WEB_URL 的含义两边不同
#       （dev.sh smoke 是带路径的网页入口，正式套件剥成只有 origin），拼 API 和读核心接口都用 _ebk_origin
#       现场取的 origin；插件 id 硬编码在下面（正式套件的钩子约定里没有 SMOKE_PLUGIN_ID，读主人初始密码的
#       核心接口要用它），不依赖 SMOKE_WEB_ORIGIN/SMOKE_PLUGIN_ID。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 只证明身份：用应用自己的"当前用户"接口断言认出的是用户管理员，不碰应用里的数据。
# 数据断言（有几条、内容对不对）全部交给 data_write / data_check：data_write 用随机标记写数据并把标记
# 存进 SMOKE_STATE，data_check 读回标记去应用里找，对不上就打印看到了什么并返回非 0。
# 工具：mcp_check 断言总线上有本插件的工具并真调一次（两套环境各自的 MCP 变量见函数内说明）。
#
# 登录是这个插件自己的（sso: none）：主人账号装好时预建（用户名=云吞用户名），初始密码由核心生成、
# show_owner，探针经核心 API 读取（这条读会被核心审计），再走应用自己的 authorize.json 登录取用户令牌。
# 登录失败会计入应用的每 IP 限速（默认 5 次/分钟），所以一轮里只登录一次，令牌在同一轮探针里复用，失败不重试。
# shellcheck disable=SC2034  # SSO/MCP 由冒烟套件读取
SSO=none
MCP=1

EBK_ID="net.mayswind.ezbookkeeping"
EBK_TOKEN=""

_ebk_origin() { # SMOKE_WEB_URL 两边含义不同（一个带入口路径、一个只有 origin），拼 API 前取 origin
  local u="${SMOKE_WEB_URL%%\?*}" rest="${SMOKE_WEB_URL#*://}"
  printf '%s://%s' "${u%%://*}" "${rest%%/*}"
}

_ebk_core_session() { # 主人令牌登进核心会话，再走一遍插件域名的会话交接（APP Cookie 落进同一个 jar）
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_BASE:-}" && -n "${SMOKE_TOKEN:-}" && -n "${SMOKE_WEB_URL:-}" ]] ||
    { echo "缺冒烟变量：SMOKE_JAR/SMOKE_BASE/SMOKE_TOKEN/SMOKE_WEB_URL" >&2; return 1; }
  # -b 保留 jar 里已有的会话（只写 -c 会把别的域的会话抹掉）
  curl -sS --noproxy '*' --max-time 120 -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    --data-urlencode "token=${SMOKE_TOKEN}" "${SMOKE_BASE}/_wonton/login" ||
    { echo "主人令牌登不进核心会话" >&2; return 1; }
  # 插件网页在核心会话之外：未登录的页面请求跳核心 /_wonton/sso，跟完交接在插件域名种上应用会话
  curl -sS --noproxy '*' --max-time 120 -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "$(_ebk_origin)/" ||
    { echo "走不通插件网页的会话交接" >&2; return 1; }
}

_ebk_password() { # 主人的初始密码（核心 API 的响应是 {"value":"…"}）
  local v
  _ebk_core_session || return 1
  v="$(curl -sS --noproxy '*' --max-time 120 --fail-with-body -b "$SMOKE_JAR" -H "Authorization: Bearer ${SMOKE_TOKEN}" \
    "${SMOKE_BASE}/_wonton/api/plugins/${EBK_ID}/secrets/owner_password")" ||
    { echo "核心里读不到主人初始密码（secrets.owner_password）" >&2; return 1; }
  v="$(jq -r '.value // empty' <<<"$v")"
  [[ -n "$v" ]] || { echo "核心没给初始密码的值" >&2; return 1; }
  printf '%s' "$v"
}

_ebk_login() { # <用户名> <密码>：成功输出应用的用户令牌
  local resp
  [[ -n "${SMOKE_WEB_URL:-}" ]] || { echo "缺冒烟变量：SMOKE_WEB_URL" >&2; return 1; }
  resp="$(curl -sS --noproxy '*' --max-time 120 --fail-with-body -b "${SMOKE_JAR:-}" -X POST -H 'Content-Type: application/json' \
    -d "{\"loginName\":\"$1\",\"password\":\"$2\"}" "$(_ebk_origin)/api/authorize.json")" ||
    { echo "应用登录失败（账号 $1，用初始密码）" >&2; return 1; }
  printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

ebk_api() { # <方法> <路径> [JSON 正文]：用 $EBK_TOKEN 调应用接口，输出响应
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --noproxy '*' --max-time 120 -b "${SMOKE_JAR:-}" -X "$method" \
    -H "Authorization: Bearer $EBK_TOKEN" -H 'X-Timezone-Offset: 480')
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "$(_ebk_origin)$path"
}

_ebk_token() { # 一轮探针共用一个登录态
  local pw
  if [[ -z "$EBK_TOKEN" ]]; then
    pw="$(_ebk_password)" || return 1
    EBK_TOKEN="$(_ebk_login "${SMOKE_OWNER:-owner}" "$pw")" || return 1
  fi
  printf '%s' "$EBK_TOKEN"
}

web_assert() { # 登录页就是应用自己的（SPA 外壳，标题写死 ezBookkeeping）
  grep -qi '<title>[^<]*ezBookkeeping'
}

identity_check() {
  local resp
  _ebk_token >/dev/null || { echo "拿不到应用登录态（读初始密码或登录失败）"; return 1; }
  resp="$(ebk_api GET /api/v1/users/profile/get.json)" || { echo "取不到当前用户"; return 1; }
  jq -e --arg owner "${SMOKE_OWNER:-owner}" '.success == true and .result.username == $owner' <<<"$resp" >/dev/null ||
    { echo "认出的不是管理员：$(head -c 160 <<<"$resp")"; return 1; }
}

_ebk_marker_file() { # SMOKE_STATE 在套件里可能是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "${SMOKE_STATE:-}" ]]; then printf '%s' "$SMOKE_STATE/ezbookkeeping-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

data_write() { # 现金账户 + 支出主分类和子分类 + 一笔带随机标记的支出，标记存进 SMOKE_STATE
  # 上游规定交易只能挂子分类（pkg/services/transactions.go isCategoryValid：主分类拒收），所以建两级
  local marker acc cat sub resp
  _ebk_token >/dev/null || { echo "拿不到应用登录态，写不了数据"; return 1; }
  marker="保数据-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"

  resp="$(ebk_api POST /api/v1/accounts/add.json \
    '{"name":"现金","category":1,"type":1,"icon":"1","iconType":0,"color":"4285f4","currency":"CNY","balance":"0"}')" ||
    { echo "建账户失败：$(head -c 160 <<<"$resp")"; return 1; }
  acc="$(jq -r '.result.id // empty' <<<"$resp")"
  [[ -n "$acc" && "$acc" != null ]] || { echo "建账户的响应里没有账户：$(head -c 160 <<<"$resp")"; return 1; }

  resp="$(ebk_api POST /api/v1/transaction/categories/add.json \
    '{"name":"餐饮","type":2,"icon":"1","iconType":0,"color":"4285f4"}')" ||
    { echo "建主分类失败：$(head -c 160 <<<"$resp")"; return 1; }
  cat="$(jq -r '.result.id // empty' <<<"$resp")"
  [[ -n "$cat" && "$cat" != null ]] || { echo "建主分类的响应里没有分类：$(head -c 160 <<<"$resp")"; return 1; }

  resp="$(ebk_api POST /api/v1/transaction/categories/add.json \
    "{\"name\":\"买菜\",\"type\":2,\"parentId\":\"$cat\",\"icon\":\"1\",\"iconType\":0,\"color\":\"4285f4\"}")" ||
    { echo "建子分类失败：$(head -c 160 <<<"$resp")"; return 1; }
  sub="$(jq -r '.result.id // empty' <<<"$resp")"
  [[ -n "$sub" && "$sub" != null ]] || { echo "建子分类的响应里没有分类：$(head -c 160 <<<"$resp")"; return 1; }

  resp="$(ebk_api POST /api/v1/transactions/add.json "{\"type\":3,\"time\":$(date +%s),\
\"sourceAccountId\":\"$acc\",\"sourceAmount\":2345,\"categoryId\":\"$sub\",\"comment\":\"$marker\"}")" ||
    { echo "记账失败：$(head -c 160 <<<"$resp")"; return 1; }
  jq -e --arg m "$marker" '.success == true and .result.comment == $m' <<<"$resp" >/dev/null ||
    { echo "记账没有成功：$(head -c 160 <<<"$resp")"; return 1; }
  jq -nc --arg m "$marker" --arg a "$acc" '{marker:$m,account_id:$a}' >"$(_ebk_marker_file)"
}

data_check() { # 按标记把那笔账搜出来
  local marker resp
  marker="$(jq -r .marker "$(_ebk_marker_file)")"
  _ebk_token >/dev/null || { echo "拿不到应用登录态，查不了数据"; return 1; }
  resp="$(ebk_api GET "/api/v1/transactions/list.json?keyword=$marker&count=20&with_count=true")" ||
    { echo "查交易失败：$(head -c 160 <<<"$resp")"; return 1; }
  jq -e --arg m "$marker" '.success == true and ([.result.items[].comment] | index($m) != null)' <<<"$resp" >/dev/null ||
    { echo "找不到写进去的那笔账（标记 $marker）：$(head -c 200 <<<"$resp")"; return 1; }
}

mcp_check() { # 总线上有本插件的工具,并真调一次:总线的工具调用先发确认卡,探针替主人批准(用核心 API)
  # 两套环境的变量:dev.sh smoke 给 SMOKE_MCP_URL/SMOKE_SLUG,正式套件给 E2E_MCP_URL/E2E_SLUG,mcp 助手两边都有
  local url="${E2E_MCP_URL:-${SMOKE_MCP_URL:-}}" slug="${E2E_SLUG:-${SMOKE_SLUG:-}}"
  local tools tool out err pid approved="" i cards id reply
  [[ -n "$url" && -n "$slug" ]] || { echo "缺 MCP 冒烟变量(MCP_URL/SLUG)" >&2; return 1; }
  [[ -n "${SMOKE_BASE:-}" && -n "${SMOKE_TOKEN:-}" ]] ||
    { echo "缺冒烟变量:SMOKE_BASE/SMOKE_TOKEN" >&2; return 1; }
  tools="$(mcp list "$url")" || { echo "tools/list 失败"; return 1; }
  tool="${slug}__query_all_accounts"
  jq -e --arg t "$tool" 'any(.[]; .name == $t)' <<<"$tools" >/dev/null ||
    { echo "tools/list 没有 $tool:$(head -c 200 <<<"$tools")"; return 1; }
  # 上游的 MCP 服务不实现工具注解,读工具标不了 readOnlyHint,总线每次调用都发确认卡等批准;
  # 上游能力缺口,在 README 和 PR 里写明。这里后台发起调用,轮询确认卡替主人批准,再收结果。
  out="$(mktemp)"; err="$(mktemp)"
  mcp call "$url" "$tool" '{}' >"$out" 2>"$err" &
  pid=$!
  for ((i = 0; i < 60; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    if [[ -z "$approved" ]] &&
      cards="$(curl -sS --noproxy '*' --max-time 10 -H "Authorization: Bearer ${SMOKE_TOKEN}" \
        "${SMOKE_BASE}/_wonton/api/confirmations" 2>/dev/null)" &&
      [[ "$(jq -r '.confirmations | length' <<<"$cards" 2>/dev/null)" != 0 ]]; then
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if reply="$(curl -sS --noproxy '*' --max-time 10 -X POST \
          -H "Authorization: Bearer ${SMOKE_TOKEN}" -H 'Content-Type: application/json' \
          -d '{"answer":"approve"}' "${SMOKE_BASE}/_wonton/confirmations/$id")" &&
          grep -q '"success":true' <<<"$reply"; then
          approved=1
          jq -r --arg id "$id" '.confirmations[] | select(.id == $id) | "已替主人批准:\(.title)"' <<<"$cards"
        else
          echo "批准卡片 $id 没成功:$(head -c 120 <<<"$reply")" >&2
        fi
      done < <(jq -r '.confirmations[].id' <<<"$cards" 2>/dev/null)
    fi
    sleep 1
  done
  wait "$pid" || { echo "调用 $tool 失败:$(head -c 200 "$err")"; rm -f "$out" "$err"; return 1; }
  out="$(cat "$out")"; rm -f "$err"
  jq -e '.content | length > 0' <<<"$out" >/dev/null ||
    { echo "$tool 的结果没有内容:$out"; return 1; }
}
