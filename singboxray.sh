#!/usr/bin/env bash
export LANG=en_US.UTF-8

# =========================================================================
# 参数接收 (兼容甬哥的一键无交互逻辑)
# $1: nvpt -> NaiveProxy (填 "y" 或 端口号)
# $2: xhpt -> Xray xHTTP 直连 (填 "y" 或 端口号)
# $3: ARGO_PORT -> Argo 回源端口 (默认 8001)
# $4: ARGO_DOMAIN -> Argo 域名
# $5: ARGO_AUTH -> Argo Token
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && error "请使用 root 权限运行此脚本！"

# 1. 架构判断 (参考甬哥逻辑)
case $(uname -m) in
    arm64|aarch64) cpu=arm64 ;;
    amd64|x86_64) cpu=amd64 ;;
    *) error "目前脚本不支持 $(uname -m) 架构" ;;
esac

INSTALL_DIR="/etc/easyshare"
mkdir -p "$INSTALL_DIR/cert"
cd "$INSTALL_DIR" || exit

# 2. 完美兼容 Ubuntu/Debian/Alpine 的依赖安装逻辑 (参考甬哥)
info "检查并补全系统必要依赖..."
if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1 && apk add --no-cache bash curl wget openssl jq coreutils util-linux >/dev/null 2>&1
elif command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update >/dev/null 2>&1 && apt install -y curl wget openssl jq coreutils util-linux ca-certificates >/dev/null 2>&1
fi

# 获取公网 IP (双保险)
get_public_ip() {
    local ip
    ip=$(curl -s4m 3 https://api.ipify.org || wget -4qO- https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}
PUBLIC_IP=$(get_public_ip)

# UUID 生成与缓存
if [ ! -f "uuid.txt" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)
    echo "$UUID" > uuid.txt
else
    UUID=$(cat uuid.txt)
fi
UUID=$(echo "$UUID" | tr '[:upper:]' '[:lower:]')
XHTTP_PATH="/${UUID}-xhttp"

# 3. 安全清理进程 (防止自杀和崩溃)
info "清理残留进程..."
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop singbox xray cloudflared 2>/dev/null
fi
pkill -9 -x sing-box 2>/dev/null
pkill -9 -x xray 2>/dev/null
pkill -9 -x cloudflared 2>/dev/null

SB_VER="1.11.4"
XRAY_VER="25.1.30"

# 4. 双保险下载内核 (CURL / WGET 自动回退)
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

if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ ! -f "sing-box" ]; then
        info "正在下载 Sing-box v$SB_VER..."
        download_file "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz" "singbox.tar.gz"
        tar -xzf singbox.tar.gz --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf singbox.tar.gz sing-box 2>/dev/null
        [ -f "sing-box" ] && chmod +x sing-box || error "Sing-box 下载或解压失败"
        rm -f singbox.tar.gz
    fi
fi

if ([ -n "$xhpt" ] && [ "$xhpt" != "n" ] && [ "$xhpt" != "N" ]) || ([ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]); then
    if [ ! -f "xray" ]; then
        info "正在下载 Xray-core v$XRAY_VER..."
        XRAY_CPU_ARCH="64"
        [ "$cpu" = "arm64" ] && XRAY_CPU_ARCH="arm64-v8a"
        download_file "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${XRAY_CPU_ARCH}.zip" "xray.zip"
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

if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    if [ ! -f "cloudflared" ]; then
        info "正在下载 Cloudflared..."
        CF_CPU="$cpu"
        download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_CPU}" "cloudflared"
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
# 5. 生成配置文件
# =========================================================================
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ "$nvpt" = "y" ] || [ "$nvpt" = "Y" ]; then
        NAIVE_PORT=$(shuf -i 10000-65535 -n 1)
    else
        NAIVE_PORT="$nvpt"
    fi
    info "已配置 NaiveProxy (Sing-box)，端口: $NAIVE_PORT"
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
if [ -n "$xhpt" ] && [ "$xhpt" != "n" ] && [ "$xhpt" != "N" ]; then
    if [ "$xhpt" = "y" ] || [ "$xhpt" = "Y" ]; then
        XHTTP_PORT=$(shuf -i 10000-65535 -n 1)
    else
        XHTTP_PORT="$xhpt"
    fi
    info "已配置 Xray xHTTP 直连，端口: $XHTTP_PORT"
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
    GLOBAL_LINKS+="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h2&sni=bing.com&fp=chrome&type=xhttp&mode=auto&path=%2F${UUID}-direct&allowInsecure=1#xHTTP_Direct_H2\n"
    GLOBAL_LINKS+="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h3&sni=bing.com&fp=chrome&type=xhttp&mode=auto&path=%2F${UUID}-direct&allowInsecure=1#xHTTP_Direct_H3\n"
fi

if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    HAS_XRAY=true
    info "已配置 Xray xHTTP (Argo 回源)，端口: $ARGO_PORT"
    
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
        XRAY_INBOUNDS="$XRAY_INBOUNDS, $ARGO_INBOUND"
    else
        XRAY_INBOUNDS="$ARGO_INBOUND"
    fi

    GLOBAL_LINKS+="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h2&sni=${ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${ARGO_DOMAIN}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H2\n"
    GLOBAL_LINKS+="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h3&sni=${ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${ARGO_DOMAIN}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H3\n"
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
# 6. 服务启动逻辑 (兼容 Systemd 与 OpenRC/后台守护)
# =========================================================================
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    [ "$HAS_SINGBOX" = true ] && cat <<EOF > /etc/systemd/system/singbox.service
[Unit]
Description=Sing-box Service
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/sing-box run -c $INSTALL_DIR/singbox_config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    [ "$HAS_XRAY" = true ] && cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/xray run -c $INSTALL_DIR/xray_config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ] && cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel Service
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/cloudflared tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${ARGO_PROTOCOL} --ha-connections ${ARGO_CONNECTIONS} run --token ${ARGO_AUTH}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    [ "$HAS_SINGBOX" = true ] && systemctl enable --now singbox
    [ "$HAS_XRAY" = true ] && systemctl enable --now xray
    [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ] && systemctl enable --now cloudflared
    info "服务已通过 Systemd 成功托管启动！"
else
    warn "当前系统无 Systemd，已自动切换为标准后台守护运行..."
    [ "$HAS_SINGBOX" = true ] && nohup "$INSTALL_DIR/sing-box" run -c "$INSTALL_DIR/singbox_config.json" >/dev/null 2>&1 &
    [ "$HAS_XRAY" = true ] && nohup "$INSTALL_DIR/xray" run -c "$INSTALL_DIR/xray_config.json" >/dev/null 2>&1 &
    [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ] && nohup "$INSTALL_DIR/cloudflared" tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol "${ARGO_PROTOCOL}" --ha-connections "${ARGO_CONNECTIONS}" run --token "${ARGO_AUTH}" >/dev/null 2>&1 &
    info "服务已成功在后台运行！"
fi

# =========================================================================
# 7. 生成订阅输出
# =========================================================================
if [ -n "$GLOBAL_LINKS" ]; then
    BASE64_SUB=$(echo -e "$GLOBAL_LINKS" | base64 | tr -d '\n')
    echo "$BASE64_SUB" > "$INSTALL_DIR/sub.txt"
    
    echo -e "\n====================== 节点部署完成 ======================"
    echo -e "${GREEN}订阅文件已保存至: $INSTALL_DIR/sub.txt${NC}"
    echo -e "----------------------------------------------------------"
    echo -e "${YELLOW}【Base64 订阅内容】:${NC}"
    echo "$BASE64_SUB"
    echo -e "=========================================================="
else
    warn "未部署任何节点，请检查命令行参数！"
fi
