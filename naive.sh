#!/bin/bash

# =========================================================
# NaïveProxy + Caddy 一键全自动非交互部署脚本
# 完美适配你的参数传递逻辑
# ==================================

# 初始化默认值
NAIVE_YN="n"
DOMAIN="sromn.fastflight.dpdns.org"
API_KEY=""

# 兼容你的参数解析逻辑：支持 naive"y" naivedomain"..." api"..." 格式
for arg in "$@"; do
    case "$arg" in
        naive*)
            NAIVE_YN=$(echo "$arg" | sed 's/^naive//g' | tr -d '"' | tr -d "'")
            ;;
        naivedomain*)
            DOMAIN=$(echo "$arg" | sed 's/^naivedomain//g' | tr -d '"' | tr -d "'")
            ;;
        api*)
            API_KEY=$(echo "$arg" | sed 's/^api//g' | tr -d '"' | tr -d "'")
            ;;
    esac
done

# 如果未开启 naive，直接退出
if [ "$NAIVE_YN" != "y" ] && [ "$NAIVE_YN" != "Y" ]; then
    echo "未启用 NaiveProxy 部署 (naive=y)，脚本退出。"
    exit 0
fi

PORT="43965"
AUTH_USER="8ea9240a8f4e4b21"
AUTH_PASS="8ea9240a8f4e4b21"

CORE_DIR="/usr/local/easyshare_core"
CADDY_BIN="${CORE_DIR}/caddy"
CADDY_FILE="${CORE_DIR}/Caddyfile"
WEB_ROOT="${CORE_DIR}/html"
SERVICE_FILE="/etc/systemd/system/caddy.service"

echo "=========================================="
echo " 开始全自动部署 NaïveProxy 服务"
echo " 目标域名: ${DOMAIN}"
echo " 服务端口: ${PORT}"
echo "=========================================="

# 1. 创建工作目录与伪装网页
mkdir -p "${CORE_DIR}" "${WEB_ROOT}"

if [ ! -f "${WEB_ROOT}/index.html" ]; then
    cat << 'EOF' > "${WEB_ROOT}/index.html"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Welcome</title>
</head>
<body>
    <h1>Server Operational</h1>
</body>
</html>
EOF
fi

# 2. 写入标准的 Caddyfile 配置
cat << EOF > "${CADDY_FILE}"
{
    admin off
}

${DOMAIN}:${PORT} {
    tls {
        protocols tls1.2 tls1.3
    }
    route {
        forward_proxy {
            basic_auth ${AUTH_USER} ${AUTH_PASS}
            hide_ip
            hide_via
            probe_resistance
        }
        file_server {
            root ${WEB_ROOT}
        }
    }
}
EOF

# 3. 写入 Systemd 守护进程服务配置文件
cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=Caddy NaiveProxy Service
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
ExecStart=${CADDY_BIN} run --environ --config ${CADDY_FILE}
ExecReload=${CADDY_BIN} reload --config ${CADDY_FILE}
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# 4. 语法校验与服务重启
if [ -f "${CADDY_BIN}" ]; then
    echo "正在校验 Caddyfile 语法..."
    "${CADDY_BIN}" validate --config "${CADDY_FILE}"
fi

systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

echo "=========================================="
echo " 部署完成！当前服务运行状态："
echo "=========================================="
systemctl status caddy --no-pager
