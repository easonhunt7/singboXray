#!/bin/bash

# ==========================================
# NaïveProxy + Caddy 完整部署与更新脚本
# ==========================================

DOMAIN="stormnaive.speedfast.dpdns.org"
PORT="43965"
USERNAME="8ea9240a8f4e4b21"
PASSWORD="8ea9240a8f4e4b21"

CORE_DIR="/usr/local/easyshare_core"
CADDY_BIN="${CORE_DIR}/caddy"
CADDY_FILE="${CORE_DIR}/Caddyfile"
WEB_ROOT="${CORE_DIR}/html"

# 1. 检查或安装 Go 环境（编译 Caddy 必需）
if ! command -v go &> /dev/null; then
    echo "正在安装 Go 编译环境..."
    apt-get update && apt-get install -y golang-go git
fi

# 2. 检查或安装 xcaddy（用于编译带 forwardproxy 模块的 Caddy）
if ! command -v xcaddy &> /dev/null; then
    echo "正在安装 xcaddy..."
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    # 将 Go bin 目录加入环境变量以便直接调用
    export PATH=$PATH:$(go env GOPATH)/bin
fi

# 3. 创建核心工作目录
mkdir -p "${CORE_DIR}" "${WEB_ROOT}"

# 4. 编译并生成支持 forwardproxy 的 Caddy 二进制文件
echo "正在编译支持 NaïveProxy (forwardproxy) 的 Caddy..."
XCADDY_BIN=$(command -v xcaddy || echo "$(go env GOPATH)/bin/xcaddy")
if [ -f "$CADDY_BIN" ]; then
    systemctl stop caddy 2>/dev/null
    rm -f "$CADDY_BIN"
fi

$XCADDY_BIN build \
    --output "$CADDY_BIN" \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

# 5. 生成默认伪装网页
if [ ! -f "$WEB_ROOT/index.html" ]; then
    cat << EOT > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body><h1>Server Operational</h1></body>
</html>
EOT
fi

# 6. 写入正确的 Caddyfile 配置文件
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

# 7. 写入 Systemd 服务守护文件
cat << EOT > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy Service
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
EOT

# 8. 校验配置文件语法
echo "正在校验配置文件..."
${CADDY_BIN} validate --config "$CADDY_FILE"
if [ $? -ne 0 ]; then
    echo "❌ Caddyfile 语法校验失败，请检查配置！"
    exit 1
fi

# 9. 加载并重启服务
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

# 10. 检查运行状态
systemctl status caddy --no-pager
