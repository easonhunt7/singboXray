#!/usr/bin/env bash
set -e
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

INPUT_NAIVE=${1:-"n"}
INPUT_XHTTP=${2:-"n"}
INPUT_ARGO_PORT=${3:-"n"}
INPUT_ARGO_DOMAIN=${4:-""}
INPUT_ARGO_AUTH=${5:-""}

echo -e "\n[1/5] 正在检查环境与清理旧进程..."
if [ -f "$WORK_DIR/sb.pid" ]; then kill -9 $(cat "$WORK_DIR/sb.pid") 2>/dev/null || true; rm -f "$WORK_DIR/sb.pid"; fi
if [ -f "$WORK_DIR/xr.pid" ]; then kill -9 $(cat "$WORK_DIR/xr.pid") 2>/dev/null || true; rm -f "$WORK_DIR/xr.pid"; fi
if [ -f "$WORK_DIR/cf.pid" ]; then kill -9 $(cat "$WORK_DIR/cf.pid") 2>/dev/null || true; rm -f "$WORK_DIR/cf.pid"; fi

ARCH=$(uname -m)
case "$ARCH" in
    arm64|aarch64) SB_ARCH="arm64"; XR_ARCH="arm64-v8a"; CF_ARCH="arm64";;
    amd64|x86_64) SB_ARCH="amd64"; XR_ARCH="64"; CF_ARCH="amd64";;
    *) echo "错误: 不支持的架构 $ARCH"; exit 1;;
esac

SB_PATH="$WORK_DIR/sing-box"
XR_PATH="$WORK_DIR/xray"
CF_PATH="$WORK_DIR/cloudflared"

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
    openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=bing.com" 2>/dev/null
fi

PUBLIC_IP=$(curl -s4m5 https://api.ipify.org || echo "127.0.0.1")
GLOBAL_LINKS=""

if [ "$INPUT_NAIVE" != "n" ] && [ -n "$INPUT_NAIVE" ]; then
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
    GLOBAL_LINKS="${GLOBAL_LINKS}naive+https://naive:${NAIVE_PASSWORD}@${PUBLIC_IP}:${NAIVE_PORT}?padding=true#NaiveProxy_Direct_easyshare\r\n"
fi

XRAY_INBOUNDS=""
HAS_XRAY=false
if [ "$INPUT_XHTTP" != "n" ] && [ -n "$INPUT_XHTTP" ]; then
    HAS_XRAY=true
    XHTTP_PORT=20888
    XRAY_INBOUNDS="{\"port\": $XHTTP_PORT, \"protocol\": \"vless\", \"settings\": { \"clients\": [{ \"id\": \"$UUID\" }], \"decryption\": \"none\" }, \"streamSettings\": { \"network\": \"xhttp\", \"security\": \"tls\", \"tlsSettings\": { \"certificates\": [{ \"certificateFile\": \"$CERT_PATH\", \"keyFile\": \"$KEY_PATH\" }], \"alpn\": [\"h2\", \"h3\"] }, \"xhttpSettings\": { \"path\": \"$XHTTP_PATH\", \"mode\": \"auto\" } }}"
    GLOBAL_LINKS="${GLOBAL_LINKS}vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h2&sni=www.bing.com&fp=chrome&type=xhttp&path=${XHTTP_PATH_ENC}#xHTTP_Direct_H2_easyshare\r\nvless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h3&sni=www.bing.com&fp=chrome&type=xhttp&path=${XHTTP_PATH_ENC}#xHTTP_Direct_H3_easyshare\r\n"
fi

if [ "$HAS_XRAY" = true ]; then
    cat << CFG > "$WORK_DIR/xray_config.json"
{
  "log": { "loglevel": "none" },
  "inbounds": [$XRAY_INBOUNDS],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
CFG
    echo -e " -> 正在启动 Xray-core (xHTTP 直连)..."
    nohup "$XR_PATH" run -c "$WORK_DIR/xray_config.json" >/dev/null 2>&1 & echo $! > "$WORK_DIR/xr.pid"
fi

echo -e "\n[4/5] 部署全部完成！"

if [ -n "$GLOBAL_LINKS" ]; then
    echo -e "\n====================== Base64 订阅链接 ======================"
    echo -e "$GLOBAL_LINKS" | base64 | tr -d '\n'
    echo -e "\n=============================================================\n"
fi
