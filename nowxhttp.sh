#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

# Github Cloudflare安全代理
GITHUB_PROXY=('https://ess.ieshare.workers.dev/')
download_file() {
    local output_path="$1"
    local official_url="$2"
    
    echo "连接Github官方源中..."
    if curl -sL --connect-timeout 5 --max-time 60 -o "$output_path" "$official_url"; then
        if [ -s "$output_path" ]; then
            green "下载成功！"
            return 0
        fi
    fi
    
    yellow "Github连接失败，转向Cloudflare安全代理..."
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

# 精准关键字参数解析
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    if [[ "$clean_arg" =~ ^[hH]3([yYnN0-9]+) ]]; then
        ARG_H3="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[rR][eE][aA][lL][iI][tT][yY]([yYnN0-9]+) ]]; then
        ARG_REALITY="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[nN][oO][wW]([yYnN0-9]+) ]]; then
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
[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 1. 初始化
systemctl stop xray 2>/dev/null || rc-service xray stop 2>/dev/null || true
systemctl stop nowhere 2>/dev/null || rc-service nowhere stop 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true

green "正在初始化环境，请耐心等待..."
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip tar openssl iptables coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip tar openssl iptables coreutils >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add --no-cache bash curl wget unzip tar openssl iptables coreutils >/dev/null 2>&1
else
    red "未识别的系统包管理器，无法自动安装依赖！"
    exit 1
fi

# 2. 条件化下载核心组件
needs_xray=false
if [ -n "$h3_port" ] || [ -n "$reality_port" ] || [ "$enable_argo" = true ]; then
    needs_xray=true
fi

if [ "$needs_xray" = true ]; then
    echo "正在下载 Xray-core..."
    mkdir -p "${work_dir}"
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64') ARCH='64' ;;
        'aarch64' | 'arm64') ARCH='arm64-v8a' ;;
        *) ARCH='64' ;;
    esac

    download_file "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip" || exit 1
    unzip -qo "${work_dir}/xray.zip" -d "${work_dir}/" && rm -f "${work_dir}/xray.zip"
    chmod +x ${work_dir}/xray
fi

if [ -n "$nowhere_port" ]; then
    echo "正在下载 Nowhere 核心..."
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

if [ "$enable_argo" = true ]; then
    echo "正在下载 Cloudflared..."
    ARCH_CF=$(uname -m)
    case "${ARCH_CF}" in
        'x86_64' | 'amd64') CF_ARCH='amd64' ;;
        'aarch64' | 'arm64') CF_ARCH='arm64' ;;
        *) CF_ARCH='amd64' ;;
    esac
    download_file "${work_dir}/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" || exit 1
    chmod +x "${work_dir}/cloudflared"
fi

# 3. 生成变量、自签证书与密钥对
echo "生成安全密钥及配置..."
uuid=$(cat /proc/sys/kernel/random/uuid)
# 生成 32 位小写 hex 密钥，适配 Nowhere v3.3.0 要求
nowhere_key=$(${nowhere_dir}/nowhere generate-key 2>/dev/null || openssl rand -hex 16)

h3_path="${uuid}-xu" 
argo_path="${uuid}-argo"
ym_vl_re="www.apple.com"

if [ "$needs_xray" = true ]; then
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

    key_pair=$("${work_dir}/xray" x25519)
    private_key_x=$(echo "$key_pair" | awk -F':' '/PrivateKey/ {print $2}' | xargs)
    public_key_x=$(echo "$key_pair" | awk -F':' '/Password/ {print $2}' | xargs)
    short_id_x=$(date +%s%N | sha256sum | cut -c 1-8)
fi

# 4. 构建多 Inbound 配置 (仅当 Xray 启用时)
if [ "$needs_xray" = true ]; then
    inbounds_arr=()

    if [ -n "$reality_port" ]; then
        inbounds_arr+=( "{
          \"tag\": \"tcp-reality\",
          \"listen\": \"::\",
          \"port\": $reality_port,
          \"protocol\": \"vless\",
          \"settings\": {
            \"clients\": [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}],
            \"decryption\": \"none\"
          },
          \"streamSettings\": {
            \"network\": \"tcp\",
            \"security\": \"reality\",
            \"realitySettings\": {
              \"fingerprint\": \"chrome\",
              \"target\": \"$ym_vl_re:443\",
              \"serverNames\": [\"$ym_vl_re\"],
              \"privateKey\": \"$private_key_x\",
              \"shortIds\": [\"$short_id_x\"]
            }
          },
          \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"metadataOnly\": false}
        }" )
    fi

    if [ -n "$h3_port" ]; then
        inbounds_arr+=( "{
          \"tag\": \"xhttp-h3\",
          \"listen\": \"::\",
          \"port\": $h3_port,
          \"protocol\": \"vless\",
          \"settings\": {
            \"clients\": [{\"id\": \"$uuid\", \"flow\": \"\"}],
            \"decryption\": \"none\"
          },
          \"streamSettings\": {
            \"network\": \"xhttp\",
            \"security\": \"tls\",
            \"xhttpSettings\": {
              \"mode\": \"auto\",
              \"path\": \"/$h3_path\"
            },
            \"tlsSettings\": {
              \"alpn\": [\"h3\"],
              \"certificates\": [{\"certificateFile\": \"$work_dir/cert.pem\", \"keyFile\": \"$work_dir/private.key\"}]
            }
          },
          \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"metadataOnly\": false}
        }" )
    fi

    if [ "$enable_argo" = true ]; then
        inbounds_arr+=( "{
          \"tag\": \"xhttp-argo\",
          \"listen\": \"127.0.0.1\",
          \"port\": $argo_port,
          \"protocol\": \"vless\",
          \"settings\": {
            \"clients\": [{\"id\": \"$uuid\"}],
            \"decryption\": \"none\"
          },
          \"streamSettings\": {
            \"network\": \"xhttp\",
            \"security\": \"none\",
            \"xhttpSettings\": {
              \"path\": \"/$argo_path\",
              \"mode\": \"auto\"
            }
          },
          \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"metadataOnly\": false}
        }" )
    fi

    inbounds_json=$(IFS=,; echo "${inbounds_arr[*]}")

    cat > "${work_dir}/config.json" << EOF
{
  "log": {
    "loglevel": "warning",
    "error": "${work_dir}/xray.log"
  },
  "inbounds": [
    $inbounds_json
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF
fi

# 5. 配置系统服务并启动
if pidof systemd >/dev/null 2>&1 || [ -d /etc/systemd/system ]; then
    if [ "$needs_xray" = true ]; then
        green "正在启动 Xray-core..."
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${work_dir}/xray run -config ${work_dir}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now xray
    fi

    if [ -n "$nowhere_port" ]; then
        green "正在启动 Nowhere 协议服务 (v3.3.0 URL 传参模式)..."
        # 使用 v3.3.0 规范的 URL 启动格式：nowhere <portal-url>
        cat > /etc/systemd/system/nowhere.service << EOF
[Unit]
Description=Nowhere Proxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${nowhere_dir}
ExecStart=${nowhere_dir}/nowhere nowhere://${nowhere_key}@0.0.0.0:${nowhere_port}?morph=1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now nowhere
    fi
fi

# 6. 获取 IP 并输出节点链接与 Base64 编码
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

> "${work_dir}/url.txt"
if [ -n "$nowhere_port" ]; then
    # 直接生成标准可导入的 socks5 链接 (格式: socks5://user:pass@ip:port 或 socks5://ip:port)
    echo "socks5://${server_ip}:${nowhere_port}?encryption=none#Nowhere-SOCKS5" >> "${work_dir}/url.txt"
fi

base64_str=$(cat "${work_dir}/url.txt" | base64 | tr -d '\n' | tr -d '\r')

clear
green "=========================================================================================="
green " Base64 节点链接 (Nowhere v3.3.0 完整支持版) "
green "=========================================================================================="
green "$base64_str"
[ -n "$nowhere_port" ] && yellow "提示：Nowhere 服务已成功启动！运行端口: $nowhere_port，SOCKS5 链接已就绪。"
green "=========================================================================================="
