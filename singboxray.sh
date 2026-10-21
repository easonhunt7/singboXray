#!/bin/bash

# =========================
# NaiveProxy (Caddy) 纯净直连安装脚本
# 协议: NaiveProxy (支持 h2/h3) - 自动 SSL 证书版
# =========================

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

# 接收并解析命令行参数
INPUT_ARG="$1"
[ "$1" = "-i" ] && INPUT_ARG="$2" && DOMAIN_ARG="$3" || DOMAIN_ARG="$2"

if [ "$INPUT_ARG" = "n" ] || [ "$INPUT_ARG" = "N" ]; then
    yellow "已根据指令取消部署。"
    exit 0
elif [ "$INPUT_ARG" = "y" ] || [ "$INPUT_ARG" = "Y" ]; then
    export sub_port=$(shuf -i 10000-65000 -n 1)
elif [[ "$INPUT_ARG" =~ ^[0-9]+$ ]]; then
    export sub_port="$INPUT_ARG"
else
    export sub_port=${PORT:-$(shuf -i 10000-65000 -n 1)}
fi

# 获取域名参数
DOMAIN="${DOMAIN_ARG:-$DOMAIN}"
if [ -z "$DOMAIN" ]; then
    red "错误: 未提供有效的域名！请在命令末尾指定解析到本机的子域名。"
    echo "用法: ./singboxray.sh \"y\" \"naive.yourdomain.com\""
    exit 1
fi

work_dir="/etc/caddy"
[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 1. 清理旧服务并安装依赖
systemctl stop caddy nginx 2>/dev/null || true
yellow "正在更新系统并安装必要组件..."
apt update && apt install -y curl wget jq unzip openssl nginx 2>/dev/null || yum install -y curl wget jq unzip openssl nginx 2>/dev/null

# 2. 下载带有 naiveproxy (forwardproxy) 插件的官方 Caddy 二进制文件
mkdir -p "${work_dir}"
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64') ARCH='amd64' ;;
    'aarch64' | 'arm64') ARCH='arm64' ;;
    *) ARCH='amd64' ;;
esac

yellow "正在通过官方 API 下载编译包含 NaiveProxy 模块的 Caddy..."
curl -sLo "${work_dir}/caddy" "https://caddyserver.com/api/download?os=linux&arch=${ARCH}&p=github.com%2Fcaddyserver%2Fforwardproxy"
chmod +x ${work_dir}/caddy

# 验证二进制文件是否下载成功
if ! file "${work_dir}/caddy" | grep -q "ELF"; then
    red "错误: Caddy 二进制文件下载失败或格式不正确，请检查网络后重试！"
    exit 1
fi

# 3. 生成 NaiveProxy 认证账号密码与订阅路径
user=$(< /dev/urandom tr -dc 'a-z0-9' | head -c 8)
pass=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 16)
password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

# 4. 生成精简正确的 Caddyfile 配置 (自动申请证书并绑定域名和 443 端口)
cat > "${work_dir}/Caddyfile" << EOF
{
    admin off
}

${DOMAIN}:443 {
    tls admin@${DOMAIN}
    forward_proxy {
        basic_auth ${user} ${pass}
        hide_ip
        hide_via
    }
    reverse_proxy https://www.bing.com {
        header_up Host {upstream_hostport}
    }
}
EOF

# 5. 配置 Systemd 服务
cat > /etc/systemd/system/caddy.service << EOF
[Unit]
Description=Caddy NaiveProxy Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${work_dir}/caddy run --config ${work_dir}/Caddyfile --adapter caddyfile
ExecReload=${work_dir}/caddy reload --config ${work_dir}/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now caddy

# 6. 获取 IP 并生成兼容 v2rayN / NekoBox 的 NaiveProxy 节点与订阅
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
isp=$(curl -sm 3 "https://api.ip.sb/geoip" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 || echo "Node")

# 生成标准 NaiveProxy 共享链接 (naive+https)
cat > ${work_dir}/url.txt << EOF
naive+https://${user}:${pass}@${DOMAIN}:443?padding=true#${isp}-NaiveProxy
EOF

base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt 2>/dev/null || base64 ${work_dir}/url.txt | tr -d '\n' > ${work_dir}/sub.txt
chmod 644 ${work_dir}/sub.txt

# 7. 配置 Nginx 托管订阅
mkdir -p /etc/nginx/conf.d
cat > /etc/nginx/conf.d/naive_sub.conf << EOF
server {
    listen $sub_port;
    server_name _;
    location = /$password {
        alias ${work_dir}/sub.txt;
        default_type 'text/plain; charset=utf-8';
    }
    location / { return 404; }
}
EOF

nginx -t > /dev/null 2>&1 && (systemctl reload nginx || systemctl start nginx)

# 8. 输出部署信息
clear
green "=========================================================================================="
green " NaiveProxy (Caddy H2/H3) 纯净节点部署成功！"
green "=========================================================================================="
green " 域名: ${DOMAIN}"
green " 端口: 443 (TCP H2 / UDP H3 原生支持)"
green " 用户名: ${user}"
green " 密码: ${pass}"
green "=========================================================================================="
cat ${work_dir}/url.txt
green "\n=========================================================================================="
green " 订阅地址: http://${raw_ip}:${sub_port}/${password}"
green "==========================================================================================\n"
