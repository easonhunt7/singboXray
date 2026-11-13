#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "必须以 root 用户运行此脚本！" && exit 1

h2_arg="y"
h3_arg="y"
naive_domain=""
cf_token=""

# 智能解析紧凑参数 (naive-h2, naive-h3, naivedomain, api)
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    case "${clean_arg,,}" in
        naive-h2*)
            h2_arg="${clean_arg#naive-h2}"
            ;;
        naive-h3*)
            h3_arg="${clean_arg#naive-h3}"
            ;;
        naivedomain*)
            naive_domain="${clean_arg#naivedomain}"
            ;;
        api*)
            cf_token="${clean_arg#api}"
            ;;
    esac
done

# 多重防错兜底提取
if [ -z "$naive_domain" ]; then
    for arg in "$@"; do
        [[ "$arg" == *naivedomain* ]] && naive_domain=$(echo "$arg" | sed 's/.*naivedomain//;s/[\"'\'']//g')
    done
fi

if [ -z "$cf_token" ]; then
    for arg in "$@"; do
        [[ "$arg" == *api* ]] && cf_token=$(echo "$arg" | sed 's/.*api//;s/[\"'\'']//g')
    done
fi

[[ -z "${naive_domain}" ]] && red "错误: 未检测到有效的域名参数！" && exit 1
[[ -z "${cf_token}" ]] && red "错误: 未检测 to 有效的 Cloudflare API Token！" && exit 1

# 检查开关：是否至少启用了一个
run_h2=false
run_h3=false
[[ "$h2_arg" =~ ^([yY][eE][sS]|[yY])$ ]] && run_h2=true
[[ "$h3_arg" =~ ^([yY][eE][sS]|[yY])$ ]] && run_h3=true

if [ "$run_h2" = false ] && [ "$run_h3" = false ]; then
    red "错误: naive-h2 和 naive-h3 均未启用（或填了 n/空），请至少开启其中一个！"
    exit 1
fi

# 分别为 H2 和 H3 分配独立随机端口（如果需要的话，也可以自定义）
if [ "$run_h2" = true ]; then
    if [[ "$h2_arg" =~ ^[0-9]+$ ]]; then
        h2_port="$h2_arg"
    else
        h2_port=$(shuf -i 10000-65000 -n 1)
    fi
fi

if [ "$run_h3" = true ]; then
    if [[ "$h3_arg" =~ ^[0-9]+$ ]]; then
        h3_port="$h3_arg"
    else
        # 确保 H3 端口不与 H2 端口冲突
        while : ; do
            h3_port=$(shuf -i 10000-65000 -n 1)
            [ "$h3_port" != "$h2_port" ] && break
        done
    fi
fi

SBX_DIR="/usr/local/singbox_naive"
CERT_DIR="/root/easyshare"

green "---> 正在清理旧版服务及检查系统环境..."
systemctl stop naive >/dev/null 2>&1
systemctl disable naive >/dev/null 2>&1
rm -f /etc/systemd/system/naive.service
pkill -9 caddy >/dev/null 2>&1

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl systemd socat openssl jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl systemd socat openssl jq >/dev/null 2>&1
fi

get_arch="amd64"
[[ $(arch) =~ ("aarch64"|"arm64") ]] && get_arch="arm64"

mkdir -p ${SBX_DIR}
mkdir -p ${CERT_DIR}

uuid_file="${SBX_DIR}/uuid"
if [ ! -f "$uuid_file" ]; then
    naive_uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c 1-16)
    echo "$naive_uuid" > "$uuid_file"
else
    naive_uuid=$(cat "$uuid_file")
fi

green "---> 正在使用 Cloudflare DNS-01 申请/配置共享 SSL 证书（完全不占用 80 端口）..."
export CF_Token="${cf_token}"

if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    curl -s https://get.acme.sh | sh -s email=admin@${naive_domain} >/dev/null 2>&1
fi

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
~/.acme.sh/acme.sh --issue --dns dns_cf -d "${naive_domain}" --force || { red "SSL 证书通过 Cloudflare DNS 申请失败，请检查 API Token 权限或域名限制！"; exit 1; }

~/.acme.sh/acme.sh --install-cert -d "${naive_domain}" \
    --cert-file "${CERT_DIR}/cert.crt" \
    --key-file "${CERT_DIR}/private.key" \
    --fullchain-file "${CERT_DIR}/fullchain.cer" >/dev/null 2>&1

[[ ! -f "${CERT_DIR}/cert.crt" ]] && red "错误: 证书文件安装失败！" && exit 1

green "---> 正在下载官方最新版 Sing-box 内核..."
SB_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
[ -z "$SB_VERSION" ] && SB_VERSION="1.11.0"

if [ "$get_arch" = "amd64" ]; then
    sb_arch="linux-amd64"
else
    sb_arch="linux-arm64"
fi

SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-${sb_arch}.tar.gz"

curl -fL --progress-bar "$SB_URL" -o /tmp/sing-box.tar.gz || {
    red "错误: Sing-box 内核下载失败！"
    exit 1
}

tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || {
    red "错误: Sing-box 解压失败！"
    rm -f /tmp/sing-box.tar.gz
    exit 1
}

mv /tmp/sing-box-${SB_VERSION}-${sb_arch}/sing-box ${SBX_DIR}/sing-box
chmod +x "${SBX_DIR}/sing-box"
rm -rf /tmp/sing-box*

[[ ! -f "${SBX_DIR}/sing-box" ]] && red "错误: Sing-box 核心未成功生成！" && exit 1

green "---> 正在生成 Sing-box 原生多节点 Naive 配置文件..."

# 动态组装 inbounds
inbounds_json=""

if [ "$run_h2" = true ]; then
    inbounds_json+='    {
      "type": "naive",
      "tag": "naive-h2-in",
      "listen": "::",
      "listen_port": '"$h2_port"',
      "users": [
        {
          "username": "'"$naive_uuid"'",
          "password": "'"$naive_uuid"'"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "certificate_path": "'"$CERT_DIR"'/fullchain.cer",
        "key_path": "'"$CERT_DIR"'/private.key"
      }
    }'
fi

if [ "$run_h3" = true ]; then
    if [ -n "$inbounds_json" ]; then
        inbounds_json+=','
    fi
    inbounds_json+='    {
      "type": "naive",
      "tag": "naive-h3-in",
      "listen": "::",
      "listen_port": '"$h3_port"',
      "users": [
        {
          "username": "'"$naive_uuid"'",
          "password": "'"$naive_uuid"'"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "'"$CERT_DIR"'/fullchain.cer",
        "key_path": "'"$CERT_DIR"'/private.key"
      }
    }'
fi

cat > "${SBX_DIR}/config.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
$inbounds_json
  ]
}
EOF

cat > /etc/systemd/system/naive.service << EOF
[Unit]
Description=Sing-box NaiveProxy Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${SBX_DIR}/sing-box run -c ${SBX_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now naive >/dev/null 2>&1

# 放行对应的防火墙端口
if command -v iptables >/dev/null 2>&1; then
    [ "$run_h2" = true ] && iptables -I INPUT -p tcp --dport $h2_port -j ACCEPT 2>/dev/null
    [ "$run_h3" = true ] && iptables -I INPUT -p udp --dport $h3_port -j ACCEPT 2>/dev/null
fi
if command -v ip6tables >/dev/null 2>&1; then
    [ "$run_h2" = true ] && ip6tables -I INPUT -p tcp --dport $h2_port -j ACCEPT 2>/dev/null
    [ "$run_h3" = true ] && ip6tables -I INPUT -p udp --dport $h3_port -j ACCEPT 2>/dev/null
fi

clear
green "=========================================================================================="
green " Sing-box 原生独立端口 NaïveProxy 服务端部署成功！"
green "=========================================================================================="
green "👉 核心架构: Sing-box Native (轻量无编译)"
green "👉 验证方式: Cloudflare DNS-01 (免 80 端口)"
green "👉 共享证书路径: ${CERT_DIR}/"
green "👉 绑定的域名: ${naive_domain}"
green "------------------------------------------------------------------------------------------"
green "👉 客户端分享链接 (可在 v2rayN / v2rayNG / Hiddify 中直接导入)："
green "------------------------------------------------------------------------------------------"
[ "$run_h3" = true ] && echo -e "\e[1;33mnaive+quic://${naive_uuid}:${naive_uuid}@${naive_domain}:${h3_port}?congestion_control=bbr&security=tls&sni=${naive_domain}#Naive-H3-${h3_port}\e[0m"
[ "$run_h2" = true ] && echo -e "\e[1;33mnaive+https://${naive_uuid}:${naive_uuid}@${naive_domain}:${h2_port}?security=tls&sni=${naive_domain}#Naive-H2-${h2_port}\e[0m"
green "=========================================================================================="
