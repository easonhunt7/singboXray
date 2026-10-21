#!/usr/bin/env bash
export LANG=en_US.UTF-8

# =========================================================================
# 一键无交互入参映射：
# $1: nvpt -> NaiveProxy 直连 ("y"=随机端口，数字=指定端口，""/n=不部署)
# $2: xhpt -> Xray xHTTP 直连 ("y"=随机端口，数字=指定端口，""/n=不部署)
# $3: ARGO_PORT -> Argo 回源端口 (默认 8001)
# $4: ARGO_DOMAIN -> Argo 固定隧道域名 (必须与 AUTH 同时具备才部署)
# $5: ARGO_AUTH -> Argo 固定隧道 Token (必须与 DOMAIN 同时具备才部署)
# =========================================================================
nvpt="${1:-}"
xhpt="${2:-}"
ARGO_PORT="${3:-8001}"
ARGO_DOMAIN="${4:-}"
ARGO_AUTH="${5:-}"

ARGO_PROTOCOL="${ARGO_PROTOCOL:-quic}"      # quic 或 http2
ARGO_CONNECTIONS="${ARGO_CONNECTIONS:-1}"   # 隧道连接数
CFIP="${CFIP:-www.teamviewer.com}"          # 优选域名
CFPORT="${CFPORT:-443}"                     # 客户端连接端口

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && error "请使用 root 权限运行此脚本！"

# 1. 严谨的架构识别（参考甬哥逻辑）
case $(uname -m) in
    arm64|aarch64) cpu=arm64; x_cpu="arm64-v8a" ;;
    amd64|x86_64) cpu=amd64; x_cpu="64" ;;
    *) error "目前脚本不支持 $(uname -m) 架构" ;;
esac

INSTALL_DIR="/etc/easyshare"
mkdir -p "$INSTALL_DIR/cert"
cd "$INSTALL_DIR" || exit

# 2. 完美的多系统包管理器兼容与依赖补全（参考甬哥逻辑）
info "检查并补全系统必要依赖..."
if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1 && apk add --no-cache bash curl wget openssl jq coreutils util-linux >/dev/null 2>&1
elif command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update >/dev/null 2>&1 && apt install -y curl wget openssl jq coreutils util-linux ca-certificates >/dev/null 2>&1
fi

# 获取公网 IP（双保险）
get_public_ip() {
    local ip
    ip=$(curl -s4m 3 https://api.ipify.org || wget -4qO- https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}
PUBLIC_IP=$(get_public_ip)

# UUID 与回源路径生成（完全对齐原始 index.js 逻辑）
if [ ! -f "uuid.txt" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)
    echo "$UUID" > uuid.txt
else
    UUID=$(cat uuid.txt)
fi
UUID=$(echo "$UUID" | tr '[:upper:]' '[:lower:]')
XHTTP_PATH="/${UUID}-xhttp"

# 3. 安全清理旧进程（精确匹配 -x，绝不自杀）
info "清理残留进程..."
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop singbox xray cloudflared 2>/dev/null
fi
pkill -9 -x sing-box 2>/dev/null
pkill -9 -x xray 2>/dev/null
pkill -9 -x cloudflared 2>/dev/null

SB_VER="1.11.4"
XRAY_VER="25.1.30"

# 4. 双保险内核下载函数（CURL / WGET 自动切换，参考甬哥逻辑）
download_file() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$output" -# --retry 2 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" --tries=2 "$url"
    else
        error "系统中未找到 curl 或 wget，无法下载文件！"
    fi
}

# 条件下载 Sing-box (NaiveProxy)
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ ! -f "sing-box" ]; then
        info "正在下载 Sing-box v$SB_VER..."
        download_file "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz" "singbox.tar.gz"
        tar -xzf singbox.tar.gz --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf singbox.tar.gz sing-box 2>/dev/null
        [ -f "sing-box" ] && chmod +x sing-box || error "Sing-box 下载或解压失败"
        rm -f singbox.tar.gz
    fi
fi

# 条件下载 Xray-core (xHTTP 直连或 Argo 回源)
ENABLE_ARGO=false
domainTrim="$(echo "$ARGO_DOMAIN" | xargs)"
authTrim="$(echo "$ARGO_AUTH" | xargs)"
portTrim="$(echo "$ARGO_PORT" | xargs)"

if [ -n "$portTrim" ] && [ "$portTrim" != "0" ] && [ -n "$domainTrim" ] && [ "${#authTrim}" -gt 30 ]; then
    ENABLE_ARGO=true
fi

if ([ -n "$xhpt" ] && [ "$xhpt" != "n" ] && [ "$xhpt" != "N" ]) \vert{}\vert{} [ "$ENABLE_ARGO" = true ]; then
    if [ ! -f "xray" ]; then
        info "正在下载 Xray-core v$XRAY_VER..."
        download_file "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${x_cpu}.zip" "xray.zip"
        if command -v python3 &>/dev/null; then
            python3 -c "import zipfile; zipfile.ZipFile('xray.zip').extract('xray', '.')"
        elif command -v unzip &>/dev/null; then
            unzip -qo xray.zip xray
        else
            error "系统中缺少 unzip 或 python3，无法解压 Xray！"
        fi
        [ -f "xray" ] && chmod +x xray || error "Xray 下载或解压失败"
        rm -f xray.zip
    fi
fi

# 条件下载 Cloudflared (Argo 隧道)
if [ "$ENABLE_ARGO" = true ]; then
    if [ ! -f "cloudflared" ]; then
        info "正在下载 Cloudflared..."
        download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}" "cloudflared"
        chmod +x cloudflared || error "Cloudflared 下载失败"
    fi
fi

# 生成自签 TLS 证书（用于 NaiveProxy 及直连 H2/H3）
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
# 5. 配置生成模块
# =========================================================================
# 处理 NaiveProxy (Sing-box)
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ "$nvpt" = "y" ] \vert{}\vert{} [ "$nvpt" = "Y" ]; then
        NAIVE_PORT=$(shuf -i 10000-65535 -n 1)
    else
        NAIVE_PORT="$nvpt"
    fi
    info "已配置 NaiveProxy (Sing-box)，监听端口: $NAIVE_PORT"
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
      "users": [{ "username": "${UUID}", "password": "${UUID}" }],
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
    GLOBAL_LINKS+="naive+https://${UUID}:${UUID}@${PUBLIC_IP}:${NAIVE_PORT}?sni=bing.com&alpn=h3,h2&allowInsecure=1#NaiveProxy_Direct\n"
fi

XRAY_INBOUNDS=""

# 处理 Xray xHTTP 直连
if [ -n "$xhpt" ] && [ "$xhpt" != "n" ] && [ "$xhpt" != "N" ]; then
    if [ "$xhpt" = "y" ] \vert{}\vert{} [ "$xhpt" = "Y" ]; then
        XHTTP_PORT=$(shuf -i 10000-65535 -n 1)
    else
        XHTTP_PORT="$xhpt"
    fi
    info "已配置 Xray xHTTP 直连，监听端口: $XHTTP_PORT"
    HAS_XRAY=true
    
    XHTTP_DIRECT_INBOUND=$(cat <<EOF
    {
      "port": ${XHTTP_PORT},
      "listen": "::",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3", "h2"],
          "certificates": [{ "certificateFile": "$INSTALL_DIR/cert/cert.pem", "keyFile": "$INSTALL_DIR/cert/private.key" }]
        },
        "xhttpSettings": { "path": "/${UUID}-direct", "mode": "auto" }
      }
    }
EOF
)
    XRAY_INBOUNDS="$XHTTP_DIRECT_INBOUND"
    GLOBAL_LINKS+="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h2&sni=bing.com&fp=chrome&type=xhttp&mode=auto&path=\%2F${UUID}-direct&allowInsecure=1#xHTTP_Direct_H2\n"
    GLOBAL_LINKS+="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h3&sni=bing.com&fp=chrome&type=xhttp&mode=auto&path=\%2F${UUID}-direct&allowInsecure=1#xHTTP_Direct_H3\n"
fi

# 处理 Argo 固定隧道回源 (必须 PORT + DOMAIN + AUTH 齐全)
if [ "$ENABLE_ARGO" = true ]; then
    HAS_XRAY=true
    info "已启用 Xray xHTTP (Argo 固定隧道回源)，监听本地端口: $ARGO_PORT"
    
    ARGO_INBOUND=$(cat <<EOF
    {
      "port": ${ARGO_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "auto", "scMaxConcurrentStreams": 16 }
      }
    }
EOF
)
    if [ -n "$XRAY_INBOUNDS" ]; then
        XRAY_INBOUNDS="$XRAY_INBOUNDS,$ARGO_INBOUND"
    else
        XRAY_INBOUNDS="$ARGO_INBOUND"
    fi

    GLOBAL_LINKS+="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h2&sni=${domainTrim}&fp=chrome&type=xhttp&mode=auto&host=${domainTrim}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H2\n"
    GLOBAL_LINKS+="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h3&sni=${domainTrim}&fp=chrome&type=xhttp&mode=auto&host=${domainTrim}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H3\n"
else
    warn "Argo 隧道变量不完整（必须同时具备 PORT、DOMAIN、AUTH 且 Token 长度 > 30），已放弃部署 Argo 隧道。"
fi

if [ "$HAS_XRAY" = true ]; then
cat > xray_config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [ $XRAY_INBOUNDS ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
fi

# =========================================================================
# 6. 服务启动逻辑（Systemd 与后台守护自适应）
# =========================================================================
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    [ "$HAS_SINGBOX" = true ] && cat <<EOF > /etc/systemd/system/singbox.service
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

    [ "$HAS_XRAY" = true ] && cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service (xHTTP)
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/xray run -c$INSTALL_
