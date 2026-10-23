#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

ARG_H3=""
ARG_REALITY=""
ARG_ARGO_PROTOCOL="quic"
ARG_ARGO_PORT="8001"
ARG_ARGO_DOMAIN=""
ARG_ARGO_TOKEN=""

# 智能解析复合与关键字参数
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    if [[ "$clean_arg" =~ ^[hH]3(.*)$ ]]; then
        ARG_H3="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[rR][eE][aA][lL][iI][tT][yY](.*)$ ]]; then
        ARG_REALITY="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[pP][rR][oO][tT][oO][cC][oO][lL](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][rR][oO][tT][oO][cC][oO][lL](.*)$ ]]; then
        ARG_ARGO_PROTOCOL="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[pP][oO][rR][tT](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][rR][oO][rR][tT](.*)$ ]]; then
        ARG_ARGO_PORT="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[dD][oO][mM][aA][iI][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[dD][oO][mM][aA][iI][nN](.*)$ ]]; then
        ARG_ARGO_DOMAIN="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[tT][oO][kK][eE][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[tT][oO][kK][eE][nN](.*)$ ]]; then
        ARG_ARGO_TOKEN="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[0-9]+$ ]] || [[ "$clean_arg" =~ ^[yYnN]$ ]]; then
        if [ -z "$ARG_H3" ]; then
            ARG_H3="$clean_arg"
        elif [ -z "$ARG_REALITY" ]; then
            ARG_REALITY="$clean_arg"
        fi
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

argo_port="${ARG_ARGO_PORT:-8001}"
argo_protocol="${ARG_ARGO_PROTOCOL:-quic}"
argo_domain="${ARG_ARGO_DOMAIN}"
argo_token="${ARG_ARGO_TOKEN}"

# Argo 4个变量校验：协议、端口、域名、Token必须齐全，否则放弃Argo部署
enable_argo=false
if [ -n "$argo_port" ] && [ -n "$argo_domain" ] && [ -n "$argo_token" ] && [ -n "$argo_protocol" ]; then
    enable_argo=true
fi

if [ -z "$h3_port" ] && [ -z "$reality_port" ] && [ "$enable_argo" = false ]; then
    yellow "提示：未检测到任何有效的部署参数（H3、REALITY及Argo隧道均未启用）。"
    exit 0
fi

work_dir="/etc/xray"
[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 1. 初始化
systemctl stop xray 2>/dev/null || rc-service xray stop 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true

yellow "正在初始化系统环境..."
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip openssl iptables coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip openssl iptables coreutils >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add --no-cache bash curl wget unzip openssl iptables coreutils >/dev/null 2>&1
else
    red "未识别的系统包管理器，无法自动安装依赖！"
    exit 1
fi

# 保险校验：确保核心工具已就绪
for cmd in curl unzip openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "错误：系统缺少必要组件 [$cmd]，且自动安装失败，请手动安装后重试！"
        exit 1
    fi
done

# 2. 下载 Xray-core
yellow "正在下载 Xray-core 核心..."
mkdir -p "${work_dir}"
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64') ARCH='64' ;;
    'aarch64' | 'arm64') ARCH='arm64-v8a' ;;
    *) ARCH='64' ;;
esac

curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
unzip -qo "${work_dir}/xray.zip" -d "${work_dir}/" && rm -f "${work_dir}/xray.zip"
chmod +x ${work_dir}/xray

# 如果开启了 Argo，下载 cloudflared
if [ "$enable_argo" = true ]; then
    yellow "正在下载 Cloudflare cloudflared 二进制文件..."
    ARCH_CF=$(uname -m)
    case "${ARCH_CF}" in
        'x86_64' | 'amd64') CF_ARCH='amd64' ;;
        'aarch64' | 'arm64') CF_ARCH='arm64' ;;
        *) CF_ARCH='amd64' ;;
    esac
    curl -sLo "${work_dir}/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    chmod +x "${work_dir}/cloudflared"
fi

# 3. 生成变量、自签证书与密钥对
yellow "正在生成安全 UUID、自签证书及密钥对..."
uuid=$(cat /proc/sys/kernel/random/uuid)
h3_path="${uuid}-xu" 
argo_path="${uuid}-argo"
ym_vl_re="www.apple.com"

# H3 自签证书
openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

# Reality 密钥对
key_pair=$("${work_dir}/xray" x25519)
private_key_x=$(echo "$key_pair" | awk -F':' '/PrivateKey/ {print $2}' | xargs)
public_key_x=$(echo "$key_pair" | awk -F':' '/Password/ {print $2}' | xargs)
short_id_x=$(date +%s%N | sha256sum | cut -c 1-8)

# 4. 构建多 Inbound 配置 (TCP-Reality-Vision + H3-XHTTP + Argo-XHTTP)
yellow "正在动态构建 Xray 核心配置文件..."
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
          \"mode\": \"auto\",
          \"scMaxConcurrentStreams\": 16
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

# 5. 配置系统服务并启动
if pidof systemd >/dev/null 2>&1 || [ -d /etc/systemd/system ]; then
    yellow "正在启动 Xray..."
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
else
    yellow "正在启动 Xray..."
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray Service"
command="/etc/xray/xray"
command_args="run -config /etc/xray/config.json"
pidfile="/run/xray.pid"
command_background="yes"

depend() {
    need net
}
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart
fi

# 根据协议自动分配连接数：quic 默认 1，http2 设为 4
argo_connections="1"
argo_proto_lower=$(echo "$argo_protocol" | tr '[:upper:]' '[:lower:]')
if [ "$argo_proto_lower" = "http2" ]; then
    argo_connections="4"
fi

# 如果开启了 Argo，启动 cloudflared 后台进程
if [ "$enable_argo" = true ]; then
    yellow "正在启动 Cloudflare Argo 固定隧道 (协议: ${argo_protocol}, 连接数: ${argo_connections})..."
    nohup "${work_dir}/cloudflared" tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol "${argo_protocol}" --ha-connections "${argo_connections}" run --token "${argo_token}" > "${work_dir}/cloudflared.log" 2>&1 &
    green "Argo 固定隧道已启动。"
fi

# 6. 放行对应的防火墙端口 (仅直连端口需要放行，Argo 不需要)
yellow "正在配置防火墙端口放行规则..."
for p in "$h3_port" "$reality_port"; do
    [ -z "$p" ] && continue
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow $p/tcp >/dev/null 2>&1
        ufw allow $p/udp >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -A INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null
        iptables -A INPUT -p udp --dport $p -j ACCEPT 2>/dev/null
    fi
done

# 7. 获取 IP 并输出节点链接与 Base64 编码
yellow "正在获取服务器公网 IP 及节点订阅..."
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

isp=$(curl -sm 3 "https://api.ip.sb/geoip" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 || echo "Node")
cfip="www.teamviewer.com"
cfport="443"

> "${work_dir}/url.txt"
[ -n "$reality_port" ] && echo "vless://${uuid}@${server_ip}:${reality_port}?encryption=none&security=reality&sni=${ym_vl_re}&fp=chrome&pbk=${public_key_x}&sid=${short_id_x}&type=tcp&flow=xtls-rprx-vision#Reality Vision_easyshare" >> "${work_dir}/url.txt"
[ -n "$h3_port" ] && echo "vless://${uuid}@${server_ip}:${h3_port}?encryption=none&security=tls&sni=bing.com&alpn=h3&fp=chrome&type=xhttp&mode=auto&path=/${h3_path}&allowInsecure=1#H3-XHTTP_easyshare" >> "${work_dir}/url.txt"
if [ "$enable_argo" = true ]; then
    echo "vless://${uuid}@${cfip}:${cfport}?encryption=none&security=tls&alpn=h2&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${argo_path}#H2-Argo XHTTP_easyshare" >> "${work_dir}/url.txt"
    echo "vless://${uuid}@${cfip}:${cfport}?encryption=none&security=tls&alpn=h3&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${argo_path}#H3-Argo XHTTP_easyshare" >> "${work_dir}/url.txt"
fi

base64_str=$(cat "${work_dir}/url.txt" | base64 | tr -d '\n' | tr -d '\r')

clear
green "=========================================================================================="
green " Base64 节点链接-Xray (REALITY/XHTTP) "
green "=========================================================================================="
green "$base64_str"
green "=========================================================================================="
