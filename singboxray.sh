#!/bin/bash

# =========================
# Xray XHTTP 纯净直连安装脚本 (singboxray.sh)
# 协议: 仅保留 VLESS-XHTTP-H3 (纯 H3 UDP 专属修复版)
# =========================

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

# 接收并解析命令行参数 (支持自定义端口)
INPUT_ARG="$1"
[ "$1" = "-i" ] && INPUT_ARG="$2"

if [ "$INPUT_ARG" = "n" ] || [ "$INPUT_ARG" = "N" ]; then
    yellow "已根据指令取消部署。"
    exit 0
elif [ "$INPUT_ARG" = "y" ] || [ "$INPUT_ARG" = "Y" ]; then
    export xhttp_port=$(shuf -i 1000-65000 -n 1)
elif [[ "$INPUT_ARG" =~ ^[0-9]+$ ]]; then
    export xhttp_port="$INPUT_ARG"
else
    export xhttp_port=${PORT:-$(shuf -i 1000-65000 -n 1)}
fi

work_dir="/etc/xray"
[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 1. 清理旧服务并安装依赖
systemctl stop xray nginx 2>/dev/null || true
yellow "正在更新系统并安装必要组件..."
apt update && apt install -y curl wget jq unzip openssl nginx 2>/dev/null || yum install -y curl wget jq unzip openssl nginx 2>/dev/null

# 2. 下载 Xray-core
mkdir -p "${work_dir}"
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64') ARCH='64' ;;
    'aarch64' | 'arm64') ARCH='arm64-v8a' ;;
    *) ARCH='64' ;;
esac

curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
unzip -qo "${work_dir}/xray.zip" -d "${work_dir}/" && rm -f "${work_dir}/xray.zip"
chmod +x ${work_dir}/xray

# 3. 生成变量与自签证书
uuid=$(cat /proc/sys/kernel/random/uuid)
xhttp_path="${uuid}-xu" # 采用与甬哥一致的标准规范后缀，确保内核完全识别
nginx_port=$(($xhttp_port + 1))
password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

# 4. 生成 Xray 核心配置 (严格对齐 H3 专属 alpn 和 sniffing)
cat > "${work_dir}/config.json" << EOF
{
  "log": {
    "loglevel": "warning",
    "error": "${work_dir}/xray.log"
  },
  "inbounds": [
    {
      "tag": "xhttp-h3",
      "listen": "::",
      "port": $xhttp_port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/${xhttp_path}"
        },
        "tlsSettings": {
          "serverName": "bing.com",
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "${work_dir}/cert.pem",
              "keyFile": "${work_dir}/private.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

# 5. 配置 Systemd 服务
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${work_dir}/xray run -config ${work_dir}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray

# 6. 放行防火墙端口 (H3 依赖 UDP，必须确保放行)
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow ${xhttp_port}/tcp >/dev/null 2>&1
    ufw allow ${xhttp_port}/udp >/dev/null 2>&1
fi
iptables -A INPUT -p tcp --dport ${xhttp_port} -j ACCEPT 2>/dev/null
iptables -A INPUT -p udp --dport ${xhttp_port} -j ACCEPT 2>/dev/null

# 7. 获取 IP 并生成兼容的 xhttp-h3 链接格式
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

isp=$(curl -sm 3 "https://api.ip.sb/geoip" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 || echo "Node")

cat > ${work_dir}/url.txt << EOF
vless://${uuid}@${server_ip}:${xhttp_port}?encryption=none&security=tls&sni=bing.com&alpn=h3&type=xhttp&path=/${xhttp_path}&allowInsecure=1#${isp}-XHTTP-H3
EOF

# 8. 输出结果
clear
green "=========================================================================================="
green " Xray XHTTP-H3 纯净直连节点部署成功（已对齐甬哥 H3 专属核心参数）！"
green "=========================================================================================="
cat ${work_dir}/url.txt
green "=========================================================================================="
