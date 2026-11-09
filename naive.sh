#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请在 root 用户下运行此脚本！" && exit 1

# 1. 端口逻辑解析：若输入为数字则指定，若为 y/Y 或为空则随机生成
input_arg="$1"
if [ "$input_arg" = "y" ] || [ "$input_arg" = "Y" ] || [ -z "$input_arg" ]; then
    naive_port=$(shuf -i 10000-65000 -n 1)
elif [[ "$input_arg" =~ ^[0-9]+$ ]]; then
    naive_port="$input_arg"
else
    naive_port=$(shuf -i 10000-65000 -n 1)
fi

sing_box_dir="/etc/sing-box"
naive_dir="/etc/naive"

# 2. 停止旧服务并初始化目录
systemctl stop sing-box 2>/dev/null || true
green "正在初始化系统环境与核心依赖..."

if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip openssl iptables coreutils >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip openssl iptables coreutils >/dev/null 2>&1
fi

mkdir -p "${sing_box_dir}" "${naive_dir}"

# 3. 下载 sing-box 核心
echo "正在获取并安装 sing-box 核心..."
ARCH_SB=$(uname -m)
[ "$ARCH_SB" = "x86_64" ] && SB_ARCH="amd64"
[ "$ARCH_SB" = "aarch64" ] && SB_ARCH="arm64"
[ -z "$SB_ARCH" ] && SB_ARCH="amd64"

VERSION="1.11.0"
wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz" || \
wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${SB_ARCH}.tar.gz"

tar -xz -C /tmp -f /tmp/sing-box.tar.gz
find /tmp -type f -name "sing-box" -exec cp -f {} /usr/local/bin/ \;
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sing-box.tar.gz

# 4. 生成持久化 UUID 与自签证书 (SNI: bing.com)
echo "正在生成加密凭证与自签 TLS 证书..."
if [ ! -f "${naive_dir}/uuid" ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$uuid" > "${naive_dir}/uuid"
else
    uuid=$(cat "${naive_dir}/uuid")
fi

openssl ecparam -genkey -name prime256v1 -out "${naive_dir}/private.key" >/dev/null 2>&1
openssl req -new -x509 -days 3650 -key "${naive_dir}/private.key" -out "${naive_dir}/cert.crt" -subj "/CN=bing.com" >/dev/null 2>&1

# 5. 写入严格符合 sing-box v1.11+ 标准且显式绑定 server_name 的 config.json
cat > "${sing_box_dir}/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": ${naive_port},
      "users": [
        {
          "username": "${uuid}",
          "password": "${uuid}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "bing.com",
        "certificate_path": "${naive_dir}/cert.crt",
        "key_path": "${naive_dir}/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 6. 配置 systemd 服务托管
cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-Box Naive Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c ${sing_box_dir}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box >/dev/null 2>&1

# 7. 自动化放行防火墙端口
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    ip6tables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi

# 8. 精准捕获公网 IP（完美兼容纯 IPv6 环境）
raw_ip=$(curl -6 -sm 2 ip.sb || curl -4 -sm 2 ip.sb)
if [ -z "$raw_ip" ]; then
    raw_ip=$(ip -6 addr show scope global | grep -v "inet6 ::1" | grep -v "venet" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
fi

if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

clear
green "=========================================================================================="
green " NaïveProxy 部署成功（零交互直连模式 + 显式 SNI 绑定）"
green "=========================================================================================="
green "👉 当前使用端口: ${naive_port}"
green "------------------------------------------------------------------------------------------"
green "👉 H2 节点链接:"
green "naive+https://${uuid}:${uuid}@${server_ip}:${naive_port}?security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H2"
green "------------------------------------------------------------------------------------------"
green "👉 H3 节点链接:"
green "naive+quic://${uuid}:${uuid}@${server_ip}:${naive_port}?congestion_control=bbr&security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H3"
green "=========================================================================================="
