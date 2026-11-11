#!/bin/sh
# 每次创建容器时运行：给主人在应用里建好账号，并给 MCP 入口签发令牌。
# 账号用核心注入的用户名和邮箱（和云吞账号一致），密码是核心生成的（主人在插件设置里能查看）；
# 语言和默认货币直接给中文、人民币，应用自己的注册表单改不了这两项默认值。
# MCP 令牌存在数据目录里，重装后还在；在应用里被吊销了，重建容器时用密码重新签发。
set -eu
umask 077

base=http://web:8080
dir=/ebk-bridge
token_file=$dir/token

die() { echo "init: $*" >&2; exit 1; }

# 已存的令牌还好用就收工（升级、重建容器都走这条捷径）
if [ -s "$token_file" ]; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $(cat "$token_file")" \
    "$base/api/v1/users/profile/get.json") || die "检查已存的 MCP 令牌时传输失败"
  case "$code" in
    200) exit 0 ;;
    401) : ;;
    *) die "检查已存的 MCP 令牌失败（HTTP $code）" ;;
  esac
fi

login() { # authorize.json 的字段是 loginName（用户名或邮箱都行），不是 username
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"loginName\":\"$WONTON_OWNER_NAME\",\"password\":\"$WONTON_SECRET_OWNER_PASSWORD\"}" \
    "$base/api/authorize.json" || return 1
}

resp=$(login) || resp=
if [ -z "$resp" ]; then
  # 登录不了说明账号还没建（首次安装）；已注册但密码对不上时，注册也会失败，如实报错。
  code=$(curl -sS -o /tmp/ebk-resp -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$(printf \
    '{"username":"%s","email":"%s","nickname":"%s","password":"%s","language":"zh-Hans","defaultCurrency":"CNY","categories":[]}' \
    "$WONTON_OWNER_NAME" "$WONTON_OWNER_EMAIL" "$WONTON_OWNER_NAME" "$WONTON_SECRET_OWNER_PASSWORD")" \
    "$base/api/register.json") || die "注册请求传输失败"
  [ "$code" = 200 ] || die "建账号 $WONTON_OWNER_NAME 失败（HTTP $code）：$(head -c 200 /tmp/ebk-resp)（可能已存在且密码已改）"
  resp=$(login) || die "注册后登录失败（账号 $WONTON_OWNER_NAME）"
fi
session=$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$session" ] || die "登录响应里没有令牌"

# MCP 令牌的签发要过一遍密码确认（上游设计），这里替主人带上同一个密码；
# 默认不过期。主人改了应用密码并吊销令牌后，重建容器会如实失败，改回密码可恢复。
mcp=$(curl -fsS -X POST -H "Authorization: Bearer $session" -H 'Content-Type: application/json' \
  -d "{\"password\":\"$WONTON_SECRET_OWNER_PASSWORD\"}" \
  "$base/api/v1/tokens/generate/mcp.json") || die "生成 MCP 令牌失败"
token=$(printf '%s' "$mcp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$token" ] || die "生成 MCP 令牌的响应里没有令牌"

printf '%s' "$token" >"$token_file"
