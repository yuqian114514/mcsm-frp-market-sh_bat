#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
FRP_DIR="$SCRIPT_DIR/frp"
STATE_XML="$DATA_DIR/state.xml"
API_BASE="https://api.mefrp.com/api"
DRIVE_BASE="https://drive.mcsl.com.cn/d/ME-Frp/Local/MEFrp-Core"
UA="MefrpLauncher/1.0 (OpenAI)"
ORIGIN="https://www.mefrp.com"
REFERER="https://www.mefrp.com/"

mkdir -p "$DATA_DIR" "$FRP_DIR"

info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "缺少依赖: $c"; exit 1; }
  done
}

need_cmd curl jq tar

xml_init() {
  [ -f "$STATE_XML" ] && return
  cat > "$STATE_XML" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<state>
  <token></token>
  <refresh_token></refresh_token>
  <last_proxy_id></last_proxy_id>
  <last_proxy_name></last_proxy_name>
  <frp_version></frp_version>
  <last_config></last_config>
</state>
EOF
}

xml_get() {
  sed -n "s@.*<${1}>\(.*\)</${1}>.*@\1@p" "$STATE_XML" | head -n1
}

xml_set() {
  local tag="$1" val="$2" esc
  val="${val//&/&amp;}"
  val="${val//</&lt;}"
  val="${val//>/&gt;}"
  esc="$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')"
  if grep -q "<${tag}>" "$STATE_XML"; then
    sed -i.bak "s@<${tag}>.*</${tag}>@<${tag}>${esc}</${tag}>@" "$STATE_XML"
  else
    sed -i.bak "s@</state>@  <${tag}>${esc}</${tag}>\n</state>@" "$STATE_XML"
  fi
  rm -f "$STATE_XML.bak"
}

platform_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) echo linux ;;
  esac
}

platform_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    i386|i686) echo 386 ;;
    armv7l|armv6l) echo arm ;;
    *) echo amd64 ;;
  esac
}

frpc_bin() {
  if [ "$(platform_os)" = "windows" ]; then
    echo "$FRP_DIR/frpc.exe"
  else
    echo "$FRP_DIR/frpc"
  fi
}

api_headers() {
  token="$(xml_get token)"
  printf '%s\n' \
    -H "Authorization: Bearer $token" \
    -H "User-Agent: $UA" \
    -H "Origin: $ORIGIN" \
    -H "Referer: $REFERER" \
    -H "Accept: application/json, text/plain, */*"
}

api_get() {
  local path="$1"
  curl -fsSL --connect-timeout 20 $(api_headers) "$API_BASE$path"
}

api_post_json() {
  local path="$1" body="$2"
  curl -fsSL --connect-timeout 20 -X POST \
    $(api_headers) \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$API_BASE$path"
}

ensure_token() {
  token="$(xml_get token)"
  if [ -n "$token" ]; then
    return
  fi

  echo
  echo "================ 登录 ================"
  echo "请粘贴 MEFrp 用户 Token（Bearer Token）"
  echo "======================================="
  read -r -p "Token: " token
  [ -n "$token" ] || { err "未提供 Token"; exit 1; }
  xml_set token "$token"

  if ! api_get "/auth/proxy/list" >/dev/null 2>&1; then
    xml_set token ""
    err "Token 无效或已失效"
    exit 1
  fi
  ok "Token 校验通过"
}

resolve_version() {
  local raw ver
  for path in /auth/downloadSources /auth/products; do
    raw="$(api_get "$path" 2>/dev/null || true)"
    ver="$(printf '%s' "$raw" | grep -oE '/ME-Frp/Local/MEFrp-Core/[^"/]+' | head -n1 | sed 's@.*/@@')"
    [ -n "$ver" ] && { printf '%s\n' "$ver"; return 0; }
    ver="$(printf '%s' "$raw" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n1)"
    [ -n "$ver" ] && { printf '%s\n' "$ver"; return 0; }
    ver="$(printf '%s' "$raw" | sed -n 's/.*"tag":"\([^"]*\)".*/\1/p' | head -n1)"
    [ -n "$ver" ] && { printf '%s\n' "$ver"; return 0; }
  done

  read -r -p "请输入 MEFrp 版本号: " ver
  [ -n "$ver" ] || { err "无法解析版本号"; exit 1; }
  printf '%s\n' "$ver"
}

asset_name() {
  local ver="$1" os arch ext
  os="$(platform_os)"
  arch="$(platform_arch)"
  if [ "$os" = "windows" ]; then
    ext="zip"
  else
    ext="tar"
  fi
  printf 'mefrpc_%s_%s_%s.%s' "$os" "$arch" "$ver" "$ext"
}

install_frpc() {
  local ver asset url tmp bin extract found current
  ver="$(resolve_version)"
  current="$(xml_get frp_version)"
  bin="$(frpc_bin)"

  if [ -x "$bin" ] && [ "$current" = "$ver" ]; then
    ok "frpc 已是最新版: $ver"
    return
  fi

  asset="$(asset_name "$ver")"
  url="$DRIVE_BASE/$ver/$asset"
  tmp="$DATA_DIR/$asset"
  extract="$DATA_DIR/frp_extract"

  info "下载 frpc: $asset"
  curl -fL --connect-timeout 20 --retry 2 \
    -H "User-Agent: $UA" \
    -H "Origin: $ORIGIN" \
    -H "Referer: $REFERER" \
    -o "$tmp" \
    "$url" || { err "下载失败: $url"; exit 1; }

  rm -rf "$extract"
  mkdir -p "$extract"

  case "$asset" in
    *.zip) need_cmd unzip; unzip -oq "$tmp" -d "$extract" ;;
    *.tar) tar -xf "$tmp" -C "$extract" ;;
  esac || { err "解压失败"; exit 1; }

  found="$(find "$extract" -type f \( -iname 'frpc' -o -iname 'mefrpc' -o -iname 'frpc.exe' -o -iname 'mefrpc.exe' \) | head -n1)"
  [ -n "$found" ] || { err "压缩包内未找到 frpc 可执行文件"; exit 1; }

  cp "$found" "$bin"
  chmod +x "$bin" 2>/dev/null || true
  rm -f "$tmp"
  rm -rf "$extract"
  xml_set frp_version "$ver"
  ok "frpc 已安装: $ver"
}

fetch_proxies() {
  api_get "/auth/proxy/list" | jq -r '
    (.data.proxies // .data.list // [])[]
    | [
        (.proxyId // .id // 0|tostring),
        (.proxyName // .name // ""),
        (.proxyType // .type // ""),
        (.nodeId // ""),
        (.remotePort // .remote_port // ""),
        (if .isOnline == null then (.status // "") else ("online=" + (.isOnline|tostring)) end)
      ] | @tsv'
}

select_proxy() {
  info "获取隧道列表..."
  local tsv ids=() names=() lines=() id name type node port status i choice
  tsv="$(fetch_proxies)"
  [ -n "$tsv" ] || { err "未获取到隧道"; exit 1; }

  while IFS=$'\t' read -r id name type node port status; do
    [ -n "$id" ] || continue
    ids+=("$id")
    names+=("$name")
    lines+=("[$type] node:$node port:$port $status")
  done <<EOF
$tsv
EOF

  echo
  echo "================ 隧道列表 ================"
  for i in "${!ids[@]}"; do
    printf "  %2d) [id:%s] %-24s %s\n" "$((i+1))" "${ids[$i]}" "${names[$i]}" "${lines[$i]}"
  done
  echo "========================================="

  while true; do
    read -r -p "选择隧道编号: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ids[@]}" ]; then
      SELECTED_ID="${ids[$((choice-1))]}"
      SELECTED_NAME="${names[$((choice-1))]}"
      return 0
    fi
    warn "输入无效，请重试"
  done
}

save_config() {
  local proxy_id="$1" cfg raw
  raw="$(api_post_json "/auth/proxy/config" "{\"proxyId\":$proxy_id,\"format\":\"toml\"}")" || {
    err "获取配置失败"
    exit 1
  }
  cfg="$DATA_DIR/proxy_${proxy_id}.toml"
  printf '%s' "$raw" | jq -r '.data.config // empty' > "$cfg"
  [ -s "$cfg" ] || { err "配置内容为空"; exit 1; }
  xml_set last_config "$cfg"
  printf '%s\n' "$cfg"
}

start_proxy() {
  local proxy_id="$1" proxy_name="$2" cfg bin
  info "获取隧道 [$proxy_name] 配置..."
  cfg="$(save_config "$proxy_id")"
  bin="$(frpc_bin)"

  [ -x "$bin" ] || install_frpc

  xml_set last_proxy_id "$proxy_id"
  xml_set last_proxy_name "$proxy_name"

  ok "启动隧道: $proxy_name"
  echo "执行: $bin -c $cfg"
  echo "------------------------------------------"
  "$bin" -c "$cfg"
}

main() {
  xml_init
  ensure_token
  install_frpc
  select_proxy
  start_proxy "$SELECTED_ID" "$SELECTED_NAME"
}

main "$@"
