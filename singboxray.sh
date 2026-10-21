#!/usr/bin/env bash
export LANG=en_US.UTF-8

# =========================================================================
# 参数映射：
# $1: nvpt -> NaiveProxy 直连 ("y"=随机端口，数字=指定端口，""/n=不部署)
# $2: xhpt -> Xray xhttp 直连 ("y"=随机端口，数字=指定端口，""/n=不部署)
# $3: ARGO_PORT -> Argo 回源端口 (留空则默认 8001)
# $4: ARGO_DOMAIN -> Argo 固定隧道域名 (必须有 Domain + Token 才会部署 Argo)
# $5: ARGO_AUTH -> Argo 固定隧道 Token
# =========================================================================

nvpt="${1:-}"
xhpt="${2:-}"
ARGO_PORT="${3:-8001}"
ARGO_DOMAIN="${4:-}"
ARGO_AUTH="${5:-}"

ARGO_PROTOCOL="${ARGO_PROTOCOL:-quic}"      
ARGO_CONNECTIONS="${ARGO_CONNECTIONS:-1}"   
CFIP="${CFIP:-www.teamviewer.com}"          
CFPORT="${CFPORT:-443}"                     

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# 检查权限
[ "$EUID" -ne 0 ] && error "请使用 root 权限运行此脚本！"

case $(uname -m) in
    arm64|aarch64) cpu=arm64 ;;
    amd64|x86_64) cpu=amd64 ;;
    *) error "目前脚本不支持 $(uname -m) 架构" ;;
esac

INSTALL_DIR="/etc/easyshare"
mkdir -p "$INSTALL_DIR/cert"
cd "$INSTALL_DIR" || exit

info "检查并安装基础依赖..."
if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1 && apk add --no-cache bash curl wget openssl jq >/dev/null 2>&1
elif command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update >/dev/null 2>&1 && apt install -y curl wget openssl jq ca-certificates >/dev/null 2>&1
fi

get_public_ip() {
    local ip
    ip=$(curl -s4m 3 https://api.ipify.org || curl -s4m 3 https://ipv4.icanhazip.com)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}
PUBLIC_IP=$(get_public_ip)

if [ ! -f "uuid.txt" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)
    echo "$UUID" > uuid.txt
else
    UUID=$(cat uuid.txt)
fi
UUID=$(echo "$UUID" | tr '[:upper:]' '[:lower:]')
XHTTP_PATH="/${UUID}-xhttp"

# 【安全进程清理】使用 -x 精确匹配，防止把当前 Shell 脚本杀掉
info "清理残留进程..."
systemctl stop singbox xray cloudflared 2>/dev/null
pkill -9 -x sing-box 2>/dev/null
pkill -9 -x xray 2>/dev/null
pkill -9 -x cloudflared 2>/dev/null

SB_VER="1.11.4"
XRAY_VER="25.1.30"

# 下载 Sing-box (用于 NaiveProxy)
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ ! -f "sing-box" ]; then
        info "正在下载 Sing-box v$SB_VER..."
        curl -L -o singbox.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
        tar -xzf singbox.tar.gz --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf singbox.tar.gz sing-box 2>/dev/null
        [ -f "sing-box" ] && chmod +x sing-box || error "Sing-box 下载失败"
        rm -f singbox.tar.gz
    fi
fi

# 下载 Xray-core (用于 xhttp 直连或 Argo 隧道)
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

# 下载 Cloudflared
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    if [ ! -f "cloudflared" ]; then
        info "正在下载 Cloudflared..."
        curl -L -o cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
        chmod +x cloudflared || error "Cloudflared 下载失败"
    fi
fi

# 生成自签 TLS 证书
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
# 1. 配置 NaiveProxy 直连 (Sing-box)
# =========================================================================
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ "$nvpt" = "y" ] \vert{}\vert{} [ "$nvpt" = "Y" ]; then
        NAIVE_PORT=$(shuf -i 10000-65535 -n 1)
    else
        NAIVE_PORT="$nvpt"
    fi
    
    info "已启用 NaiveProxy (Sing-box)，监听端口: $NAIVE_PORT"
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
# 2. 配置 Xray xHTTP 直连 或 Argo 回源
# =========================================================================
XRAY_INBOUNDS=""

# 直连 xHTTP 节点
if [ -n "$xhpt" ] && [ "$xhpt" != "n" ] && [ "$xhpt" != "N" ]; then
    if [ "$xhpt" = "y" ] \vert{}\vert{} [ "$xhpt" = "Y" ]; then
        XHTTP_PORT=$(shuf -i 10000-65535 -n 1)
    else
        XHTTP_PORT="$xhpt"
    fi
    
    info "已启用 Xray xHTTP 直连，监听端口: $XHTTP_PORT"
    HAS_XRAY=true
    
    XHTTP_DIRECT_INBOUND=$(cat <<EOF
    {
      "port": ${XHTTP_PORT},
      "listen": "::",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3", "h2"],
          "certificates": [{
            "certificateFile": "$INSTALL_DIR/cert/cert.pem",
            "keyFile": "$INSTALL_DIR/cert/private.key"
          }]
        },
        "xhttpSettings": {
          "path": "/${UUID}-direct",
          "mode": "auto"
        }
      }
    }
EOF
)
    XRAY_INBOUNDS="$XHTTP_DIRECT_INBOUND"
    
    DIRECT_H2="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h2&sni=bing.com&fp=chrome&type=xhttp&mode=auto&path=\%2F${UUID}-direct&allowInsecure=1#xHTTP_Direct_H2"
    DIRECT_H3="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h3&sni=bing.com&fp=chrome&type=xhttp&mode=auto&path=\%2F${UUID}-direct&allowInsecure=1#xHTTP_Direct_H3"
    GLOBAL_LINKS+="$DIRECT_H2\n$DIRECT_H3\n"
fi

# Argo 隧道回源节点
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    HAS_XRAY=true
    info "已启用 Xray xHTTP (Argo 隧道回源)，监听端口: $ARGO_PORT"
    
    ARGO_INBOUND=$(cat <<EOF
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
EOF
)
    if [ -n "$XRAY_INBOUNDS" ]; then
        XRAY_INBOUNDS="$XRAY_INBOUNDS,$ARGO_INBOUND"
    else
        XRAY_INBOUNDS="$ARGO_INBOUND"
    fi

    ARGO_LINK_H2="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h2&sni=${ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${ARGO_DOMAIN}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H2"
    ARGO_LINK_H
