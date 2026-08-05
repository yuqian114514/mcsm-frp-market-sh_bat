#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
FRP_DIR="$SCRIPT_DIR/frp"
STATE_XML="$DATA_DIR/state.xml"

GITHUB_MIRROR="https://github.nswrz.cn"
GITHUB_MIRROR2="https://ghfile.geekertao.top"
GITHUB_MIRROR3="https://github.tbap.top"

mkdir -p "$DATA_DIR" "$FRP_DIR"

# ---- Banner ----
echo ""
echo "————————————————————————————————————————————————"
echo ""
echo "      MCSM FRP 模板集市 - Lolia-FRP"
echo "                 作者: 语千🍥"
echo "              QQ交流群: 941830180"
echo ""
echo "————————————————————————————————————————————————"
echo ""

# ---- 输出 ----
info()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()    { echo -e "\033[32m[+]\033[0m $*"; }
warn()  { echo -e "\033[33m[!]\033[0m $*"; }
err()   { echo -e "\033[31m[x]\033[0m $*" >&2; }

# ---- 依赖自动安装 ----
# 探测包管理器
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v brew >/dev/null 2>&1; then echo "brew"
  else echo ""; fi
}

# 命令名 -> 包名 (个别发行版包名不同)
pkg_name_for() {
  local cmd="$1" mgr="$2"
  case "$cmd" in
    nc)
      case "$mgr" in
        apt)          echo "netcat-openbsd" ;;
        dnf|yum)      echo "nmap-ncat" ;;
        apk)          echo "netcat-openbsd" ;;
        pacman)       echo "openbsd-netcat" ;;
        zypper)       echo "netcat-openbsd" ;;
        brew)         echo "netcat" ;;
        *)            echo "netcat" ;;
      esac ;;
    base64|head|od|sed|tr)  echo "coreutils" ;;
    *)                      echo "$cmd" ;;   # curl jq tar openssl unzip 包名同命令名
  esac
}

# 用探测到的包管理器安装一组包
install_pkgs() {
  local mgr="$1"; shift
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0

  local sudo=""
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then sudo="sudo"; fi

  info "正在安装依赖: ${pkgs[*]}"
  case "$mgr" in
    apt)    $sudo apt-get update -y >/dev/null 2>&1; $sudo apt-get install -y "${pkgs[@]}" ;;
    dnf)    $sudo dnf install -y "${pkgs[@]}" ;;
    yum)    $sudo yum install -y "${pkgs[@]}" ;;
    pacman) $sudo pacman -Sy --noconfirm "${pkgs[@]}" ;;
    zypper) $sudo zypper install -y "${pkgs[@]}" ;;
    apk)    $sudo apk add "${pkgs[@]}" ;;
    brew)   brew install "${pkgs[@]}" ;;
    *)      return 1 ;;
  esac
}

# 确保这些命令都存在, 缺的自动装
ensure_deps() {
  local required=("$@")
  local missing=()
  local c
  for c in "${required[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  warn "检测到缺少依赖: ${missing[*]}"
  local mgr; mgr="$(detect_pkg_mgr)"
  if [ -z "$mgr" ]; then
    err "未找到可用的包管理器，请手动安装: ${missing[*]}"
    exit 1
  fi

  # 命令名映射为包名并去重
  local pkgs=() seen=""
  for c in "${missing[@]}"; do
    local p; p="$(pkg_name_for "$c" "$mgr")"
    case " $seen " in *" $p "*) ;; *) pkgs+=("$p"); seen="$seen $p" ;; esac
  done

  if ! install_pkgs "$mgr" "${pkgs[@]}"; then
    err "自动安装失败，请手动安装: ${missing[*]}"
    exit 1
  fi

  # 装完复查
  local still=()
  for c in "${missing[@]}"; do
    command -v "$c" >/dev/null 2>&1 || still+=("$c")
  done
  if [ "${#still[@]}" -ne 0 ]; then
    err "以下依赖安装后仍不可用: ${still[*]}"
    exit 1
  fi
  ok "依赖安装完成"
}

# 必需依赖 (nc 可选, 单独处理, 缺了会退回手动粘贴 URL)
ensure_deps curl jq tar openssl base64 unzip

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "缺少依赖: $c"; exit 1; }
  done
}

# ---- 平台识别 (LoliaFrp_<os>_<arch>) ----
detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      os="linux" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv6l) arch="arm" ;;
    i386|i686)     arch="386" ;;
    loongarch64)   arch="loong64" ;;
    *)             arch="amd64" ;;
  esac
  echo "${os}_${arch}"
}
PLATFORM="$(detect_platform)"

# ---- URL 编码 ----
urlencode() {
  local s="$1" out="" c i
  for ((i=0; i<${#s}; i++)); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  echo "$out"
}

# ---- 打开浏览器 ----
open_browser() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 &
  else warn "无法自动打开浏览器，请手动复制上面的链接"; fi
}

# ============================================================
# XML 状态持久化
# ============================================================
xml_init() {
  [ -f "$STATE_XML" ] && return
  cat > "$STATE_XML" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<state>
  <token></token>
  <refresh_token></refresh_token>
  <last_tunnel_id></last_tunnel_id>
  <last_tunnel_name></last_tunnel_name>
  <last_command></last_command>
  <frp_version></frp_version>
</state>
EOF
}

xml_get() { sed -n "s@.*<${1}>\(.*\)</${1}>.*@\1@p" "$STATE_XML" | head -n1; }

xml_set() {
  local tag="$1" val="$2"
  val="${val//&/&amp;}"; val="${val//</&lt;}"; val="${val//>/&gt;}"
  local esc; esc="$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')"
  if grep -q "<${tag}>" "$STATE_XML"; then
    sed -i.bak "s@<${tag}>.*</${tag}>@<${tag}>${esc}</${tag}>@" "$STATE_XML"
  else
    sed -i.bak "s@</state>@  <${tag}>${esc}</${tag}>\n</state>@" "$STATE_XML"
  fi
  rm -f "$STATE_XML.bak"
}

is_first_run() {
  [ ! -f "$STATE_XML" ] && return 0
  [ -z "$(xml_get last_tunnel_id)" ] && return 0
  return 1
}

# ============================================================
# 下载 (GitHub 主站 -> 三个镜像站 回退)
# ============================================================
download_with_fallback() {
  local gh_path="$1" out="$2"
  local primary="https://github.com/$gh_path"
  local mirror="$GITHUB_MIRROR/https://github.com/$gh_path"
  local mirror2="$GITHUB_MIRROR2/https://github.com/$gh_path"
  local mirror3="$GITHUB_MIRROR3/https://github.com/$gh_path"

  info "尝试从 GitHub 下载: $primary"
  if curl -fL -m 15 --retry 2 -o "$out" "$primary"; then ok "GitHub 下载成功"; return 0; fi
  warn "GitHub 下载失败，切换镜像站"
  info "镜像站下载: $mirror"
  if curl -fL --connect-timeout 20 --retry 2 -o "$out" "$mirror"; then ok "镜像站下载成功"; return 0; fi
  warn "下载失败，切换镜像站"
  info "镜像站下载: $mirror2"
  if curl -fL --connect-timeout 20 --retry 2 -o "$out" "$mirror2"; then ok "镜像站下载成功"; return 0; fi
  warn "下载失败，切换镜像站"
  info "镜像站下载: $mirror3"
  if curl -fL --connect-timeout 20 --retry 2 -o "$out" "$mirror3"; then ok "镜像站下载成功"; return 0; fi
  err "下载失败 (主站与镜像站均不可用)"
  return 1
}

# ============================================================
# Lolia 配置
# ============================================================
LOLIA_API_BASE="https://api.lolia.link/api/v1"
LOLIA_FRP_REPO="Lolia-FRP/lolia-frp"
LOLIA_AUTHORIZE="https://dash.lolia.link/oauth/authorize"
LOLIA_TOKEN_URL="https://api.lolia.link/api/v1/oauth2/token"
LOLIA_SCOPE="user:read tunnel:read node:read"
LOLIA_CLIENT_ID="xv1fzjdeuahur235"

# ---- PKCE 工具 ----
pkce_verifier() { head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }
pkce_challenge() { printf '%s' "$1" | openssl dgst -binary -sha256 | base64 | tr '+/' '-_' | tr -d '=\n'; }

# 用 nc 起一次性 HTTP 服务, 捕获回调请求行, 返回 /callback?... 路径
pkce_wait_callback() {
  local resp_body http req
  resp_body='<!doctype html><meta charset="utf-8"><h2>授权成功喵</h2><p>可以关闭本页返回终端了。</p>'
  http="HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n${resp_body}"
  req="$(printf '%b' "$http" | nc -l -p "$1" 2>/dev/null \
        || printf '%b' "$http" | nc -l "$1" 2>/dev/null)"
  echo "$req" | sed -n 's@^GET \(/callback[^ ]*\) HTTP.*@\1@p' | head -n1
}

# ---- OAuth2 + PKCE 登录 ----
ensure_token() {
  local token; token="$(xml_get token)"
  [ -n "$token" ] && return
  need_cmd openssl base64

  local verifier challenge state
  verifier="$(pkce_verifier)"
  challenge="$(pkce_challenge "$verifier")"
  state="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  # ---- 选择授权方式 ----
  # 云服务器/SSH 无本地浏览器, 回调会跳到"用户自己电脑"的 127.0.0.1, 服务器收不到
  # 所以默认给出选择: 本机自动收回调 / 手动粘贴回调 URL
  echo
  echo "================ 授权方式 ================"
  echo "  1) 本机运行 (自动打开浏览器并接收回调)"
  echo "  2) 云服务器/远程 (手动把浏览器地址栏 URL 粘贴回来)"
  echo "========================================="
  local mode
  # 无图形环境 (无 DISPLAY 且非 macOS) 或没有 nc 时, 默认推荐 2
  local default_mode=1
  if [ -z "${DISPLAY:-}" ] && [ "$(uname -s)" != "Darwin" ]; then default_mode=2; fi
  if ! command -v nc >/dev/null 2>&1; then default_mode=2; fi
  read -rp "请选择授权方式 [默认 ${default_mode}]: " mode
  [ -z "$mode" ] && mode="$default_mode"

  local redirect_uri callback_url

  if [ "$mode" = "1" ]; then
    # ---- 本机自动收回调 ----
    need_cmd nc
    local port=11451 chosen=""
    while [ "$port" -le 11460 ]; do
      if ! { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null; then
        chosen="$port"; break
      fi
      exec 3>&- 2>/dev/null || true
      port=$((port+1))
    done
    [ -z "$chosen" ] && chosen=11451
    redirect_uri="http://127.0.0.1:${chosen}/callback"

    local auth_url="${LOLIA_AUTHORIZE}?response_type=code&client_id=${LOLIA_CLIENT_ID}&redirect_uri=$(urlencode "$redirect_uri")&scope=$(urlencode "$LOLIA_SCOPE")&state=${state}&code_challenge=${challenge}&code_challenge_method=S256"

    echo
    info "请在浏览器完成授权 (若未自动打开, 手动复制下面链接):"
    echo "  $auth_url"
    echo
    info "授权完成后, 浏览器会跳转到 $redirect_uri 显示授权成功喵页面"
    open_browser "$auth_url"

    info "等待授权回调 (127.0.0.1:${chosen})..."
    callback_url="$(pkce_wait_callback "$chosen")"
  else
    # ---- 云服务器: 手动粘贴回调 URL ----
    redirect_uri="http://127.0.0.1:11451/callback"
    local auth_url="${LOLIA_AUTHORIZE}?response_type=code&client_id=${LOLIA_CLIENT_ID}&redirect_uri=$(urlencode "$redirect_uri")&scope=$(urlencode "$LOLIA_SCOPE")&state=${state}&code_challenge=${challenge}&code_challenge_method=S256"

    echo
    info "请在【你自己电脑】的浏览器中打开以下链接完成授权:"
    echo "  $auth_url"
    echo
    info "授权后浏览器会跳到 http://127.0.0.1:11451/callback?... 这个打不开的页面 (正常现象)"
    info "请把浏览器【地址栏里的完整 URL】整段复制, 粘贴到这里:"
    read -rp "回调 URL: " callback_url
  fi

  local code rstate
  code="$(echo "$callback_url" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
  rstate="$(echo "$callback_url" | sed -n 's/.*[?&]state=\([^&]*\).*/\1/p')"
  [ -z "$code" ] && { err "未从回调解析到 code (请确认粘贴了完整 URL)"; exit 1; }
  [ -n "$rstate" ] && [ "$rstate" != "$state" ] && { err "state 不匹配, 已中止"; exit 1; }

  info "正在用 code 换取 access_token..."
  local resp
  resp="$(curl -fsSL --connect-timeout 20 -X POST "$LOLIA_TOKEN_URL" \
      --data-urlencode "grant_type=authorization_code" \
      --data-urlencode "code=$code" \
      --data-urlencode "redirect_uri=$redirect_uri" \
      --data-urlencode "client_id=$LOLIA_CLIENT_ID" \
      --data-urlencode "code_verifier=$verifier" 2>/dev/null)" \
      || { err "token 请求失败"; exit 1; }

  local access refresh
  access="$(echo "$resp" | jq -r '.access_token // .data.access_token // empty')"
  refresh="$(echo "$resp" | jq -r '.refresh_token // .data.refresh_token // empty')"
  [ -z "$access" ] && { err "换取 token 失败: $resp"; exit 1; }

  xml_set token "$access"
  [ -n "$refresh" ] && xml_set refresh_token "$refresh"
  ok "OAuth 登录成功"
}

# ============================================================
# 隧道操作
# ============================================================
# GET /user/tunnel (Bearer, 自动翻页) -> TSV: id \t name \t 展示信息
fetch_tunnels() {
  local token; token="$(xml_get token)"
  local page=1 total_page=1
  while :; do
    local resp
    resp="$(curl -fsSL --connect-timeout 15 \
        -H "Authorization: Bearer $token" \
        "$LOLIA_API_BASE/user/tunnel?page=$page&limit=50" 2>/dev/null)" || return 1

    echo "$resp" | jq -r '
      .data.list[]?
      | [ (.id|tostring), .name,
          ("[" + (.type // "?") + "] " + (.node_name // "-")
            + "  :" + ((.remote_port // 0)|tostring)
            + "  (" + (.remark // "") + ")  " + (.status // "")) ]
      | @tsv'

    total_page="$(echo "$resp" | jq -r '.data.total_page // 1')"
    [ "$page" -ge "$total_page" ] && break
    page=$((page+1))
  done
}

# GET /user/tunnel/{name} -> data.tunnel_token (frpc -t 用的就是它)
get_tunnel_token() {
  local tname="$1" token; token="$(xml_get token)"
  curl -fsSL --connect-timeout 15 \
    -H "Authorization: Bearer $token" \
    "$LOLIA_API_BASE/user/tunnel/$tname" 2>/dev/null \
    | jq -r '.data.tunnel_token // empty'
}

# GET /client/version -> data.tag
latest_version() {
  curl -fsSL --connect-timeout 10 "$LOLIA_API_BASE/client/version" 2>/dev/null \
    | jq -r '.data.tag // empty'
}

# ============================================================
# frp 二进制管理
# ============================================================
frpc_bin() { echo "$FRP_DIR/frpc"; }
installed_frp_version() { xml_get frp_version; }

install_frp() {
  local tag="$1"
  local asset
  case "$PLATFORM" in
    windows_*) asset="LoliaFrp_${PLATFORM}.zip" ;;
    *)         asset="LoliaFrp_${PLATFORM}.tar.gz" ;;
  esac
  local gh_path="$LOLIA_FRP_REPO/releases/download/$tag/$asset"
  local tmp="$DATA_DIR/$asset"

  info "下载 frp $tag ($asset)"
  download_with_fallback "$gh_path" "$tmp" || return 1

  info "解压中..."
  rm -rf "$DATA_DIR/frp_extract"; mkdir -p "$DATA_DIR/frp_extract"
  case "$asset" in
    *.zip)    need_cmd unzip; unzip -oq "$tmp" -d "$DATA_DIR/frp_extract" ;;
    *.tar.gz) tar -xzf "$tmp" -C "$DATA_DIR/frp_extract" ;;
  esac || { err "解压失败"; return 1; }

  local found
  found="$(find "$DATA_DIR/frp_extract" -maxdepth 3 -type f \
            \( -iname 'frpc' -o -iname 'loliafrp*' \) ! -iname '*.exe' | head -n1)"
  [ -z "$found" ] && { err "压缩包内未找到 frpc 可执行文件"; return 1; }

  cp "$found" "$(frpc_bin)"
  chmod +x "$(frpc_bin)"
  rm -rf "$tmp" "$DATA_DIR/frp_extract"
  xml_set frp_version "$tag"
  ok "frp 已安装: $tag"
}

ensure_frp_updated() {
  local latest; latest="$(latest_version)"
  local current; current="$(installed_frp_version)"
  if [ ! -x "$(frpc_bin)" ]; then
    info "首次启动，安装 frp..."
    [ -z "$latest" ] && { err "无法获取 frp 最新版本"; exit 1; }
    install_frp "$latest"
    return
  fi
  if [ -n "$latest" ] && [ "$latest" != "$current" ]; then
    warn "发现新版本 frp: ${current:-无} -> $latest，正在更新"
    install_frp "$latest"
  else
    ok "frp 已是最新版: ${current:-未知}"
  fi
}

# ============================================================
# TUI 选择隧道
# ============================================================
select_tunnel() {
  info "获取隧道列表..."
  local tsv; tsv="$(fetch_tunnels)"
  if [ -z "$tsv" ]; then err "未获取到隧道 (检查 token 或网络)"; return 1; fi

  local ids=() names=() extras=()
  while IFS=$'\t' read -r id name extra; do
    [ -z "$id" ] && continue
    ids+=("$id"); names+=("$name"); extras+=("$extra")
  done <<< "$tsv"

  echo
  echo "================ 隧道列表 ================"
  local i
  for i in "${!ids[@]}"; do
    printf "  %2d) [id:%s] %-24s %s\n" "$((i+1))" "${ids[$i]}" "${names[$i]}" "${extras[$i]}"
  done
  echo "========================================="

  local choice
  while true; do
    read -rp "选择隧道编号: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ids[@]}" ]; then
      SELECTED_ID="${ids[$((choice-1))]}"
      SELECTED_NAME="${names[$((choice-1))]}"
      return 0
    fi
    warn "输入无效，请重试"
  done
}

# ============================================================
# 启动隧道 (frpc -t 隧道id:tunnel_token)
# ============================================================
start_tunnel() {
  local tid="$1" tname="$2"
  info "获取隧道 [$tname] 的令牌..."
  local utoken; utoken="$(get_tunnel_token "$tname")"
  [ -z "$utoken" ] && { err "获取隧道令牌失败"; return 1; }

  local bin; bin="$(frpc_bin)"
  local cmd="$bin -t ${tid}:${utoken}"
  xml_set last_tunnel_id "$tid"
  xml_set last_tunnel_name "$tname"
  xml_set last_command "$cmd"

  ok "启动隧道: $tname"
  echo "执行: $bin -t ${tid}:***"
  echo "------------------------------------------"
  "$bin" -t "${tid}:${utoken}"
}

start_last() {
  local tid; tid="$(xml_get last_tunnel_id)"
  [ -z "$tid" ] && { warn "没有历史隧道记录"; return 1; }
  local tname; tname="$(xml_get last_tunnel_name)"
  start_tunnel "$tid" "$tname"
}

# ============================================================
# 主流程
# ============================================================
main() {
  xml_init
  if is_first_run; then
    ensure_token
    ensure_frp_updated
    select_tunnel || exit 1
    start_tunnel "$SELECTED_ID" "$SELECTED_NAME"
  else
    echo ""
    echo "==================================="
    echo " 上次隧道: $(xml_get last_tunnel_name)"
    echo "==================================="
    echo "  1) 启动上一次的隧道"
    echo "  2) 切换隧道"
    echo "  0) 退出"
    echo "==================================="
    local choice
    read -rp "请选择: " choice
    case "$choice" in
      1) ensure_token; ensure_frp_updated; start_last ;;
      2) ensure_token; ensure_frp_updated; select_tunnel || exit 1; start_tunnel "$SELECTED_ID" "$SELECTED_NAME" ;;
      0) info "退出"; exit 0 ;;
      *) warn "无效选择"; exit 1 ;;
    esac
  fi
}

main "$@"