#!/usr/bin/env bash
# =========================================================
# NaïveProxy 一键部署脚本 (完美支持 naivedomain"xxx" 格式)
# =========================================================

set -e

# --- 1. 参数解析（兼容 naivedomain"..." 格式） ---
ALL_ARGS="$*"

DEPLOY_FLAG="n"
INPUT_PORT=""
DOMAIN=""

# 1. 匹配部署开关：只要包含 y/Y 且没有明确指明 n
if [[ "$ALL_ARGS" =~ [yY] ]] && [[ ! "$ALL_ARGS" =~ naive\"n\" ]] && [[ ! "$ALL_ARGS" =~ \ n\  ]]; then
    DEPLOY_FLAG="y"
elif [[ "$ALL_ARGS" =~ naive\"y\" ]] \vert{}\vert{} [[ "$ALL_ARGS" =~ \ y\  ]]; then
    DEPLOY_FLAG="y"
fi

# 2. 精准提取 naivedomain"xxx" 或 domain"xxx" 中的域名
if [[ "$ALL_ARGS" =~ naivedomain[\"\x27]?([^[:space:]\"\x27]+)[\"\x27]? ]] \vert{}\vert{} [[ "$ALL_ARGS" =~ domain[\"\x27]?([^[:space:]\"\x27]+)[\"\x27]? ]]; then
    DOMAIN="${BASH_REMATCH[1]}"
else
    # 备用：从参数中直接抓取形如 xxx.xxx.xxx 的域名
    for arg in "$@"; do
        if [[ "$arg" == *.* ]] && [[ "$arg" != *"/"* ]] && [[ "$arg" != *"http"* ]]; then
            DOMAIN="$arg"
            break
        fi
    done
fi

# 3. 提取端口：匹配 naive"数字" 或纯数字
for arg in "$@"; do
    if [[ "$arg" =~ ^naive\"([0-9]+)\"$ ]]; then
        INPUT_PORT="${BASH_REMATCH[1]}"
        break
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        INPUT_PORT="$arg"
        break
    fi
done

# 如果标志位不为 y，直接退出
if [[ "${DEPLOY_FLAG,,}" != "y" ]]; then
    echo "[!] 跳过 NaïveProxy 部署。"
    exit 0
fi

# 检查域名是否为空
if [ -z "$DOMAIN" ]; then
    echo "[Error] 域名不能为空！请检查传入的 naivedomain 参数。"
    exit 1
fi

# 端口处理：若未指定端口，随机分配 10000-65535 端口
if [ -z "$INPUT_PORT" ]; then
    PORT=$((RANDOM % 55536 + 10000))
    echo "[+] 未指定端口，已随机分配高位端口: ${PORT}"
else
    PORT="$INPUT_PORT"
    echo "[+] 使用指定端口: ${PORT}"
fi

# 自动生成 12 位随机用户名和 16 位密码
USER=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)
PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)

echo "================================================="
echo " 开始部署 NaïveProxy"
echo " 域名: ${DOMAIN}"
echo " 端口: ${PORT}"
echo " 用户: ${USER}"
echo " 密码: ${PASS}"
echo "================================================="

# --- 2. 系统环境检测与基础依赖安装 ---
OS_TYPE=""
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    apk update
    apk add --no-progress curl wget sudo tar bash jq openssl ca-certificates
elif [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" \vert{}\vert{} "$ID_LIKE" =~ "debian" ]]; then
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

# --- 3. 下载集成 forwardproxy 模块的 Caddy 引擎 ---
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

# --- 4. 生成静态伪装网页 ---
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

# --- 5. 动态构建 Caddyfile ---
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
        basic_auth ${USER}${PASS}
        hide_ip
        hide_via
        probe_resistance
    }
    
    root * ${WEB_ROOT}
    file_server
}
EOF

# --- 6. 配置后台守护服务与自启动 ---
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

# --- 7. 输出客户端配置参数 ---
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
