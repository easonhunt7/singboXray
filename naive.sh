#!/usr/bin/env bash
set -e

# 接收固定参数：$1=开关(y/n), $2=端口(留空或数字), $3=域名
DEPLOY_FLAG="${1:-n}"
INPUT_PORT="$2"
DOMAIN="$3"

# 如果开关不是 y，则直接退出
if [[ "${DEPLOY_FLAG,,}" != "y" ]]; then
    echo "[!] 跳过 NaïveProxy 部署。"
    exit 0
fi

# 如果第二个参数传的是域名而不是端口（即没填端口、直接填了域名）
if [[ "$INPUT_PORT" == *.* ]] && [ -z "$DOMAIN" ]; then
    DOMAIN="$INPUT_PORT"
    INPUT_PORT=""
fi

if [ -z "$DOMAIN" ]; then
    echo "[Error] 域名不能为空！请正确传入域名参数。"
    exit 1
fi

# 端口处理：未指定或为空则随机分配高位端口
if [ -z "$INPUT_PORT" ] || ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]]; then
    PORT=$((RANDOM % 55536 + 10000))
    echo "[+] 未指定有效端口，已随机分配高位端口: ${PORT}"
else
    PORT="$INPUT_PORT"
    echo "[+] 使用指定端口: ${PORT}"
fi

USER=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)
PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)

echo "================================================="
echo " 开始部署 NaïveProxy"
echo " 域名: ${DOMAIN}"
echo " 端口: ${PORT}"
echo " 用户: ${USER}"
echo " 密码: ${PASS}"
echo "================================================="

# 系统环境检测
OS_TYPE=""
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    apk update
    apk add --no-progress curl wget sudo tar bash jq openssl ca-certificates
elif [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" || "$ID_LIKE" =~ "debian" ]]; then
        OS_TYPE="debian"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl wget sudo tar bash jq openssl ca-certificates
    fi
fi

if [ -z "$OS_TYPE" ]; then
    echo "[Error] 暂不支持该系统架构，仅支持 Ubuntu / Debian / Alpine。"
    exit 1
fi

# 下载集成 forwardproxy 模块的 Caddy 引擎
CADDY_BIN="/usr/local/bin/caddy"
echo "[+] 正在获取集成 forwardproxy 模块的 Caddy 引擎..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) CADDY_ARCH="amd64" ;;
    aarch64|arm64) CADDY_ARCH="arm64" ;;
    *) echo "[Error] 不支持的架构: $ARCH"; exit 1 ;;
esac

DOWNLOAD_URL="https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}&p=github.com%2Fcaddyserver%2Fforwardproxy"
curl -sSL "$DOWNLOAD_URL" -o "$CADDY_BIN"
chmod +x "$CADDY_BIN"

# 生成静态伪装网页
WEB_ROOT="/var/www/naive_mask"
mkdir -p "$WEB_ROOT"
cat <<'EOF' > "${WEB_ROOT}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Service Notice</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f4f6f8; color: #333; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { background: #fff; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.05); text-align: center; max-width: 400px; }
        h1 { font-size: 20px; font-weight: 600; margin-bottom: 12px; color: #111; }
        p { font-size: 14px; color: #666; line-height: 1.5; }
    </style>
</head>
<body>
    <div class="card">
        <h1>System Normal</h1>
        <p>This edge node is operating within normal technical metrics. Unauthorized protocol traffic is filtered.</p>
    </div>
</body>
</html>
EOF

# 动态构建 Caddyfile
CADDY_DIR="/etc/caddy"
mkdir -p "$CADDY_DIR"
CADDYFILE="${CADDY_DIR}/Caddyfile"

cat <<EOF > "$CADDYFILE"
{
    admin off
}

:${PORT}, ${DOMAIN}:${PORT} {
    tls admin@${DOMAIN}
    
    forwardproxy {
        basic_auth ${USER} ${PASS}
        hide_ip
        hide_via
        probe_resistance
    }
    
    root * ${WEB_ROOT}
    file_server
}
EOF

# 配置后台守护服务
echo "[+] 配置系统后台守护服务..."
if [ "$OS_TYPE" == "alpine" ]; then
    cat <<'EOF' > /etc/init.d/caddy
#!/sbin/openrc-run
description="Caddy Web Server (NaïveProxy)"
command="/usr/local/bin/caddy"
command_args="run --config /etc/caddy/Caddyfile"
pidfile="/run/caddy.pid"
command_background="yes"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/caddy
    rc-update add caddy default >/dev/null 2>&1 || true
    rc-service caddy restart
else
    cat <<EOF > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy Web Server with NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy
fi

echo "================================================="
echo " 🎉 NaïveProxy 部署成功！"
echo "================================================="
echo " 域名 (Domain)   : ${DOMAIN}"
echo " 端口 (Port)     : ${PORT}"
echo " 用户名 (Username): ${USER}"
echo " 密码 (Password) : ${PASS}"
echo "-------------------------------------------------"
echo " 🔗 客户端连接 URL (支持 HTTP/2 & HTTP/3):"
echo " naive+https://${USER}:${PASS}@${DOMAIN}:${PORT}"
echo "================================================="
