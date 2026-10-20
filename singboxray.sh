#!/usr/bin/env bash
# =========================================================
# 纯 Shell 极客稳健版一键部署节点脚本 (完美适配 OpenVZ/Debian/Alpine)
# 架构: Sing-box (NaiveProxy H2/H3) + Xray (xHTTP 直连/Argo)
# =========================================================

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

echo -e "\n========================================================="
echo -e "         开始执行轻量化节点一键部署程序                    "
echo -e "========================================================="

echo -e "\n[1/6] 正在检查系统环境与基础组件..."
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "[错误] 系统未检测到 curl 或 wget，请先手动安装！"
    exit 1
fi

echo -e "\n[2/6] 正在清理旧代理进程..."
if [ -f "$WORK_DIR/sb.pid" ]; then kill -9 $(cat "$WORK_DIR/sb.pid") 2>/dev/null || true; rm -f "$WORK_DIR/sb.pid"; fi
if [ -f "$WORK_DIR/xr.pid" ]; then kill -9 $(cat "$WORK_DIR/xr.pid") 2>/dev/null || true; rm -f "$WORK_DIR/xr.pid"; fi
if [ -f "$WORK_DIR/cf.pid" ]; then kill -9 $(cat "$WORK_DIR/cf.pid") 2>/dev/null || true; rm -f "$WORK_DIR/cf.pid"; fi

ARCH=$(uname -m)
case "$ARCH" in
    arm64|aarch64) SB_ARCH="arm64"; XR_ARCH="arm64-v8a"; CF_ARCH="arm64";;
    amd64|x86_64) SB_ARCH="amd64"; XR_ARCH="64"; CF_ARCH="amd64";;
    *) echo "[错误] 暂不支持当前系统架构: $ARCH"; exit 1;;
esac

SINGBOX_VER="1.11.4"
XRAY_VER="25.1.30"

SB_PATH="$WORK_DIR/sing-box"
XR_PATH="$WORK_DIR/xray"
CF_PATH="$WORK_DIR/cloudflared"

echo -e "\n[3/6] 正在检查并下载 Sing-box 与 Xray 核心..."
if [ ! -f "$SB_PATH" ]; then
    echo " -> 正在下载 Sing-box 内核..."
    (command -v curl >/dev/null 2>&1 && curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${SB_ARCH}.tar.gz" -o "$WORK_DIR/sb.tar.gz") || \
    (command -v wget >/dev/null 2>&1 && wget -qO "$WORK_DIR/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${SB_ARCH}.tar.gz")
    tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR" --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR" sing-box 2>/dev/null || true
    mv "$WORK_DIR/sing-box" "$SB_PATH" 2>/dev/null || true
    rm -f "$WORK_DIR/sb.tar.gz"
fi
chmod +x "$SB_PATH"

if [ ! -f "$XR_PATH" ]; then
    echo " -> 正在下载 Xray-core 内核..."
    (command -v curl >/dev/null 2>&1 && curl -sL "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${XR_ARCH}.zip" -o "$WORK_DIR/xr.zip") || \
    (command -v wget >/dev/null 2>&1 && wget -qO "$WORK_DIR/xr.zip" "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${XR_ARCH}.zip")
    unzip -o "$WORK_DIR/xr.zip" xray -d "$WORK_DIR" >/dev/null 2>&1
    rm -f "$WORK_DIR/xr.zip"
fi
chmod +x "$XR_PATH"

echo -e "\n[4/6] 正在初始化安全密钥、UUID 与 TLS 证书..."
if [ ! -f "$WORK_DIR/uuid" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -r 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    echo "$UUID" > "$WORK_DIR/uuid"
fi
UUID=$(cat "$WORK_DIR/uuid")

if [ ! -f "$WORK_DIR/naive_password" ]; then
    openssl rand -hex 8 > "$WORK_DIR/naive_password"
fi
NAIVE_PASSWORD=$(cat "$WORK_DIR/naive_password")

XHTTP_PATH="/${UUID}-xhttp"
XHTTP_PATH_ENC=$(urlencode "$XHTTP_PATH")

KEY_PATH="$WORK_DIR/private.key"
CERT_PATH="$WORK_DIR/cert.pem"
if [ ! -f "$KEY_PATH" ] || [ ! -f "$CERT_PATH" ]; then
    openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=bing.com" 2>/dev/null
    chmod 600 "$KEY_PATH"
fi

PUBLIC_IP=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 https://api.ipify.org) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 -qO- https://api.ipify.org) || echo "127.0.0.1" )
GLOBAL_LINKS=""

# 6. 配置并启动 Sing-box (NaiveProxy H2/H3)
if [ "$INPUT_NAIVE" != "n" ] && [ -n "$INPUT_NAIVE" ]; then
    if [ "$INPUT_NAIVE" = "x" ]; then
        if [ ! -f "$WORK_DIR/port_naive" ]; then
            echo $((10000 + $(date +%s) % 40000)) > "$WORK_DIR/port_naive"
        fi
        NAIVE_PORT=$(cat "$WORK_DIR/port_naive")
    else
        NAIVE_PORT=$INPUT_NAIVE
        echo "$NAIVE_PORT" > "$WORK_DIR/port_naive"
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
    echo -e " -> [配置] 正在启动 Sing-box (NaiveProxy H2/H3)，监听端口: $NAIVE_PORT"
    nohup "$SB_PATH" run -c "$WORK_DIR/singbox_config.json" >/dev/null 2>&1 & echo $! > "$WORK_DIR/sb.pid"
    
    NAIVE_LINK="naive+https://naive:${NAIVE_PASSWORD}@${PUBLIC_IP}:${NAIVE_PORT}?padding=true#NaiveProxy_Direct_easyshare"
    GLOBAL_LINKS="${GLOBAL_LINKS}${NAIVE_LINK}\r\n"
fi

# 7. 配置并启动 Xray (xHTTP 直连 & Argo 回源)
XRAY_INBOUNDS=""
HAS_XRAY=false

if [ "$INPUT_XHTTP" != "n" ] && [ -n "$INPUT_XHTTP" ]; then
    HAS_XRAY=true
    if [ "$INPUT_XHTTP" = "x" ]; then
        if [ ! -f "$WORK_DIR/port_xhttp" ]; then
            echo $((12000 + $(date +%s) % 40000)) > "$WORK_DIR/port_xhttp"
        fi
        XHTTP_PORT=$(cat "$WORK_DIR/port_xhttp")
    else
        XHTTP_PORT=$INPUT_XHTTP
        echo "$XHTTP_PORT" > "$WORK_DIR/port_xhttp"
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

    H2_LINK="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h2&sni=www.bing.com&fp=chrome&type=xhttp&path=${XHTTP_PATH_ENC}#xHTTP_Direct_H2_easyshare"
    H3_LINK="vless://${UUID}@${PUBLIC_IP}:${XHTTP_PORT}?encryption=none&security=tls&alpn=h3&sni=www.bing.com&fp=chrome&type=xhttp&path=${XHTTP_PATH_ENC}#xHTTP_Direct_H3_easyshare"
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

    if [ ! -f "$CF_PATH" ]; then
        echo " -> 正在下载 Cloudflared 客户端..."
        (command -v curl >/dev/null 2>&1 && curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o "$CF_PATH") || \
        (command -v wget >/dev/null 2>&1 && wget -qO "$CF_PATH" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}")
        chmod +x "$CF_PATH"
    fi

    echo -e " -> [配置] 正在启动 Cloudflare Argo 固定隧道..."
    nohup "$CF_PATH" tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol quic run --token "$INPUT_ARGO_AUTH" >/dev/null 2>&1 & echo $! > "$WORK_DIR/cf.pid"

    CFIP="www.teamviewer.com"
    ARGO_H2="vless://${UUID}@${CFIP}:443?encryption=none&security=tls&alpn=h2&sni=${INPUT_ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${INPUT_ARGO_DOMAIN}&path=${XHTTP_PATH_ENC}#xHTTP_Argo_H2_easyshare"
    ARGO_H3="vless://${UUID}@${CFIP}:443?encryption=none&security=tls&alpn=h3&sni=${INPUT_ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${INPUT_ARGO_DOMAIN}&path=${XHTTP_PATH_ENC}#xHTTP_Argo_H3_easyshare"
    GLOBAL_LINKS="${GLOBAL_LINKS}${ARGO_H2}\r\n${ARGO_H3}\r\n"
fi

if [ "$HAS_XRAY" = true ]; then
    XRAY_INBOUNDS="[${XRAY_INBOUNDS%,}]"
    cat << EOF > "$WORK_DIR/xray_config.json"
{
  "log": { "loglevel": "none" },
  "inbounds": $XRAY_INBOUNDS,
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
    echo -e "\n[5/6] 正在启动 Xray-core (xHTTP 直连/Argo回源)..."
    nohup "$XR_PATH" run -c "$WORK_DIR/xray_config.json" >/dev/null 2>&1 & echo $! > "$WORK_DIR/xr.pid"
fi

if pidof systemd >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
    cat > /etc/systemd/system/singboxray.service <<EOF
[Unit]
Description=Singboxray Proxy Service
After=network.target
[Service]
Type=forking
ExecStart=/bin/true
ExecReload=/bin/true
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

echo -e "\n[6/6] 部署全部完成！"

if [ -n "$GLOBAL_LINKS" ]; then
    BASE64_SUB=$(echo -e "$GLOBAL_LINKS" | base64 | tr -d '\n')
    echo -e "\n====================== Base64 订阅/链接 ======================"
    echo "$BASE64_SUB"
    echo -e "==============================================================\n"
fi
