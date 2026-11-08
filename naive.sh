#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

# Github Cloudflare安全代理
GITHUB_PROXY=('https://ess.ieshare.workers.dev/')
download_file() {
    local output_path="$1"
    local official_url="$2"
    
    echo "连接Github官方源中..."
    if curl -sL --connect-timeout 5 --max-time 60 -o "$output_path" "$official_url"; then
        if [ -s "$output_path" ]; then
            green "下载成功！"
            return 0
        fi
    fi
    
    yellow "Github连接失败，转向Cloudflare安全代理..."
    for proxy in "${GITHUB_PROXY[@]}"; do
        local proxy_url="${proxy}${official_url}"
        if curl -sL --connect-timeout 5 --max-time 60 -o "$output_path" "$proxy_url"; then
            if [ -s "$output_path" ]; then
                green "下载成功！"
                return 0
            fi
        fi
    done
    
    red "错误：官方源及镜像代理下载均告失败！"
    return 1
}

# 仿照你习惯的变量解析逻辑
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

# 1. 初始化
systemctl stop sing-box 2>/dev/null || rc-service sing-box stop 2>/dev/null || true

green "正在初始化 NaïveProxy 环境..."
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add --no-cache bash curl wget unzip openssl iptables coreutils jq >/dev/null 2>&1
else
    red "未识别的系统包管理器，无法自动安装依赖！"
    exit 1
fi

mkdir -p "${sing_box_dir}" "${naive_dir}"

# 2. 下载 Sing-box 内核
echo "正在下载 Sing-box 内核..."
ARCH_SB=$(uname -m)
[ "$ARCH_SB" = "x86_64" ] && SB_ARCH="amd64"
[ "$ARCH_SB" = "aarch64" ] && SB_ARCH="arm64"
SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
download_file "${sing_box_dir}/sing-box.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz" || exit 1
tar -xz -C "${sing_box_dir}" -f "${sing_box_dir}/sing-box.tar.gz"
mv "${sing_box_dir}/sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf "${sing_box_dir}/sing-box.tar.gz" "${sing_box_dir}/sing-box-${SB_VERSION}-linux-${SB_ARCH}"

# 3. 生成 UUID 与自签证书
echo "生成凭证与自签证书..."
uuid=$(cat /proc/sys/kernel/random/uuid)
echo "$uuid" > "${naive_dir}/uuid"

openssl ecparam -genkey -name prime256v1 -out "${naive_dir}/private.key"
openssl req -new -x509 -days 3650 -key "${naive_dir}/private.key" -out "${naive_dir}/cert.crt" -subj "/CN=bing.com"

# 4. 写入 Sing-box 独立配置
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
      "outbound": "direct"
    }
  ]
}
EOF

# 5. 配置并启动 Systemd 服务
green "正在启动 Sing-box 服务..."
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
systemctl enable --now sing-box

# 6. 放行防火墙端口
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow $naive_port/tcp >/dev/null 2>&1
    ufw allow $naive_port/udp >/dev/null 2>&1
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -A INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi

# 7. 获取 IP 并输出链接
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

clear
green "=========================================================================================="
green " NaïveProxy 单节点独立测试成功 "
green "=========================================================================================="
green "naive+https://${uuid}:${uuid}@${server_ip}:${naive_port}?security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H2"
green "naive+quic://${uuid}:${uuid}@${server_ip}:${naive_port}?congestion_control=bbr&security=tls&sni=bing.com&insecure=1&allowInsecure=1#Naive-H3"
green "=========================================================================================="
