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

CADDY_DATA_DIR="/usr/local/easyshare_core"
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

mkdir -p ${CADDY_DATA_DIR}
mkdir -p ${CERT_DIR}
mkdir -p ${CADDY_DATA_DIR}/html/

if [ ! -f "${CADDY_DATA_DIR}/html/index.html" ]; then
    cat >"${CADDY_DATA_DIR}/html/index.html" <<EOF
<!DOCTYPE html>
<html><head><title>Welcome!</title></head><body><h1>System Operational</h1></body></html>
EOF
fi

uuid_file="${CADDY_DATA_DIR}/uuid"
if [ ! -f "$uuid_file" ]; then
    naive_uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c 1-16)
    echo "$naive_uuid" > "$uuid_file"
else
    naive_uuid=$(cat "$uuid_file")
fi

green "---> 正在使用 Cloudflare DNS-01 申请/配置 SSL 证书..."
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

green "---> 正在检查并安装官方最新版 Go 运行环境..."
GO_VERSION="1.23.4"
if ! command -v go &> /dev/null || [[ "$(go version)" =~ "go1.1" ]] || [[ "$(go version)" =~ "go1.20" ]]; then
    yellow "---> 正在从官方获取并安装最新 Go 运行时..."
    apt-get remove -y golang-go golang >/dev/null 2>&1
    curl -fLss "https://go.dev/dl/go${GO_VERSION}.linux-${get_arch}.tar.gz" -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
fi

export PATH=$PATH:/usr/local/go/bin
export GOPATH=$(go env GOPATH 2>/dev/null || echo "/root/go")
export PATH=$PATH:$GOPATH/bin

# 配置标准的 Go 编译代理环境
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"
export GO111MODULE=on

green "---> 正在通过自建 Cloudflare 代理下载 xcaddy 编译工具..."
XCADDY_VERSION="v0.4.7"
VERSION_NUM="0.4.7"

if [ "$get_arch" = "amd64" ]; then
    arch_name="amd64"
elif [ "$get_arch" = "arm64" ]; then
    arch_name="arm64"
else
    arch_name="amd64"
fi

PROXY_URL="https://ess.ieshare.workers.dev/https://github.com/caddyserver/xcaddy/releases/download/${XCADDY_VERSION}/xcaddy_${VERSION_NUM}_linux_${arch_name}.tar.gz"

mkdir -p "$GOPATH/bin"
curl -fL --progress-bar "$PROXY_URL" -o /tmp/xcaddy.tar.gz || {
    red "自建代理下载失败，正在尝试通过官方直连下载..."
    ALT_URL="https://github.com/caddyserver/xcaddy/releases/download/${XCADDY_VERSION}/xcaddy_${VERSION_NUM}_linux_${arch_name}.tar.gz"
    curl -fL --progress-bar "$ALT_URL" -o /tmp/xcaddy.tar.gz || {
        red "错误: xcaddy 二进制下载彻底失败！"
        exit 1
    }
}

tar -C "$GOPATH/bin" -xzf /tmp/xcaddy.tar.gz xcaddy || {
    red "错误: xcaddy 解压失败！"
    rm -f /tmp/xcaddy.tar.gz
    exit 1
}
rm -f /tmp/xcaddy.tar.gz

GOPATH_BIN="$(go env GOPATH)/bin"
XCADDY_BIN="$GOPATH_BIN/xcaddy"
[ ! -f "$XCADDY_BIN" ] && XCADDY_BIN=$(command -v xcaddy)

if [ -z "$XCADDY_BIN" ] || [ ! -f "$XCADDY_BIN" ]; then
    red "错误: 找不到 xcaddy 可执行文件！"
    exit 1
fi

green "---> 正在使用官方 xcaddy 编译集成 forwardproxy (naive 分支) 的 Caddy 服务端..."
[ -f "${CADDY_DATA_DIR}/caddy" ] && rm -f "${CADDY_DATA_DIR}/caddy"

export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"

# 【优化点】：去掉了复杂的裁剪标签，使用最稳健的标准编译指令
"$XCADDY_BIN" build \
    --output "${CADDY_DATA_DIR}/caddy" \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive || {
    red "Caddy 编译失败！"
    exit 1
}

[[ ! -f "${CADDY_DATA_DIR}/caddy" ]] && red "错误: Caddy 编译未生成目标文件！" && exit 1
chmod +x "${CADDY_DATA_DIR}/caddy"

green "---> 正在生成 Caddyfile 配置文件..."
cat > "${CADDY_DATA_DIR}/Caddyfile" << EOF
{
    admin off
    auto_https off
}

:${naive_port} {
    tls ${CERT_DIR}/cert.crt ${CERT_DIR}/private.key
    route {
        forward_proxy {
            basic_auth ${naive_uuid} ${naive_uuid}
            hide_ip
            hide_via
            probe_resistance
        }
        file_server {
            root ${CADDY_DATA_DIR}/html
        }
    }
}
EOF

cat > /etc/systemd/system/naive.service << EOF
[Unit]
Description=Standard NaiveProxy Service (Caddy + ForwardProxy)
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${CADDY_DATA_DIR}/caddy run --config ${CADDY_DATA_DIR}/Caddyfile
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
green " 标准 NaïveProxy 服务端部署成功！"
green "=========================================================================================="
green "👉 证书存放路径: ${CERT_DIR}/ (easyshare)"
green "👉 绑定的域名: ${naive_domain}"
green "👉 服务端口: ${naive_port}"
green "------------------------------------------------------------------------------------------"
green "👉 客户端分享链接 (可在 v2rayN / v2rayNG / Hiddify 中直接导入)："
green "------------------------------------------------------------------------------------------"
echo -e "\e[1;33mnaive+https://${naive_uuid}:${naive_uuid}@${naive_domain}:${naive_port}?security=tls&sni=${naive_domain}#Naive-Standard-H2\e[0m"
echo -e "\e[1;33mnaive+quic://${naive_uuid}:${naive_uuid}@${naive_domain}:${naive_port}?congestion_control=bbr&security=tls&sni=${naive_domain}#Naive-Standard-QUIC\e[0m"
green "=========================================================================================="
