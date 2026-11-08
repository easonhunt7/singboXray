#!/bin/bash

# 确保以 root 权限运行
[[ $EUID -ne 0 ]] && echo "请在 root 用户下运行此脚本！" && exit 1

green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }

# 1. 交互输入端口（默认 27333）
read -p "请输入 NaïveProxy 端口 [回车默认 27333]: " naive_port
naive_port=${naive_port:-27333}

green "正在准备安装环境并下载内核..."
systemctl stop sing-box 2>/dev/null || true

# 2. 安装必要依赖
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
fi

sing_box_dir="/etc/sing-box"
naive_dir="/etc/naive"
mkdir -p "${sing_box_dir}" "${naive_dir}"

# 3. 下载最新版 sing-box 核心
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

# 4. 生成 UUID 与自签证书 (SNI: bing.com)
if [ ! -f "${naive_dir}/uuid" ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$uuid" > "${naive_dir}/uuid"
else
    uuid=$(cat "${naive_dir}/uuid")
fi

openssl ecparam -genkey -name prime256v1 -out "${naive_dir}/private.key" >/dev/null 2>&1
openssl req -new -x509 -days 3650 -key "${naive_dir}/private.key" -out "${naive_dir}/cert.crt" -subj "/CN=bing.com" >/dev/null 2>&1

# 5. 写入极简且正确的 sing-box 配置文件（严格遵守 v1.11+ 语法标准）
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

# 6. 配置 systemd 服务
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

# 7. 放行 IPv6 防火墙端口
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    ip6tables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi

# 8. 获取公网 IPv6 地址（优先外部 API，精准避开虚拟网卡）
raw_ip=$(curl -6 -sm 3 ip.sb || ip -6 addr show scope global | grep -v "inet6 ::1" | grep -v "venet" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
[ -z "$raw_ip" ] && raw_ip="你的IPv6地址"

clear
green "=========================================================================================="
green " NaïveProxy 部署完成！"
green "=========================================================================================="
green "👉 H2 链接 (复制并在 v2rayN 中使用 sing-box 核心导入):"
green "naive+https://${uuid}:${uuid}@[${raw_ip}]:${naive_port}?security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H2"
green "------------------------------------------------------------------------------------------"
green "👉 H3 链接 (QUIC):"
green "naive+quic://${uuid}:${uuid}@[${raw_ip}]:${naive_port}?congestion_control=bbr&security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H3"
green "=========================================================================================="
