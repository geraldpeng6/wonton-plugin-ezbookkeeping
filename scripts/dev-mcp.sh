# shellcheck shell=bash
# shellcheck disable=SC2154 # root、plugin、instance 由 dev.sh 加载设置。
# 直连调试用的 MCP 客户端：官方 MCP Inspector CLI 的多架构镜像（官方发布流程按版本发布）。
# 升级版本时连清单列表摘要一起换：docker buildx imagetools inspect ghcr.io/modelcontextprotocol/inspector:<版本>。
mcp_client_image="ghcr.io/modelcontextprotocol/inspector:2.15.0@sha256:a907a7d15d59aebd06050d5bebed9227c6fb66fd8d9511be252e13d27b2d643d"

# 由 dev.sh 加载：在插件网络里起一个一次性客户端容器，连清单 mcp 声明的服务。
mcp_direct() {
  local sub facts endpoint id service url container network tool args
  need_plugin
  facts="$(docker compose -f "$plugin/docker-compose.yml" config --no-interpolate --format json)" ||
    die "解析不了工作区的 docker-compose.yml"
  endpoint="$(python3 - "$facts" <<'PY'
import json, sys
manifest = json.loads(sys.argv[1])["x-wonton"]
mcp = manifest.get("mcp")
if not mcp:
    sys.exit("插件清单没有声明 mcp；直连只调试提供 MCP 的插件，总线请用 mcp list|call")
if mcp["transport"] != "streamable-http":
    sys.exit(f"不支持的 MCP 传输：{mcp['transport']}")
print(manifest["id"], mcp["service"], f"{mcp['port']}{mcp.get('path') or '/mcp'}", sep="\t")
PY
  )" || exit 1
  IFS=$'\t' read -r id service url <<<"$endpoint"
  container="wonton-$instance--${id//./-}--$service"
  network="wonton-$instance--${id//./-}"
  docker container inspect "$container" >/dev/null 2>&1 || die "找不到 MCP 服务容器 $container：先安装插件"
  docker network inspect "$network" >/dev/null 2>&1 ||
    die "找不到插件网络 $network：直连要求插件使用核心管理的独立网络"
  docker image inspect "$mcp_client_image" >/dev/null 2>&1 || {
    info "拉取 MCP 客户端镜像 $mcp_client_image"
    docker pull -q "$mcp_client_image" >/dev/null || die "拉不到 MCP 客户端镜像 $mcp_client_image"
  }
  sub="$1"; shift
  case "$sub" in
    list) set -- --method tools/list ;;
    call)
      [[ -n "${1:-}" ]] || usage
      tool="$1"; args="${2:-{\}}"
      set -- --method tools/call --tool-name "$tool" --tool-args-json "$args"
      ;;
  esac
  # 连接 30 秒、单次调用 300 秒，经只读挂载的会话文件给 Inspector（SDK 默认 60 秒，对慢工具太短）。
  # --stored-auth-only：插件网络里的 MCP 服务不带认证，服务端真要认证时立刻失败，不在容器里等交互登录。
  # conf 留在全局：EXIT trap 才读得到（同 install_plugin 的 tmp）。
  conf="$(mktemp "$state/mcp-client.XXXXXX")"
  trap 'rm -f "$conf"' EXIT
  printf '{"mcpServers":{"wonton-direct":{"type":"streamable-http","url":"http://%s:%s","connectionTimeout":30000,"requestTimeout":300000}}}\n' \
    "$container" "$url" >"$conf"
  docker run --rm --name "wonton-$instance--mcp-client-$(random_hex 4)" \
    --label "wonton.instance=$instance" --network "$network" \
    -e HTTP_PROXY= -e HTTPS_PROXY= -e ALL_PROXY= -e NO_PROXY='*' \
    -e http_proxy= -e https_proxy= -e all_proxy= -e no_proxy='*' \
    -v "$conf:/wonton-mcp.json:ro" \
    "$mcp_client_image" --cli --config /wonton-mcp.json --server wonton-direct \
    --stored-auth-only -q --format json "$@"
}
