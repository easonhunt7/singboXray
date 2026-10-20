#!/usr/bin/env bash
# =========================================================
# 纯 Shell 一键部署节点脚本 (支持 Ubuntu / Debian / Alpine)
# 架构: Sing-box (NaiveProxy H2/H3) + Xray (xHTTP 直连/Argo)
# =========================================================

set -e

WORK_DIR=".tmp"
mkdir -p "$WORK_DIR"

# 1. 接收命令行参数
# 格式: ./deploy.sh [naive端口] [xhttp端口] [argo端口] [argo域名] [argo token]
INPUT_NAIVE=${1:-"n"}
INPUT_XHTTP=${2:-"n"}
INPUT_ARGO_PORT=${3:-"n"}
INPUT_ARGO_DOMAIN=${4:-""}
INPUT_ARGO_AUTH=${5:-""}

# 2. 检查并安装基础依赖 (curl, openssl, tar, unzip)
echo -e "\n[1/5] 检查并安装系统基础依赖..."
if [ -f /etc/alpine-release ]; then
    apk update && apk add --no-cache curl openssl tar unzip coreutils procps
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    apt-get update -y && apt-get install -y curl openssl tar unzip procps psmisc
else
    echo "[错误] 暂不支持当前 Linux 发行版。"
    exit 1
fi

# 3. 清理旧进程
pkill -9 -f sing-box || true
pkill -9 -f xray || true
pkill -9 -f cloudflared || true

# 4. 架构判断与二进制下载
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    SB_ARCH="arm64"
    XR_ARCH="arm64-v8a"
    CF_ARCH="arm64"
else
    SB_ARCH="amd64"
    XR_ARCH="64"
    CF_ARCH="amd64"
fi

SINGBOX_VER="1.11.4"
XRAY_VER="25.1.30"

SB_PATH="$WORK_DIR/sing-box"
XR_PATH="$WORK_DIR/xray"
CF_PATH="$WORK_DIR/cloudflared"

echo -e "\n[2/5] 正在检查或下载内核二进制文件..."
# 下载 Sing-box
if [ ! -f "$SB_PATH" ]; then
    curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${SB_ARCH}.tar.gz" -o "$WORK_DIR/sb.tar.gz"
    tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR" --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR" sing-box
    mv "$WORK_DIR/sing-box" "$SB_PATH" 2>/dev/null || true
    rm -f "$WORK_DIR/sb.tar.gz"
fi
chmod +x "$SB_PATH"

# 下载 Xray
if [ ! -f "$XR_PATH" ]; then
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${XR_ARCH}.zip" -o "$WORK_DIR/xr.zip"
    unzip -o "$WORK_DIR/xr.zip" xray -d "$WORK_DIR" >/dev/null 2>&1
    rm -f "$WORK_DIR/xr.zip"
fi
chmod +x "$XR_PATH"

# 5. 生成密钥与证书
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -r 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
NAIVE_PASSWORD=$(openssl rand -hex 8)
XHTTP_PATH="/${UUID}-xhttp"

KEY_PATH="$WORK_DIR/private.key"
CERT_PATH="$WORK_DIR/cert.pem"
if [ ! -f "$KEY_PATH" ] || [ ! -f "$CERT_PATH" ]; then
    openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=bing.com" 2>/dev/null
    chmod 600 "$KEY_PATH"
fi

# 获取公网 IP
PUBLIC_IP=$(curl -s --connect-timeout 3 https://api.ipify.org || curl -s --connect-timeout 3 https://ipv4.icanhazip.com || echo "127.0.0.1")

GLOBAL_LINKS=""

# 6. 配置并启动 Sing-box (NaiveProxy H2/H3)
if [ "$INPUT_NAIVE" != "n" ] && [ -n "$INPUT_NAIVE" ]; then
    if [ "$INPUT_NAIVE" = "x" ]; then
        NAIVE_PORT=$((10000 + RANDOM % 50000))
    else
        NAIVE_PORT=$INPUT_NAIVE
    fi

    cat << EOF > "$WORK_DIR/singbox_config.json"
{
  "log": { "level": "panic" },
  "inbounds": [
    {
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
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    echo -e "\n[3/5] 启动 Sing-box (NaiveProxy 端口: $NAIVE_PORT)..."
    nohup "$SB_PATH" run -c "$WORK_DIR/singbox_config.json" >/dev/null 2>&1 &
    
    NAIVE_LINK="naive+https://naive:${NAIVE_PASSWORD}@${PUBLIC_IP}:${NAIVE_PORT}?padding=true#NaiveProxy_Direct"
    GLOBAL_LINKS="${GLOBAL_LINKS}${NAIVE_LINK}\r\n"
fi

# 7. 配置并启动 Xray (xHTTP 直连 & Argo 回源)
XRAY_INBOUNDS=""
HAS_XRAY=false

if [ "$INPUT_XHTTP" != "n" ] && [ -n "$INPUT_XHTTP" ]; then
    HAS_XRAY=true
    if [ "$INPUT_XHTTP" = "x" ]; then
        XHTTP_PORT=$((10000 + RANDOM % 50000))
    else
        XHTTP_PORT=$INPUT_XHTTP
    fi

    XRAY_INBOUNDS="${XRAY_INBOUNDS}
    {
      \"port\": $XHTTP_PORT,
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": [{ \"id\": \"$UUID\" }], \"decryption\": \"none\" },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"tls\",
        \"tlsSettings\": {
          \"certificates\": [{ \"certificateFile\": \"$CERT_PATH\", \"keyFile\": \"$KEY_PATH\" }],
          \"alpn\": [\"h2\", \"h3\"]
        },
        \"xhttpSettings\": { \"path\": \"$XHTTP_PATH\", \"mode\": \"auto\" }
      }
    },"

    H2_LINK="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h2&sni=www.bing.com&fp=chrome&type=xhttp&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Direct_H2"
    H3_LINK="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h3&sni=www.bing.com&fp=chrome&type=xhttp&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Direct_H3"
    GLOBAL_LINKS="${GLOBAL_LINKS}${H2_LINK}\r\n${H3_LINK}\r\n"
fi

# Argo 隧道配置
if [ "$INPUT_ARGO_PORT" != "n" ] && [ -n "$INPUT_ARGO_PORT" ] && [ -n "$INPUT_ARGO_DOMAIN" ] && [ -n "$INPUT_ARGO_AUTH" ]; then
    HAS_XRAY=true
    ARGO_PORT=$INPUT_ARGO_PORT

    XRAY_INBOUNDS="${XRAY_INBOUNDS}
    {
      \"port\": $ARGO_PORT,
      \"listen\": \"127.0.0.1\",
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": [{ \"id\": \"$UUID\" }], \"decryption\": \"none\" },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"none\",
        \"xhttpSettings\": { \"path\": \"$XHTTP_PATH\", \"mode\": \"auto\", \"scMaxConcurrentStreams\": 16 }
      }
    },"

    # 下载 Cloudflared
    if [ ! -f "$CF_PATH" ]; then
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o "$CF_PATH"
        chmod +x "$CF_PATH"
    fi

    echo -e "\n[4/5] 启动 Cloudflare Argo 固定隧道..."
    nohup "$CF_PATH" tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol quic --ha-connections 1 run --token "$INPUT_ARGO_AUTH" >/dev/null 2>&1 &

    CFIP="www.teamviewer.com"
    ARGO_H2="vless://${UUID}@${CFIP}:443?encryption=none&security=tls&alpn=h2&sni=${INPUT_ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${INPUT_ARGO_DOMAIN}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H2"
    ARGO_H3="vless://${UUID}@${CFIP}:443?encryption=none&security=tls&alpn=h3&sni=${INPUT_ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${INPUT_ARGO_DOMAIN}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H3"
    GLOBAL_LINKS="${GLOBAL_LINKS}${ARGO_H2}\r\n${ARGO_H3}\r\n"
fi

# 写入 Xray 配置并启动
if [ "$HAS_XRAY" = true ]; then
    XRAY_INBOUNDS="[${XRAY_INBOUNDS%,}]" # 去除尾随逗号
    cat << EOF > "$WORK_DIR/xray_config.json"
{
  "log": { "loglevel": "none" },
  "inbounds": $XRAY_INBOUNDS,
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
    echo -e "\n[5/5] 启动 Xray-core..."
    nohup "$XR_PATH" run -c "$WORK_DIR/xray_config.json" >/dev/null 2>&1 &
fi

# 8. 输出 Base64 订阅
if [ -n "$GLOBAL_LINKS" ]; then
    BASE64_SUB=$(echo -e "$GLOBAL_LINKS" | base64 | tr -d '\n')
    echo -e "\n====================== Base64 订阅/链接 ======================"
    echo "$BASE64_SUB"
    echo -e "==============================================================\n"
fi
