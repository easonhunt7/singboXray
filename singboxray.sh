#!/usr/bin/env bash
export LANG=en_US.UTF-8

# =========================================================================
# 通过命令行位置参数接收变量映射：
# $1: nvpt -> NaiveProxy 直连 ("y"=随机端口，数字=指定端口，""=不部署)
# $2: xhpt -> Xray xhttp 直连 ("y"=随机端口，数字=指定端口，""=不部署)
# $3: ARGO_PORT -> Argo 回源端口 (留空则默认 8001)
# $4: ARGO_DOMAIN -> Argo 固定隧道域名 (必须有 Domain + Token 才会部署 Argo)
# $5: ARGO_AUTH -> Argo 固定隧道 Token
# =========================================================================

nvpt="${1:-}"
xhpt="${2:-}"
ARGO_PORT="${3:-8001}"
ARGO_DOMAIN="${4:-}"
ARGO_AUTH="${5:-}"

ARGO_PROTOCOL="${ARGO_PROTOCOL:-quic}"      # 默认 quic
ARGO_CONNECTIONS="${ARGO_CONNECTIONS:-1}"   # 默认连接数
CFIP="${CFIP:-www.teamviewer.com}"          # 优选域名
CFPORT="${CFPORT:-443}"                     # 客户端连接端口

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# 检查权限
[ "$EUID" -ne 0 ] && error "请使用 root 权限运行此脚本！(例如: sudo ./singboxray.sh ...)"

# 系统架构判断
case $(uname -m) in
    arm64|aarch64) cpu=arm64 ;;
    amd64|x86_64) cpu=amd64 ;;
    *) error "目前脚本不支持 $(uname -m) 架构" ;;
esac

INSTALL_DIR="/etc/easyshare"
mkdir -p "$INSTALL_DIR/cert"
cd "$INSTALL_DIR" || exit

# 安装基础依赖
info "检查并安装基础依赖..."
if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1 && apk add --no-cache bash curl wget openssl jq >/dev/null 2>&1
elif command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update >/dev/null 2>&1 && apt install -y curl wget openssl jq ca-certificates >/dev/null 2>&1
fi

# 获取公网 IP
get_public_ip() {
    local ip
    ip=$(curl -s4m 3 https://api.ipify.org || curl -s4m 3 https://ipv4.icanhazip.com)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}
PUBLIC_IP=$(get_public_ip)

# 生成 UUID 与固定密钥
if [ ! -f "uuid.txt" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)
    echo "$UUID" > uuid.txt
else
    UUID=$(cat uuid.txt)
fi
UUID=$(echo "$UUID" | tr '[:upper:]' '[:lower:]')
XHTTP_PATH="/${UUID}-xhttp"

# 停止旧进程
info "清理残留进程..."
systemctl stop singbox xray cloudflared 2>/dev/null
pkill -9 -f sing-box 2>/dev/null
pkill -9 -f xray 2>/dev/null
pkill -9 -f cloudflared 2>/dev/null

# 内核版本定义
SB_VER="1.11.4"
XRAY_VER="25.1.30"

# 下载 Sing-box (如果启用了 naiveproxy)
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ ! -f "sing-box" ]; then
        info "正在下载 Sing-box v$SB_VER..."
        curl -L -o singbox.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
        tar -xzf singbox.tar.gz --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf singbox.tar.gz sing-box 2>/dev/null
        [ -f "sing-box" ] && chmod +x sing-box || error "Sing-box 下载失败"
        rm -f singbox.tar.gz
    fi
fi

# 下载 Xray-core (如果启用了 xhttp 直连或 argo 隧道)
if ([ -n "$xhpt" ] && [ "$xhpt" != "n" ] && [ "$xhpt" != "N" ]) || ([ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]); then
    if [ ! -f "xray" ]; then
        info "正在下载 Xray-core v$XRAY_VER..."
        XRAY_CPU_ARCH="64"
        [ "$cpu" = "arm64" ] && XRAY_CPU_ARCH="arm64-v8a"
        curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${XRAY_CPU_ARCH}.zip"
        if command -v python3 &>/dev/null; then
            python3 -c "import zipfile; zipfile.ZipFile('xray.zip').extract('xray', '.')"
        elif command -v unzip &>/dev/null; then
            unzip -qo xray.zip xray
        else
            error "系统中缺少 unzip 或 python3，无法解压 Xray！"
        fi
        [ -f "xray" ] && chmod +x xray || error "Xray 下载失败"
        rm -f xray.zip
    fi
fi

# 下载 Cloudflared (如果完整提供了 Argo 变量)
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    if [ ! -f "cloudflared" ]; then
        info "正在下载 Cloudflared..."
        curl -L -o cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
        chmod +x cloudflared || error "Cloudflared 下载失败"
    fi
fi

# 生成自签 TLS 证书（NaiveProxy 及 H2/H3 需要）
if [ ! -f "cert/cert.pem" ] || [ ! -f "cert/private.key" ]; then
    info "正在生成自签名 TLS 证书..."
    openssl ecparam -genkey -name prime256v1 -out cert/private.key 2>/dev/null
    openssl req -new -x509 -days 3650 -key cert/private.key -out cert/cert.pem -subj "/CN=bing.com" 2>/dev/null
    chmod 600 cert/private.key
fi

GLOBAL_LINKS=""
HAS_SINGBOX=false
HAS_XRAY=false

# =========================================================================
# 1. 部署 Sing-box: NaiveProxy (h2/h3)
# =========================================================================
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ "$nvpt" = "y" ] \vert{}\vert{} [ "$nvpt" = "Y" ]; then
        NAIVE_PORT=$(shuf -i 10000-65535 -n 1)
    else
        NAIVE_PORT="$nvpt"
    fi
    
    info "已启用 NaiveProxy (Sing-box 内核)，监听端口: $NAIVE_PORT"
    HAS_SINGBOX=true
    
cat > singbox_config.json <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": ${NAIVE_PORT},
      "users": [
        {
          "username": "${UUID}",
          "password": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$INSTALL_DIR/cert/cert.pem",
        "key_path": "$INSTALL_DIR/cert/private.key",
        "alpn": ["h3", "h2"]
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    NAIVE_LINK="naive+https://${UUID}:${UUID}@${PUBLIC_IP}:${NAIVE_PORT}?sni=bing.com&alpn=h3,h2&allowInsecure=1#NaiveProxy_Direct"
    GLOBAL_LINKS+="$NAIVE_LINK\n"
fi

# =========================================================================
# 2. 部署 Xray: xHTTP 固定隧道 (Argo)
# =========================================================================
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    HAS_XRAY=true
    info "检测到完整的 Argo 隧道变量，准备配置 Xray xhttp 回源..."

cat > xray_config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": ${ARGO_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto",
          "scMaxConcurrentStreams": 16
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

    ARGO_LINK_H2="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h2&sni=${ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${ARGO_DOMAIN}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H2"
    ARGO_LINK_H3="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h3&sni=${ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${ARGO_DOMAIN}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H3"
    GLOBAL_LINKS+="$ARGO_LINK_H2\n$ARGO_LINK_H3\n"
else
    warn "Argo 隧道变量不完整（DOMAIN 与 AUTH 必须同时具备），已放弃部署 Argo 隧道。"
fi

# =========================================================================
# 启动系统服务守护 (Systemd)
# =========================================================================
if [ "$HAS_SINGBOX" = true ]; then
    cat <<EOF > /etc/systemd/system/singbox.service
[Unit]
Description=Sing-box Service (NaiveProxy)
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/sing-box run -c$INSTALL_DIR/singbox_config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now singbox
    info "Sing-box 服务已成功启动！"
fi

if [ "$HAS_XRAY" = true ]; then
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service (Argo xHTTP)
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/xray run -c$INSTALL_DIR/xray_config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel Service
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/cloudflared tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol${ARGO_PROTOCOL} --ha-connections ${ARGO_CONNECTIONS} run --token${ARGO_AUTH}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray
    systemctl enable --now cloudflared
    info "Xray 与 Cloudflared 隧道服务已成功启动！"
fi
