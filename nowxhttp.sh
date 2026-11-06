#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

# Github Cloudflare 安全代理
GITHUB_PROXY=('https://ess.ieshare.workers.dev/')
download_file() {
    local output_path="$1"
    local official_url="$2"
    
    echo "连接 Github 官方源中..."
    if curl -sL --connect-timeout 5 --max-time 60 -o "$output_path" "$official_url"; then
        if [ -s "$output_path" ]; then
            green "下载成功！"
            return 0
        fi
    fi
    
    yellow "Github 连接失败，转向 Cloudflare 安全代理..."
    for proxy in "${GITHUB_PROXY[@]}"; do
        local proxy_url="${proxy}${official_url}"
        if curl -sL --connect-timeout 5 --max-time 60 -o "$output_path" "$proxy_url"; then
            if [ -s "$output_path" ]; then
                green "下载成功！"
                return 0
            fi
        fi
    done
    
    red "错误：官方源及镜像代理下载均告失败！"
    return 1
}

ARG_H3=""
ARG_REALITY=""
ARG_NOWHERE=""
ARG_ARGO_PROTOCOL="quic"
ARG_ARGO_PORT="8001"
ARG_ARGO_DOMAIN=""
ARG_ARGO_TOKEN=""

# 参数解析（恢复兼容带引号及灵活写法的匹配逻辑）
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    if [[ "$clean_arg" =~ ^[hH]3(.*)$ ]]; then
        ARG_H3="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[rR][eE][aA][lL][iI][tT][yY](.*)$ ]]; then
        ARG_REALITY="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[nN][oO][wW](.*)$ ]]; then
        ARG_NOWHERE="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[pP][rR][oO][tT][oO][cC][oO][lI](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][rR][oO][tT][oO][cC][oO][lI](.*)$ ]]; then
        ARG_ARGO_PROTOCOL="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[pP][oO][rR][tT](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][rR][oO][rR][tT](.*)$ ]]; then
        ARG_ARGO_PORT="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[dD][oO][mM][aA][iI][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[dD][oO][mM][aA][iI][nN](.*)$ ]]; then
        ARG_ARGO_DOMAIN="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[tT][oO][kK][eE][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[tT][oO][kK][eE][nN](.*)$ ]]; then
        ARG_ARGO_TOKEN="${BASH_REMATCH[1]}"
    fi
done

parse_port() {
    local input="$1"
    [ -z "$input" ] && echo "" && return
    if [ "$input" = "n" ] || [ "$input" = "N" ]; then
        echo ""
    elif [ "$input" = "y" ] || [ "$input" = "Y" ]; then
        shuf -i 1000-65000 -n 1
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        echo ""
    fi
}

h3_port=$(parse_port "$ARG_H3")
reality_port=$(parse_port "$ARG_REALITY")
nowhere_port=$(parse_port "$ARG_NOWHERE")

argo_port="${ARG_ARGO_PORT:-8001}"
argo_protocol="${ARG_ARGO_PROTOCOL:-quic}"
argo_domain="${ARG_ARGO_DOMAIN}"
argo_token="${ARG_ARGO_TOKEN}"

enable_argo=false
if [ -n "$argo_port" ] && [ -n "$argo_domain" ] && [ -n "$argo_token" ] && [ -n "$argo_protocol" ]; then
    enable_argo=true
fi

if [ -z "$h3_port" ] && [ -z "$reality_port" ] && [ -z "$nowhere_port" ] && [ "$enable_argo" = false ]; then
    yellow "提示：未检测到任何有效变量。"
    exit 0
fi

work_dir="/etc/xray"
nowhere_dir="/etc/nowhere"
[[ $EUID -ne 0 ]] && red "请在 root 用户下运行" && exit 1

# 1. 初始化清理
systemctl stop xray 2>/dev/null || true
systemctl stop nowhere 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true

green "正在初始化系统环境..."
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip tar openssl iptables coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip tar openssl iptables coreutils >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add --no-cache bash curl wget unzip tar openssl iptables coreutils >/dev/null 2>&1
fi

# 2. 下载组件
if [ -n "$nowhere_port" ]; then
    echo "正在下载 Nowhere v3.3.0 核心..."
    mkdir -p "${nowhere_dir}"
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64') NW_FILE="nowhere-x86_64-unknown-linux-gnu.tar.gz" ;;
        'aarch64' | 'arm64') NW_FILE="nowhere-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) NW_FILE="nowhere-x86_64-unknown-linux-gnu.tar.gz" ;;
    esac
    download_file "${nowhere_dir}/nowhere.tar.gz" "https://github.com/NodePassProject/nowhere/releases/latest/download/${NW_FILE}" || exit 1
    tar -zxvf "${nowhere_dir}/nowhere.tar.gz" -C "${nowhere_dir}/" && rm -f "${nowhere_dir}/nowhere.tar.gz"
    chmod +x "${nowhere_dir}/nowhere"
fi

# 3. 创建 Nowhere 启动包装脚本 (使用 portal:// 协议头)
if [ -n "$nowhere_port" ]; then
    echo "生成 Nowhere 启动引导脚本..."
    nowhere_key=$(${nowhere_dir}/nowhere generate-key)
    
    cat > "${nowhere_dir}/start.sh" << EOF
#!/bin/bash
exec ${nowhere_dir}/nowhere portal://${nowhere_key}@0.0.0.0:${nowhere_port}?morph=1
EOF
    chmod +x "${nowhere_dir}/start.sh"

    # 配置 systemd 服务
    cat > /etc/systemd/system/nowhere.service << EOF
[Unit]
Description=Nowhere Proxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${nowhere_dir}
ExecStart=${nowhere_dir}/start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now nowhere
fi

# 4. 获取服务器 IP 并生成直连链接
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

socks_link="socks5://${server_ip}:${nowhere_port}?encryption=none#Nowhere-SOCKS5"
base64_str=$(echo -n "$socks_link" | base64 | tr -d '\n' | tr -d '\r')

clear
green "=========================================================================================="
green " Nowhere v3.3.0 部署成功！"
green "=========================================================================================="
green "【SOCKS5 明文链接】:"
yellow "$socks_link"
green ""
green "【Base64 编码链接】:"
yellow "$base64_str"
green "=========================================================================================="
