# scripts/smoke.sh 的一项一项探测，跟着插件走。
# shellcheck shell=bash disable=SC2034
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完整 OIDC（应用 /oauth2/login → 核心身份方用核心会话自动授权 → 回调）拿应用
#       令牌，再用应用自己的"当前用户"接口断言认出的是主人。
# 工具：上游工具都没标 readOnlyHint（每次调用总线都发确认卡片），不能写 MCP_TOOL（套件要求标注），
#       写 mcp_check：套件先跑 mcp list（结果在 $SMOKE_TOOLS），再由这里后台跑 approve 应答卡片、
#       调 query_all_accounts。调用前要备凭据，写在 before_mcp：按 README 写的主人流程的等价 API——
#       给 owner 账号设密码（OIDC 建的号没有密码，不要求旧密码）→ 生成 MCP 令牌（生成要过密码确认）
#       → 经核心接口填进插件的 input 密钥（等价于主人在设置页粘贴）。
# 数据：data_write 用随机标记经应用 API 记一笔支出，标记写进 $SMOKE_STATE；data_check 读回标记去
#       transactions/list 里找。OIDC 自动建号的账本是空的，先建账户和类别。

web_assert() { grep -qi '<title>ezBookkeeping</title>'; }

_ebk_origin() { printf '%s' "${SMOKE_WEB_ORIGIN:-${SMOKE_WEB_URL%%[/?#]*}}"; }

_ebk_rand() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }

_ebk_state_dir() { # SMOKE_STATE 在套件里是标记文件（e2e 里可能是目录），探针自己的状态文件放同一边
  if [[ -d "${SMOKE_STATE:-}" ]]; then printf '%s' "$SMOKE_STATE"; else printf '%s' "$(dirname "${SMOKE_STATE:-.}")"; fi
}

_ebk_pw_file() { printf '%s/ezbookkeeping-mcp-pw' "$(_ebk_state_dir)"; }

_ebk_marker_file() {
  if [[ -d "${SMOKE_STATE:-}" ]]; then printf '%s' "$SMOKE_STATE/ezbookkeeping-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

# 应用自己的 API：<方法> <路径> <令牌> [<JSON 正文>]，响应到标准输出。走 SMOKE_WEB_ORIGIN
# （套件的 web_get 会把路径拼在入口路径后面，这里要的是 origin）。
_ebk_api() {
  local method="$1" path="$2" token="$3" body="${4:-}"
  if [[ -n "$body" ]]; then
    curl_t "$SMOKE_WEB_MAX_TIME" "$(_ebk_origin)$path" --noproxy '*' -X "$method" \
      -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$body"
  else
    curl_t "$SMOKE_WEB_MAX_TIME" "$(_ebk_origin)$path" --noproxy '*' -X "$method" -H "Authorization: Bearer $token"
  fi
}

# 走完浏览器式 OIDC 拿应用会话令牌：核心会话先补进 jar（-b 保留别的域的会话），再跟 /oauth2/login
# 的重定向链；回调成功页的地址里带着临时令牌（fragment 不发给服务器，只能从 Location 头取），
# 再按前端登录后的同一步 POST /api/oauth2/authorize.json 换成正式会话令牌。
# client_session_id 每次随机：它是上游的防重键，写死会让一次没走完的登录挡住后面的登录（300 秒）。
ebk_token() {
  local jar base url loc i token out
  jar="${SMOKE_JAR:-}" base="${SMOKE_BASE:-}"
  [[ -n "$jar" && -n "$base" && -n "${SMOKE_TOKEN:-}" && -n "${SMOKE_WEB_URL:-}" ]] ||
    { echo "缺冒烟变量：需要 SMOKE_JAR/SMOKE_BASE/SMOKE_TOKEN/SMOKE_WEB_URL" >&2; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$jar" -c "$jar" --data-urlencode "token=$SMOKE_TOKEN" \
    "$base/_wonton/login" || { echo "主人令牌登录不了核心" >&2; return 1; }
  url="$(_ebk_origin)/oauth2/login?platform=desktop&client_session_id=wonton-$(_ebk_rand)"
  for i in 1 2 3 4 5 6 7 8; do
    loc="$(curl_t "$SMOKE_WEB_MAX_TIME" "$url" --noproxy '*' -b "$jar" -c "$jar" -H 'Accept: text/html' \
      -o /dev/null -w '%{redirect_url}')" || { echo "登录重定向链断在 $url" >&2; return 1; }
    [[ -z "$loc" ]] && break
    url="$loc"
    if [[ "$url" == *oauth2_callback*token=* ]]; then
      token="${url##*[?&]token=}"
      token="${token%%&*}"
      token="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$token")"
      [[ -n "$token" ]] || { echo "回调地址里 token 为空：$url" >&2; return 1; }
      out="$(curl_t "$SMOKE_WEB_MAX_TIME" "$(_ebk_origin)/api/oauth2/authorize.json" --noproxy '*' -X POST \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg t "$token" '{token:$t}')")" ||
        { echo "临时令牌换会话令牌失败：$out"; return 1; }
      token="$(jq -r '.result.token // empty' <<<"$out" 2>/dev/null)"
      [[ -n "$token" ]] || { echo "换会话令牌的响应里没有 token：$(head -c 200 <<<"$out")" >&2; return 1; }
      printf '%s' "$token"
      return 0
    fi
  done
  echo "重定向链里没走到回调（最后：$url）" >&2
  return 1
}

identity_check() {
  local token me
  token="$(ebk_token)" || { echo "拿不到应用令牌：OIDC 登录链失败"; return 1; }
  me="$(_ebk_api GET /api/v1/users/profile/get.json "$token")" ||
    { echo "当前用户接口失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.result.username == $u' <<<"$me" >/dev/null ||
    { echo "应用认出的不是用户 $SMOKE_OWNER：$(head -c 200 <<<"$me")"; return 1; }
}

# ---------- 工具（MCP）：先按主人流程备好令牌，再经总线调只读查询 ----------

before_mcp() {
  local token pw pw_file new_pw mcp_token secret_resp resp
  [[ "$SMOKE_SSO" == oidc ]] || { echo "清单不是 sso: oidc，备凭据的探针不适用"; return 1; }
  token="$(ebk_token)" || { echo "拿不到应用会话令牌：OIDC 登录链失败"; return 1; }
  pw_file="$(_ebk_pw_file)"
  pw="$(cat "$pw_file" 2>/dev/null || true)"

  _ebk_mint() { # <会话令牌> <密码>：生成 MCP 令牌，输出到标准输出；失败输出空
    _ebk_api POST /api/v1/tokens/generate/mcp.json "$1" \
      "$(jq -nc --arg p "$2" '{password:$p}')" 2>/dev/null | jq -r '.result.token // empty' 2>/dev/null
  }

  if [[ -n "$pw" ]]; then
    mcp_token="$(_ebk_mint "$token" "$pw")"
  fi
  if [[ -z "${mcp_token:-}" ]]; then
    # 没有存档密码（首次）或存档的密码不对（账号密码被改过）：设一个新密码再生成。
    # OIDC 自动建号的账号没有密码，profile/update 不要求旧密码；有密码时要带上旧密码。
    new_pw="ebk-probe-$(_ebk_rand)"
    if [[ -n "$pw" ]]; then
      resp="$(_ebk_api POST /api/v1/users/profile/update.json "$token" \
        "$(jq -nc --arg o "$pw" --arg p "$new_pw" '{oldPassword:$o,password:$p}')" 2>/dev/null)" ||
        { echo "改 owner 账号密码失败：$resp"; return 1; }
    else
      resp="$(_ebk_api POST /api/v1/users/profile/update.json "$token" \
        "$(jq -nc --arg p "$new_pw" '{password:$p}')" 2>/dev/null)" ||
        { echo "给 owner 账号设密码失败（账号已有别的密码？）：$resp"; return 1; }
    fi
    pw="$new_pw"
    printf '%s' "$pw" >"$pw_file"
    chmod 600 "$pw_file" 2>/dev/null || true
    mcp_token="$(_ebk_mint "$token" "$pw")"
  fi
  [[ -n "$mcp_token" ]] || { echo "生成 MCP 令牌失败（密码确认没过？）"; return 1; }
  secret_resp="$(smoke_api PUT "/_wonton/api/plugins/$SMOKE_PLUGIN_ID/secrets/mcp_token" \
    -H 'Content-Type: application/json' -d "$(jq -nc --arg v "$mcp_token" '{value:$v}')")" ||
    { echo "把 MCP 令牌写进插件设置失败：$secret_resp"; return 1; }
  # 核心发现头里的密钥对不上就会重连插件重新握手，给一轮时间。
  sleep 3
  say "MCP 令牌已生成并填进插件设置"
}

mcp_check() {
  local out n_tools
  n_tools="$(jq --arg s "$SMOKE_SLUG" '[.[] | select(.name | startswith($s + "__"))] | length' "$SMOKE_TOOLS" 2>/dev/null)" || n_tools=0
  [[ "$n_tools" -ge 8 ]] ||
    { echo "tools/list 应有 8 个本插件工具，看到 $n_tools：$(head -c 200 "$SMOKE_TOOLS" 2>/dev/null)"; return 1; }
  # 上游没标 readOnlyHint，调用要等主人确认：后台跑 approve 应答卡片，调完就停。
  probes_dev approve --watch >>"$PROBES_LOG" 2>&1 &
  local approver=$!
  out="$(mcp call "$SMOKE_MCP_URL" "${SMOKE_SLUG}__query_all_accounts" '{}' 2>&1)"
  kill "$approver" 2>/dev/null
  wait "$approver" 2>/dev/null
  jq -e '.content[0].text | fromjson | type == "object"' <<<"$out" >/dev/null 2>&1 ||
    { echo "query_all_accounts 结果不符合预期：$(head -c 300 <<<"$out")"; return 1; }
  echo "query_all_accounts 返回：$(jq -c '.content[0].text | fromjson' <<<"$out" | head -c 200)"
}

# ---------- 数据：随机标记记一笔支出，重装后读回 ----------

_ebk_ensure_account() { # <令牌>：返回可用的账户 id（没有就建一个现金账户）
  local token="$1" list id
  list="$(_ebk_api GET /api/v1/accounts/list.json "$token")" || { echo "列账户失败：$list" >&2; return 1; }
  id="$(jq -r '.result[0].id // empty' <<<"$list" 2>/dev/null)"
  if [[ -z "$id" ]]; then
    list="$(_ebk_api POST /api/v1/accounts/add.json "$token" \
      "$(jq -nc --arg n "现金-探针-$(_ebk_rand)" '{name:$n,category:1,type:1,icon:"1",color:"33691E",currency:"CNY"}')")" ||
      { echo "建账户失败：$list" >&2; return 1; }
    id="$(jq -r '.result.id // empty' <<<"$list" 2>/dev/null)"
    [[ -n "$id" ]] || { echo "建账户没回 id：$(head -c 200 <<<"$list")" >&2; return 1; }
  fi
  printf '%s' "$id"
}

_ebk_ensure_category() { # <令牌>：返回支出类别的次级类别 id（记账要的是次级类别；没有就建）
  local token="$1" list primary id
  list="$(_ebk_api GET /api/v1/transaction/categories/list.json "$token")" ||
    { echo "列类别失败：$list" >&2; return 1; }
  id="$(jq -r '[.result[]? | select(.type == 2 and (.parentId != null and .parentId != "0" and .parentId != ""))][0].id // empty' <<<"$list" 2>/dev/null)"
  if [[ -n "$id" ]]; then printf '%s' "$id"; return 0; fi
  primary="$(jq -r '[.result[]? | select(.type == 2 and (.parentId == null or .parentId == "0" or .parentId == ""))][0].id // empty' <<<"$list" 2>/dev/null)"
  if [[ -z "$primary" ]]; then
    primary="$(_ebk_api POST /api/v1/transaction/categories/add.json "$token" \
      '{"name":"其他-探针","type":2,"parentId":"0","icon":"1","color":"E65100"}' | jq -r '.result.id // empty')" ||
      { echo "建支出主类别失败" >&2; return 1; }
    [[ -n "$primary" ]] || { echo "建支出主类别没回 id" >&2; return 1; }
  fi
  list="$(_ebk_api POST /api/v1/transaction/categories/add.json "$token" \
    "$(jq -nc --arg p "$primary" '{name:"杂项-探针",type:2,parentId:$p,icon:"1",color:"E65100"}')")" ||
    { echo "建次级类别失败：$list" >&2; return 1; }
  id="$(jq -r '.result.id // empty' <<<"$list" 2>/dev/null)"
  [[ -n "$id" ]] || { echo "建次级类别没回 id：$(head -c 200 <<<"$list")" >&2; return 1; }
  printf '%s' "$id"
}

data_write() {
  local token marker account category now offset resp
  [[ -n "${SMOKE_STATE:-}" && -n "${SMOKE_WEB_URL:-}" ]] || { echo "缺冒烟变量：SMOKE_STATE/SMOKE_WEB_URL" >&2; return 1; }
  token="$(ebk_token)" || { echo "拿不到应用令牌，写不了数据" >&2; return 1; }
  account="$(_ebk_ensure_account "$token")" || return 1
  category="$(_ebk_ensure_category "$token")" || return 1
  marker="保数据-$(_ebk_rand)"
  now="$(date +%s)"
  offset="$(date +%z)"   # +0800 → 480
  offset="$((10#${offset%%[0-9]*}${offset:1:2} * 60 + 10#${offset:3:2}))"
  resp="$(_ebk_api POST /api/v1/transactions/add.json "$token" \
    "$(jq -nc --arg c "$category" --arg a "$account" --arg m "$marker" --argjson t "$now" --argjson o "$offset" \
      '{type:3,categoryId:$c,time:$t,utcOffset:$o,sourceAccountId:$a,sourceAmount:1234,comment:$m}')")" ||
    { echo "记一笔失败：$resp"; return 1; }
  jq -e '.result.id != null' <<<"$resp" >/dev/null 2>&1 || { echo "记账没回 id：$(head -c 200 <<<"$resp")"; return 1; }
  printf '%s' "$marker" >"$(_ebk_marker_file)"
}

data_check() {
  local token marker list
  marker="$(cat "$(_ebk_marker_file)")"
  [[ -n "$marker" ]] || { echo "标记文件是空的"; return 1; }
  token="$(ebk_token)" || { echo "拿不到应用令牌，读不了数据" >&2; return 1; }
  list="$(_ebk_api GET /api/v1/transactions/list.json "$token")" ||
    { echo "列交易失败：$list"; return 1; }
  grep -qF "$marker" <<<"$list" ||
    { echo "交易列表里找不到标记 $marker：$(head -c 300 <<<"$list")"; return 1; }
}
