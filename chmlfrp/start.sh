
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
FRP_DIR="${SCRIPT_DIR}/frp"
STATE_FILE="${DATA_DIR}/state.json"
CHML_API_BASE="https://cf-v2.uapis.cn"
CHML_AUTHORIZE="https://account-api.qzhua.net/oauth2/authorize"
CHML_TOKEN_URL="https://account-api.qzhua.net/oauth2/token"
CHML_SCOPE="openid profile email phone offline_access chmlfrp_api"
CHML_CLIENT_ID="01a00af8728b79c6aae8488b76afbb15"
CHML_FRP_VERSION="0.51.2_251023"
CHML_DOWNLOAD_BASE="https://cf-v1.uapis.cn/download"
REDIRECT_PORT=47902

# 颜色输出
info() { echo -e "\033[36m[*] $1\033[0m" >&2; }
ok() { echo -e "\033[32m[+] $1\033[0m" >&2; }
warn() { echo -e "\033[33m[!] $1\033[0m" >&2; }
err() { echo -e "\033[31m[x] $1\033[0m" >&2; }

# ... 保持其他函数不变 ...

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v apk &> /dev/null; then
        echo "apk"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

command_exists() {
    command -v "$1" &> /dev/null
}

install_dependencies() {
    local pkg_mgr=$(detect_package_manager)
    local os=$(detect_os)
    local missing_deps=()

    info "检测系统依赖..."

    command_exists jq || missing_deps+=("jq")
    command_exists curl || missing_deps+=("curl")
    command_exists openssl || missing_deps+=("openssl")

    if ! command_exists nc && ! command_exists netcat; then
        case "$pkg_mgr" in
            apt) missing_deps+=("netcat-openbsd") ;;
            yum|dnf) missing_deps+=("nmap-ncat") ;;
            pacman) missing_deps+=("openbsd-netcat") ;;
            apk) missing_deps+=("netcat-openbsd") ;;
            zypper) missing_deps+=("netcat-openbsd") ;;
            *) missing_deps+=("netcat") ;;
        esac
    fi

    if [ ${#missing_deps[@]} -eq 0 ]; then
        ok "所有依赖已安装"
        return 0
    fi

    warn "缺少依赖: ${missing_deps[*]}"

    if [ "$EUID" -ne 0 ]; then
        err "需要 root 权限来安装依赖"
        echo "" >&2
        echo "请使用以下命令之一手动安装依赖：" >&2
        echo "" >&2
        case "$pkg_mgr" in
            apt) echo "  sudo apt update && sudo apt install -y ${missing_deps[*]}" >&2 ;;
            yum) echo "  sudo yum install -y ${missing_deps[*]}" >&2 ;;
            dnf) echo "  sudo dnf install -y ${missing_deps[*]}" >&2 ;;
            pacman) echo "  sudo pacman -Sy --noconfirm ${missing_deps[*]}" >&2 ;;
            apk) echo "  sudo apk add ${missing_deps[*]}" >&2 ;;
            zypper) echo "  sudo zypper install -y ${missing_deps[*]}" >&2 ;;
            *) echo "  未知的包管理器，请手动安装: ${missing_deps[*]}" >&2 ;;
        esac
        echo "" >&2
        exit 1
    fi

    info "正在自动安装依赖: ${missing_deps[*]}"

    case "$pkg_mgr" in
        apt)
            apt update -qq || warn "apt update 失败"
            apt install -y ${missing_deps[*]} || { err "安装失败"; exit 1; }
            ;;
        yum) yum install -y ${missing_deps[*]} || { err "安装失败"; exit 1; } ;;
        dnf) dnf install -y ${missing_deps[*]} || { err "安装失败"; exit 1; } ;;
        pacman) pacman -Sy --noconfirm ${missing_deps[*]} || { err "安装失败"; exit 1; } ;;
        apk) apk add ${missing_deps[*]} || { err "安装失败"; exit 1; } ;;
        zypper) zypper install -y ${missing_deps[*]} || { err "安装失败"; exit 1; } ;;
        *)
            err "不支持的包管理器: $pkg_mgr"
            err "请手动安装以下依赖: ${missing_deps[*]}"
            exit 1
            ;;
    esac

    ok "依赖安装完成"
}

show_banner() {
    echo "" >&2
    echo "————————————————————————————————————————————————" >&2
    echo "" >&2
    echo "      MCSM FRP 模板集市 - *ChmlfFrp*" >&2
    echo "                 作者: 语千🍥" >&2
    echo "              QQ交流群: 941830180" >&2
    echo "" >&2
    echo "————————————————————————————————————————————————" >&2
    echo "" >&2
}

mkdir -p "$DATA_DIR" "$FRP_DIR"

detect_platform() {
    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        i386|i686) arch="386" ;;
    esac

    echo "${os}_${arch}"
}

PLATFORM=$(detect_platform)

init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"token":"","refresh_token":"","last_tunnel_id":"","last_tunnel_name":"","frp_version":""}' > "$STATE_FILE"
    fi
}

get_state() {
    if [ ! -f "$STATE_FILE" ]; then echo ""; return; fi
    jq -r ".$1 // \"\"" "$STATE_FILE" 2>/dev/null || echo ""
}

set_state() {
    local key=$1 value=$2
    if [ ! -f "$STATE_FILE" ]; then init_state; fi
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

test_first_run() {
    local tid=$(get_state "last_tunnel_id")
    [ -z "$tid" ] && return 0 || return 1
}

base64url() {
    openssl base64 -e | tr '+/' '-_' | tr -d '=' | tr -d '\n'
}

generate_verifier() {
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' | tr -d '\n'
}

generate_challenge() {
    echo -n "$1" | openssl dgst -sha256 -binary | base64url
}

url_encode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

ensure_token() {
    local token=$(get_state "token")
    if [ -n "$token" ]; then return; fi

    local verifier=$(generate_verifier)
    local challenge=$(generate_challenge "$verifier")
    local state=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)
    local nonce=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)

    echo "" >&2
    echo "================ 授权方式 ================" >&2
    echo "  1) 本机运行 (自动打开浏览器并接收回调)" >&2
    echo "  2) 云服务器/远程 (手动把浏览器地址栏 URL 粘贴回来)" >&2
    echo "==========================================" >&2
    read -p "请选择授权方式 [默认 2]: " mode
    mode=${mode:-2}

    local redirect_uri="http://127.0.0.1:${REDIRECT_PORT}/callback"
    local auth_url="${CHML_AUTHORIZE}?response_type=code&client_id=${CHML_CLIENT_ID}&redirect_uri=$(url_encode "$redirect_uri")&scope=$(url_encode "$CHML_SCOPE")&state=${state}&nonce=${nonce}&code_challenge=${challenge}&code_challenge_method=S256"

    if [ "$mode" = "2" ]; then
        echo "" >&2
        warn "请在浏览器中打开以下链接完成授权:"
        echo "  $auth_url" >&2
        echo "" >&2
        warn "授权后浏览器会跳到 http://127.0.0.1:${REDIRECT_PORT}/callback?... 这个打不开的页面 (正常现象)"
        warn "请把浏览器【地址栏里的完整 URL】整段复制, 粘贴到这里:"
        read -p "回调 URL: " callback_url

        code=$(echo "$callback_url" | grep -oP 'code=\K[^&\s]+' || echo "")
        got_state=$(echo "$callback_url" | grep -oP 'state=\K[^&\s]+' || echo "")
    else
        info "已在 $redirect_uri 等待授权回调..."
        echo "" >&2
        warn "请在浏览器中打开以下链接完成授权:"
        echo "  $auth_url" >&2
        echo "" >&2

        if command -v xdg-open &> /dev/null; then
            xdg-open "$auth_url" 2>/dev/null || true
        elif command -v open &> /dev/null; then
            open "$auth_url" 2>/dev/null || true
        fi

        code=""
        got_state=""

        response=$(echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><meta charset='utf-8'><h2>授权成功喵</h2><p>可以关闭本页返回终端了。</p>")

        while true; do
            request=$(echo -e "$response" | nc -l -p $REDIRECT_PORT -q 1 2>/dev/null || echo "")
            if [ -n "$request" ]; then
                code=$(echo "$request" | grep -oP 'GET /callback\?.*code=\K[^&\s]+' || echo "")
                got_state=$(echo "$request" | grep -oP 'state=\K[^&\s]+' || echo "")
                [ -n "$code" ] && break
            fi
        done
    fi

    if [ -z "$code" ]; then err "未获取到授权 code"; exit 1; fi
    if [ "$got_state" != "$state" ]; then err "state 不匹配, 已中止"; exit 1; fi

    info "正在用 code 换取 access_token..."
    local token_resp=$(curl -s -X POST "$CHML_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code&code=${code}&redirect_uri=${redirect_uri}&client_id=${CHML_CLIENT_ID}&code_verifier=${verifier}")

    local access_token=$(echo "$token_resp" | jq -r '.access_token // .data.access_token // ""')
    local refresh_token=$(echo "$token_resp" | jq -r '.refresh_token // .data.refresh_token // ""')

    if [ -z "$access_token" ]; then err "换取 token 失败"; exit 1; fi

    set_state "token" "$access_token"
    [ -n "$refresh_token" ] && set_state "refresh_token" "$refresh_token"
    ok "OAuth 登录成功"
}

fetch_tunnels() {
    local token=$(get_state "token")
    local uri="${CHML_API_BASE}/tunnel?token=${token}"

    local resp=$(curl -s "$uri")
    local state_val=$(echo "$resp" | jq -r '.state // ""')

    if [ "$state_val" != "success" ]; then
        warn "Token 可能过期或无效，重新登录"
        set_state "token" ""
        ensure_token
        fetch_tunnels
        return
    fi

    echo "$resp" | jq -c '.data[]' 2>/dev/null
}



get_frpc_config() {
    local tunnel_name=$1
    local node_name=$2
    local token=$(get_state "token")
    local cfg="${DATA_DIR}/frpc_${tunnel_name}.ini"

    # 使用 curl 的 --data-urlencode 参数自动编码
    info "请求配置 API: 隧道=$tunnel_name, 节点=$node_name"

    local resp=$(curl -s -G "${CHML_API_BASE}/tunnel_config" \
        --data-urlencode "token=${token}" \
        --data-urlencode "node=${node_name}" \
        --data-urlencode "tunnel_names=${tunnel_name}")

    local state_val=$(echo "$resp" | jq -r '.state // empty' 2>/dev/null)

    if [ "$state_val" != "success" ]; then
        local msg=$(echo "$resp" | jq -r '.msg // "未知错误"' 2>/dev/null)
        err "获取配置失败: $msg"

        # 如果还是失败，尝试手动拼接 URL（像 PowerShell 那样）
        warn "尝试备用方案..."
        local manual_url="${CHML_API_BASE}/tunnel_config?token=${token}&node=$(printf '%s' "$node_name" | jq -sRr @uri)&tunnel_names=$(printf '%s' "$tunnel_name" | jq -sRr @uri)"
        resp=$(curl -s "$manual_url")
        state_val=$(echo "$resp" | jq -r '.state // empty' 2>/dev/null)

        if [ "$state_val" != "success" ]; then
            err "备用方案也失败"
            info "响应内容: $(echo "$resp" | head -c 200)..."
            return 1
        fi
    fi

    # data 字段是字符串，直接提取并写入文件
    echo "$resp" | jq -r '.data // empty' 2>/dev/null > "$cfg"

    if [ ! -s "$cfg" ]; then
        err "配置文件为空"
        return 1
    fi

    ok "配置已保存到: $cfg"
    echo "$cfg"
}

get_frpc_bin() {
    echo "${FRP_DIR}/frpc"
}


install_frp() {
    local tag=$1
    local asset="ChmlFrp-${tag}_${PLATFORM}.tar.gz"
    local download_url="${CHML_DOWNLOAD_BASE}/${asset}"
    local tmp="${DATA_DIR}/${asset}"

    info "下载 frp $tag ($asset)"
    info "下载地址: $download_url"

    if ! curl -L -o "$tmp" "$download_url" --connect-timeout 60 --max-time 120; then
        err "下载失败"
        return 1
    fi
    ok "下载成功"

    info "解压中..."
    local extract="${DATA_DIR}/frp_extract"
    rm -rf "$extract"
    mkdir -p "$extract"

    if ! tar -xzf "$tmp" -C "$extract" 2>&1 | head -n 5 >&2; then
        err "解压失败"
        return 1
    fi

    local found=$(find "$extract" -type f \( -name "frpc" -o -name "chmlfrp" \) 2>/dev/null | head -n 1)

    if [ -z "$found" ]; then
        err "压缩包内未找到 frpc"
        warn "压缩包内容:"
        ls -la "$extract" >&2
        return 1
    fi

    info "找到 frpc: $found"
    cp "$found" "$(get_frpc_bin)"
    chmod +x "$(get_frpc_bin)"
    rm -f "$tmp"
    rm -rf "$extract"

    set_state "frp_version" "$tag"
    ok "frp 已安装: $tag"
    return 0
}

update_frp() {
    local latest=$CHML_FRP_VERSION
    local current=$(get_state "frp_version")
    local bin=$(get_frpc_bin)

    if [ ! -f "$bin" ]; then
        info "首次启动，安装 frp..."
        install_frp "$latest"
        return
    fi

    if [ "$latest" != "$current" ]; then
        warn "发现新版本 frp: $current -> $latest，正在更新"
        install_frp "$latest"
        return
    fi

    ok "frp 已是最新版: $current"
}

select_tunnel() {
    info "获取隧道列表..."
    local tunnels=$(fetch_tunnels)

    if [ -z "$tunnels" ]; then
        err "未获取到隧道"
        return 1
    fi

    local count=$(echo "$tunnels" | wc -l)
    info "成功获取 $count 个隧道"

    echo "" >&2
    echo "================ 隧道列表 ================" >&2
    local i=1
    while IFS= read -r tunnel; do
        if [ -z "$tunnel" ]; then continue; fi

        local id=$(echo "$tunnel" | jq -r '.id')
        local name=$(echo "$tunnel" | jq -r '.name')
        local type=$(echo "$tunnel" | jq -r '.type')
        local node=$(echo "$tunnel" | jq -r '.node')
        local ip=$(echo "$tunnel" | jq -r '.ip')
        local dorp=$(echo "$tunnel" | jq -r '.dorp')
        local state=$(echo "$tunnel" | jq -r '.state')
        local status="离线"
        [ "$state" != "false" ] && status="在线"

        printf "%2d) [id:%s] %-20s [%s] %s -> %s:%s (%s)\n" "$i" "$id" "$name" "$type" "$node" "$ip" "$dorp" "$status" >&2
        i=$((i+1))
    done <<< "$tunnels"
    echo "==========================================" >&2

    while true; do
        read -p "选择隧道编号: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            echo "$tunnels" | sed -n "${choice}p"
            return 0
        fi
        warn "输入无效，请重试"
    done
}

start_tunnel() {
    local tunnel=$1
    local tid=$(echo "$tunnel" | jq -r '.id')
    local tname=$(echo "$tunnel" | jq -r '.name')
    local node=$(echo "$tunnel" | jq -r '.node')

    info "获取隧道 [$tname] 的配置..."
    local cfg=$(get_frpc_config "$tname" "$node")

    if [ -z "$cfg" ]; then return 1; fi

    local bin=$(get_frpc_bin)
    set_state "last_tunnel_id" "$tid"
    set_state "last_tunnel_name" "$tname"

    ok "启动隧道: $tname"
    echo "执行: $bin -c $cfg" >&2
    echo "------------------------------------------" >&2
    "$bin" -c "$cfg"
}

start_last() {
    local tid=$(get_state "last_tunnel_id")
    if [ -z "$tid" ]; then
        warn "没有历史隧道记录"
        return
    fi

    local tname=$(get_state "last_tunnel_name")
    local tunnels=$(fetch_tunnels)
    local tunnel=$(echo "$tunnels" | jq -c "select(.id == $tid)" | head -n 1)

    if [ -z "$tunnel" ]; then
        warn "未找到隧道 id=$tid，请重新选择"
        tunnel=$(select_tunnel)
        [ -n "$tunnel" ] && start_tunnel "$tunnel"
        return
    fi

    start_tunnel "$tunnel"
}

invoke_first_run() {
    ensure_token
    update_frp
    local tunnel=$(select_tunnel)
    [ -n "$tunnel" ] && start_tunnel "$tunnel"
}

invoke_returning() {
    echo "" >&2
    echo "===================================" >&2
    echo " 上次隧道: $(get_state 'last_tunnel_name')" >&2
    echo "===================================" >&2
    echo "  1) 启动上一次的隧道" >&2
    echo "  2) 切换隧道" >&2
    echo "  0) 退出" >&2
    echo "===================================" >&2
    read -p "请选择: " choice

    case "$choice" in
        1) ensure_token; update_frp; start_last ;;
        2) ensure_token; update_frp; local t=$(select_tunnel); [ -n "$t" ] && start_tunnel "$t" ;;
        0) info "退出"; return ;;
        *) warn "无效选择" ;;
    esac
}

show_banner
install_dependencies
init_state

if test_first_run; then
    invoke_first_run
else
    invoke_returning
fi