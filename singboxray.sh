#!/usr/bin/env bash
# 去掉 set -e，避免静默退出，改为精准捕获错误
trap 'echo "错误: 脚本在第 $LINENO 行执行失败"; exit 1' ERR

WORK_DIR="$HOME/.singboxray"
mkdir -p "$WORK_DIR"

urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9]) o="${c}" ;;
            *) printf -v o '%%%02X' "'$c" ;;
        esac
        encoded="${encoded}${o}"
    done
    echo "${encoded}"
}

echo -e "\n[1/5] 正在检查环境与清理旧进程..."
if [ -f "$WORK_DIR/sb.pid" ]; then kill -9 $(cat "$WORK_DIR/sb.pid") 2>/dev/null || true; rm -f "$WORK_DIR/sb.pid"; fi
if [ -f "$WORK_DIR/xr.pid" ]; then kill -9 $(cat "$WORK_DIR/xr.pid") 2>/dev/null || true; rm -f "$WORK_DIR/xr.pid"; fi

ARCH=$(uname -m)
case "$ARCH" in
    arm64|aarch64) SB_ARCH="arm64"; XR_ARCH="arm64-v8a";;
    amd64|x86_64) SB_ARCH="amd64"; XR_ARCH="64";;
    *) echo "错误: 不支持的架构 $ARCH"; exit 1;;
esac

SB_PATH="$WORK_DIR/sing-box"
XR_PATH="$WORK_DIR/xray"

echo -e "\n[2/5] 正在检查并准备内核..."
if [ ! -f "$SB_PATH" ]; then
    curl -sL "https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-linux-${SB_ARCH}.tar.gz" -o "$WORK_DIR/sb.tar.gz"
    tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR" --wildcards "*/sing-box" --strip-components=1 2>/dev/null || true
    mv "$WORK_DIR/sing-box" "$SB_PATH" 2>/dev/null || true
    rm -f "$WORK_DIR/sb.tar.gz"
fi
chmod +x "$SB_PATH"

if [ ! -f "$XR_PATH" ]; then
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/v25.1.30/Xray-linux-${XR_ARCH}.zip" -o "$WORK_DIR/xr.zip"
    unzip -o "$WORK_DIR/xr.zip" xray -d "$WORK_DIR" >/dev/null 2>&1
    rm -f "$WORK_DIR/xr.zip"
fi
chmod +x "$XR_PATH"

echo -e "\n[3/5] 初始化安全密钥、UUID 与 TLS 证书..."
[ ! -f "$WORK_DIR/uuid" ] && (cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16) > "$WORK_DIR/uuid"
UUID=$(cat "$WORK_DIR/uuid")

[ ! -f "$WORK_DIR/naive_password" ] && openssl rand -hex 8 > "$WORK_DIR/naive_password"
NAIVE_PASSWORD=$(cat "$WORK_DIR/naive_password")

XHTTP_PATH="/${UUID}-xhttp"
XHTTP_PATH_ENC=$(urlencode "$XHTTP_PATH")

KEY_PATH="$WORK_DIR/private.key"
CERT_PATH="$WORK_DIR/cert.pem"
if [ ! -f "$KEY_PATH" ] || [ ! -f "$CERT_PATH" ]; then
    echo " -> 正在生成 ECC 私钥..."
    openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH"
    echo " -> 正在生成自签 TLS 证书..."
    openssl req -new -x509 -days 3650 -key "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=bing.com"
fi

echo -e "\n[3.5/5] 正在智能检测服务器公网 IP..."
PUBLIC_IP=$(curl -s4m3 https://ip.sb || curl -s4m3 https://api.ipify.org || curl -s4m3 https://ipv4.icanhazip.com || curl -s4m3 https://ipinfo.io/ip)

if [ -z "$PUBLIC_IP" ] || [[ "$PUBLIC_IP" =~ ^127\..* ]] || [[ "$PUBLIC_IP" =~ ^10\..* ]] || [[ "$PUBLIC_IP" =~ ^192\.168\..* ]]; then
    PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7;exit}')
fi

if [ -z "$PUBLIC_IP" ] || [[ "$PUBLIC_IP" =~ ^127\..* ]] || [[ "$PUBLIC_IP" =~ ^10\..* ]] || [[ "$PUBLIC_IP" =~ ^192\.168\..* ]]; then
    PUBLIC_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
fi

while [ -z "$PUBLIC_IP" ] || [[ "$PUBLIC_IP" =~ ^127\..* ]]; do
    echo -e "\n[!] 提示：未能在当前容器环境中自动嗅探到有效的公网 IP。"
    read -p "请输入你的 VPS 真实公网 IP 地址: " PUBLIC_IP
done

echo -e " -> 成功锁定服务器 IP: $PUBLIC_IP"

GLOBAL_LINKS=""

# 1. 启动 Sing-box NaiveProxy
NAIVE_PORT=10888
cat << CFG > "$WORK_DIR/singbox_config.json"
{
  "log": { "level": "panic" },
  "inbounds": [{
    "type": "naive",
    "tag": "naive-in",
    "listen": "::",
    "listen_port": $NAIVE_PORT,
    "users": [{ "username": "naive", "password": "$NAIVE_PASSWORD" }],
    "tls": {
      "enabled": true,
      "alpn": ["h2", "h3"],
      "certificate_path": "$CERT_PATH",
      "key_path": "$KEY_PATH"
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
CFG

echo -e " -> 正在启动 Sing-box (NaiveProxy)，监听端口: $NAIVE_PORT"
nohup "$SB_PATH" run -c "$WORK_DIR/singbox_config.json" >/dev/null 2>&1 & echo $! > "$WORK_DIR/sb.pid"
sleep 1

NAIVE_LINK="naive+https://naive:${NAIVE_PASSWORD}@${PUBLIC_IP}:${NAIVE_PORT}?padding=true#NaiveProxy_Direct_easyshare"
GLOBAL_LINKS="${GLOBAL_LINKS}${NAIVE_LINK}\n"

# 2. 启动 Xray xHTTP 直连
XHTTP_PORT=20888
cat << CFG > "$WORK_DIR/xray_config.json"
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "port": $XHTTP_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{ "certificateFile": "$CERT_PATH", "keyFile": "$KEY_PATH" }],
        "alpn": ["h2", "h3"]
      },
      "xhttpSettings": {
        "path": "$XHTTP_PATH",
        "mode": "auto"
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
CFG

echo -e " -> 正在启动 Xray-core (xHTTP 直连)，监听端口: $XHTTP_PORT"
nohup "$XR_PATH" run -c "$WORK_DIR/xray_config.json" >/dev/null 2>&1 & echo $! > "$WORK_DIR/xr.pid"
sleep 1

H2_LINK="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h2&sni=www.bing.com&fp=chrome&type=xhttp&path=${XHTTP_PATH_ENC}#xHTTP_Direct_H2_easyshare"
H3_LINK="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h3&sni=www.bing.com&fp=chrome&type=xhttp&path=${XHTTP_PATH_ENC}#xHTTP_Direct_H3_easyshare"
GLOBAL_LINKS="${GLOBAL_LINKS}${H2_LINK}\n${H3_LINK}\n"

echo -e "\n[4/5] 部署全部完成！"

if [ -n "$GLOBAL_LINKS" ]; then
    echo -e "\n====================== Base64 订阅链接 ======================"
    echo -e "$GLOBAL_LINKS" | base64 | tr -d '\n'
    echo -e "\n=============================================================\n"
fi
