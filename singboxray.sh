cat << 'EOF' > singboxray.sh
#!/usr/bin/env bash
export LANG=en_US.UTF-8

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

# 防内存溢出：如果内存较小且没有 Swap，自动创建一个 1GB 的 Swap 虚拟内存
if [ $(free -m | awk '/Swap:/ {print $2}') -eq 0 ]; then
    info "检测到系统无 Swap 内存，正在临时创建 1GB Swap 防止 OOM 崩溃..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
fi

case $(uname -m) in
    arm64|aarch64) cpu=arm64 ;;
    amd64|x86_64) cpu=amd64 ;;
    *) error "目前脚本不支持 $(uname -m) 架构" ;;
esac

INSTALL_DIR="/etc/easyshare"
mkdir -p "$INSTALL_DIR/cert"
cd "$INSTALL_DIR" || exit

info "检查并精简安装基础依赖..."
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

info "清理残留进程..."
systemctl stop singbox xray cloudflared 2>/dev/null
pkill -9 -f sing-box 2>/dev/null
pkill -9 -f xray 2>/dev/null
pkill -9 -f cloudflared 2>/dev/null

SB_VER="1.11.4"
XRAY_VER="25.1.30"

if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ ! -f "sing-box" ]; then
        info "正在下载 Sing-box v$SB_VER..."
        curl -L -o singbox.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${cpu}.tar.gz"
        tar -xzf singbox.tar.gz --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf singbox.tar.gz sing-box 2>/dev/null
        [ -f "sing-box" ] && chmod +x sing-box || error "Sing-box 下载失败"
        rm -f singbox.tar.gz
    fi
fi

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

if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    if [ ! -f "cloudflared" ]; then
        info "正在下载 Cloudflared..."
        curl -L -o cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
        chmod +x cloudflared || error "Cloudflared 下载失败"
    fi
fi

if [ ! -f "cert/cert.pem" ] || [ ! -f "cert/private.key" ]; then
    info "正在生成自签名 TLS 证书..."
    openssl ecparam -genkey -name prime256v1 -out cert/private.key 2>/dev/null
    openssl req -new -x509 -days 3650 -key cert/private.key -out cert/cert.pem -subj "/CN=bing.com" 2>/dev/null
    chmod 600 cert/private.key
fi

GLOBAL_LINKS=""
HAS_SINGBOX=false
HAS_XRAY=false

if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    if [ "$nvpt" = "y" ] || [ "$nvpt" = "Y" ]; then
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
fi

if [ "$HAS_SINGBOX" = true ]; then
    cat <<EOF > /etc/systemd/system/singbox.service
[Unit]
Description=Sing-box Service (NaiveProxy)
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
ExecStart=$INSTALL_DIR/xray run -c $INSTALL_DIR/xray_config.json
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
ExecStart=$INSTALL_DIR/cloudflared tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${ARGO_PROTOCOL} --ha-connections ${ARGO_CONNECTIONS} run --token ${ARGO_AUTH}
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

if [ -n "$GLOBAL_LINKS" ]; then
    BASE64_SUB=$(echo -e "$GLOBAL_LINKS" | base64 | tr -d '\n')
    echo "$BASE64_SUB" > "$INSTALL_DIR/sub.txt"
    
    echo -e "\n====================== 节点部署完成 ======================"
    echo -e "${GREEN}订阅文件已保存至: $INSTALL_DIR/sub.txt${NC}"
    echo -e "----------------------------------------------------------"
    echo -e "${YELLOW}【Base64 订阅链接】:${NC}"
    echo "$BASE64_SUB"
    echo -e "=========================================================="
else
    warn "未部署任何有效节点，请检查入参！"
fi
EOF
chmod +x singboxray.sh
./singboxray.sh "y" "" "" "your-domain.com" "your-argo-token"
