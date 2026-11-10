#!/bin/bash

# ==========================================
# 参数配置
# ==========================================
DOMAIN="stormnaive.speedfast.dpdns.org"
PORT="43965"
AUTH_USER="8ea9240a8f4e4b21"
AUTH_PASS="8ea9240a8f4e4b21"

CORE_DIR="/usr/local/easyshare_core"
CADDY_BIN="${CORE_DIR}/caddy"
CADDY_FILE="${CORE_DIR}/Caddyfile"
WEB_ROOT="${CORE_DIR}/html"
SERVICE_FILE="/etc/systemd/system/caddy.service"

set -e

# ==========================================
# 1. 基础环境准备
# ==========================================
mkdir -p "${CORE_DIR}" "${WEB_ROOT}"

# 如果本地不存在可用的 Caddy 二进制，自动下载支持 forwardproxy 的构建版本
if [ ! -f "${CADDY_BIN}" ]; then
    echo "[+] 未找到 Caddy 二进制，正在从 Github```bash
#!/bin/bash

# ==========================================
# NaïveProxy + Caddy 完整部署与更新脚本
# 环境依赖：系统需已存在带 naive 模块的 caddy 二进制文件
# ==========================================

DOMAIN="stormnaive.speedfast.dpdns.org"
PORT="43965"
CADDY_BIN="/usr/local/easyshare_core/caddy"
CADDY_FILE="/usr/local/easyshare_core/Caddyfile"
WEB_ROOT="/usr/local/easyshare_core/html"
USERNAME="8ea9240a8f4e4b21"
PASSWORD="8ea9240a8f4e4b21"

# 1. 检查 Caddy 二进制文件是否存在
if [ ! -f "$CADDY_BIN" ]; then
    echo "错误: 未找到 Caddy 二进制文件 ($CADDY_BIN)，请确认路径。"
    exit 1
fi

# 2. 准备目录结构与伪装网页文件
mkdir -p "$WEB_ROOT"
if [ ! -f "$WEB_ROOT/index.html" ]; then
    cat << EOT > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
</head>
<body>
    <h1>Server Operational</h1>
</body>
</html>
EOT
fi

# 3. 写入 Caddyfile 配置文件
cat << EOT > "$CADDY_FILE"
{
    admin off
}

${DOMAIN}:${PORT} {
    tls {
        protocols tls1.2 tls1.3
    }
    route {
        forward_proxy {
            basic_auth ${USERNAME} ${PASSWORD}
            hide_ip
            hide_via
            probe_resistance
        }
        file_server {
            root ${WEB_ROOT}
        }
    }
}
EOT

# 4. 写入 Systemd 服务守护文件
cat << EOT > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy Service
Documentation=[https://caddyserver.com/docs/](https://caddyserver.com/docs/)
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
EOT

# 5. 校验配置文件语法
echo "正在校验配置文件..."
${CADDY_BIN} validate --config "$CADDY_FILE"
if [ $? -ne 0 ]; then
    echo "❌ Caddyfile 语法校验失败，中断执行！"
    exit 1
fi

# 6. 加载并重启服务
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

# 7. 打印运行状态
systemctl status caddy --no-pager
