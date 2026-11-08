#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

# 变量解析逻辑：兼容 naive="y" 或直接传端口号
ARG_NAIVE=""

for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    if [[ "$clean_arg" =~ ^[nN][aA][iI][vV][eE](.*)$ ]]; then
        ARG_NAIVE="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[0-9]+$ ]] || [[ "$clean_arg" =~ ^[yYnN]$ ]]; then
        if [ -z "$ARG_NAIVE" ]; then
            ARG_NAIVE="$clean_arg"
        fi
    fi
done

parse_port() {
    local input="$1"
    [ -z "$input" ] && echo "" && return
    if [ "$input" = "n" ] || [ "$input" = "N" ]; then
        echo ""
    elif [ "$input" = "y" ] || [ "$input" = "Y" ]; then
        shuf -i 10000-60000 -n 1
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        echo ""
    fi
}

naive_port=$(parse_port "$ARG_NAIVE")

if [ -z "$naive_port" ]; then
    yellow "提示：未检测到有效变量（NaïveProxy 未启用或传入了 n）。"
    exit 0
fi

naive_dir="/etc/naive"
sing_box_dir="/etc/sing-box"
[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 1. 初始化与依赖安装
systemctl stop sing-box 2>/dev/null || true

green "正在安装必要依赖..."
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add --no-cache bash curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
fi

mkdir -p "${sing_box_dir}" "${naive_dir}"

# 2. 下载并安装最新版 Sing-box 内核
echo "正在下载 Sing-box 内核..."
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

# 3. 生成 UUID 与自签证书
echo "生成凭证与自签证书..."
uuid=$(cat /proc/sys/kernel/random/uuid)
echo "$uuid" > "${naive_dir}/uuid"

openssl ecparam -genkey -name prime256v1 -out "${naive_dir}/private.key" >/dev/null 2>&1
openssl req -new -x509 -days 3650 -key "${naive_dir}/private.key" -out "${naive_dir}/cert.crt" -subj "/CN=bing.com" >/dev/null 2>&1

# 4. 写入 Sing-box 配置 (监听全局双栈)
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

# 5. 配置并启动 Systemd 服务
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
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box >/dev/null 2>&1

# 6. 放行防火墙端口 (同时兼容 iptables 与纯 IPv6 环境的 ip6tables)
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    ip6tables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi

# 7. 完美获取公网 IP（优先通过外部 API，彻底避开虚拟网卡 venet0 干扰）
raw_ip=$(curl -6 -sm 3 ip.sb || curl -4 -sm 3 ip.sb)
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
green " NaïveProxy 模块部署成功！"
green "=========================================================================================="
green "👉 H2 链接 (推荐在 v2rayN 中使用 sing-box 核心导入):"
green "naive+https://${uuid}:${uuid}@${server_ip}:${naive_port}?security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H2"
green "------------------------------------------------------------------------------------------"
green "👉 H3 链接 (QUIC):"
green "naive+quic://${uuid}:${uuid}@${server_ip}:${naive_port}?congestion_control=bbr&security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H3"
green "=========================================================================================="
