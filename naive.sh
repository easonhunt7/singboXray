#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "必须以 root 用户运行此脚本！" && exit 1

port_arg="y"
naive_domain=""
cf_token=""

# 智能解析无等号紧凑参数
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    case "${clean_arg,,}" in
        naive*)
            port_arg="${clean_arg#naive}"
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
[[ -z "${cf_token}" ]] && red "错误: 未检测到有效的 Cloudflare API Token！" && exit 1

if [ "$port_arg" = "y" ] || [ "$port_arg" = "Y" ] || [ -z "$port_arg" ]; then
    naive_port=$(shuf -i 10000-65000 -n 1)
elif [[ "$port_arg" =~ ^[0-9]+$ ]]; then
    naive_port="$port_arg"
else
    naive_port=$(shuf -i 10000-65000 -n 1)
fi

GREEN_DATA_DIR="/usr/local/easyshare_core"
CERT_DIR="/root/easyshare"

green "---> 正在检查系统环境与依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl systemd socat openssl jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl systemd socat openssl jq >/dev/null 2>&1
fi

get_arch="amd64"
[[ $(arch) =~ ("aarch64"|"arm64") ]] && get_arch="arm64"

mkdir -p ${GREEN_DATA_DIR}
mkdir -p ${CERT_DIR}

uuid_file="${GREEN_DATA_DIR}/uuid"
if [ ! -f "$uuid_file" ]; then
    naive_uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$naive_uuid" > "$uuid_file"
else
    naive_uuid=$(cat "$uuid_file")
fi

green "---> 正在使用 Cloudflare DNS-01 申请/配置 SSL 证书..."
export CF_Token="${cf_token}"

# 安装 acme.sh（若未安装）
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    curl -s https://get.acme.sh | sh -s email=admin@${naive_domain} >/dev/null 2>&1
fi

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1

# 申请证书
~/.acme.sh/acme.sh --issue --dns dns_cf -d "${naive_domain}" --force || { red "SSL 证书通过 Cloudflare DNS 申请失败，请检查 API Token 权限！"; exit 1; }

# 安装证书到指定 easyshare 目录
~/.acme.sh/acme.sh --install-cert -d "${naive_domain}" \
    --cert-file "${CERT_DIR}/cert.crt" \
    --key-file "${CERT_DIR}/private.key" \
    --fullchain-file "${CERT_DIR}/fullchain.cer" >/dev/null 2>&1

[[ ! -f "${CERT_DIR}/cert.crt" ]] && red "错误: 证书文件安装失败！" && exit 1

green "---> 正在下载并安装 sing-box 核心..."
sb_latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
[ -z "$sb_latest" ] && sb_latest="1.10.0"

sb_url="https://github.com/SagerNet/sing-box/releases/download/v${sb_latest}/sing-box-${sb_latest}-linux-${get_arch}.tar.gz"
curl -fLss "${sb_url}" -o /tmp/sing-box.tar.gz || { red "sing-box 下载失败！"; exit 1; }

tar -xz -f /tmp/sing-box.tar.gz -C /tmp/ >/dev/null 2>&1
mv -f /tmp/sing-box-${sb_latest}-linux-${get_arch}/sing-box ${GREEN_DATA_DIR}/sing-box
chmod +x ${GREEN_DATA_DIR}/sing-box
rm -rf /tmp/sing-box*

green "---> 正在生成 sing-box 原生 Naive 配置文件..."
cat > "${GREEN_DATA_DIR}/config.json" << EOF
{
  "log": {
    "disabled": false,
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
          "username": "${naive_uuid}",
          "password": "${naive_uuid}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_DIR}/cert.crt",
        "key_path": "${CERT_DIR}/private.key"
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

cat > /etc/systemd/system/naive.service << EOF
[Unit]
Description=Sing-Box Native NaiveProxy Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${GREEN_DATA_DIR}/sing-box run -c ${GREEN_DATA_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now naive >/dev/null 2>&1

if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    ip6tables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi

clear
green "=========================================================================================="
green " Sing-Box 原生 NaïveProxy 部署成功！"
green "=========================================================================================="
green "👉 证书存放路径: ${CERT_DIR}/ (easyshare)"
green "👉 绑定的域名: ${naive_domain}"
green "👉 服务端口: ${naive_port}"
green "------------------------------------------------------------------------------------------"
green "👉 客户端分享链接 (可在 v2rayN 中直接导入)："
green "------------------------------------------------------------------------------------------"
echo -e "\e[1;33mnaive+https://${naive_uuid}:${naive_uuid}@${naive_domain}:${naive_port}?security=tls&sni=${naive_domain}#Naive-SingBox-CF\e[0m"
echo -e "\e[1;33mnaive+quic://${naive_uuid}:${naive_uuid}@${naive_domain}:${naive_port}?congestion_control=bbr&security=tls&sni=${naive_domain}#Naive-SingBox-QUIC\e[0m"
green "=========================================================================================="
