#!/bin/bash

# =========================
# Xray XHTTP 直连 & Argo 四合一安装脚本 (singboxray.sh)
# 协议: VLESS-XHTTP (支持 h2/h3) + VMess-WS-Argo 备份
# =========================

export LANG=en_US.UTF-8
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# 接收并解析命令行参数 (-i / n / y / 端口数字)
INPUT_ARG="$1"
[ "$1" = "-i" ] && INPUT_ARG="$2"

if [ "$INPUT_ARG" = "n" ] \vert{}\vert{} [ "$INPUT_ARG" = "N" ]; then
    yellow "已根据指令取消部署。"
    exit 0
elif [ "$INPUT_ARG" = "y" ] \vert{}\vert{} [ "$INPUT_ARG" = "Y" ]; then
    export xhttp_port=$(shuf -i 1000-65000 -n 1)
elif [[ "$INPUT_ARG" =~ ^[0-9]+$ ]]; then
    export xhttp_port="$INPUT_ARG"
else
    export xhttp_port=${PORT:-$(shuf -i 1000-65000 -n 1)}
fi

# 定义常量
server_name="xray"
work_dir="/etc/xray"
client_dir="${work_dir}/url.txt"
export CFIP=${CFIP:-'cdns.doon.eu.org'} 
export ARGO_PORT='8001' 
export CFPORT=${CFPORT:-'443'} 

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本，可输入 sudo -i 回车切换到root用户" && exit 1

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_service() {
    local service_name=$1
    local service_file=$2
    [[ ! -f "${service_file}" ]] && { red "not installed"; return 2; }
    if command_exists apk; then
        rc-service "${service_name}" status | grep -q "started" && green "running" || yellow "not running"
    else
        systemctl is-active "${service_name}" \vert{} grep -q "^active$" && green "running" || yellow "not running"
    fi
    return $?
}

check_xray() {
    check_service "xray" "${work_dir}/xray"
}

check_argo() {
    check_service "argo" "${work_dir}/argo"
}

manage_packages() {
    if [ $# -lt 2 ]; then return 1; fi
    action=$1; shift
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y
        elif command_exists dnf || command_exists yum; then
            yum update -y || dnf update -y
        elif command_exists apk; then
            apk update
        fi
    fi
    for package in "$@"; do
        if [ "$action" == "install" ]; then
            command_exists "$package" && continue
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
            fi
        fi
    done
}

get_realip() {
    ip=$(curl -4 -sm 2 ip.sb)
    ipv6() { curl -6 -sm 2 ip.sb; }
    [ -z "$ip" ] && echo "[$(ipv6)]" \vert{}\vert{} echo "$ip"
}

allow_port() {
    has_ufw=0; has_firewalld=0; has_iptables=0
    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1

    for rule in "$@"; do
        port=${rule\%/*}; proto=${rule#*/}
        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p ${proto} --dport${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p ${proto} --dport${port} -j ACCEPT)
    done
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1
}

# 安装 Xray 和 cloudflared (argo)
install_xray() {
    clear
    purple "正在安装 Xray-core 及依赖中，请稍后..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='64' ;;
        'aarch64' | 'arm64') ARCH='arm64-v8a' ;;
        'armv7l')  ARCH='arm32-v7a' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}"

    # 下载 Xray 官方发布包并解压
    curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
    unzip -qo "${work_dir}/xray.zip" -d "${work_dir}/"
    rm -f "${work_dir}/xray.zip"

    # 下载 Argo 和 qrencode
    curl -sLo "${work_dir}/argo" "https://$(uname -m | grep -q 'x86_64' && echo 'amd64' || echo 'arm64').eooce.com/bot" 2>/dev/null || \
    curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
    curl -sLo "${work_dir}/qrencode" "https://raw.githubusercontent.com/eooce/test/master/qrencode" 2>/dev/null || true

    chmod +x ${work_dir}/xray ${work_dir}/argo${work_dir}/qrencode 2>/dev/null || true

    nginx_port=$(($xhttp_port + 1))
    uuid=$(cat /proc/sys/kernel/random/uuid)
    xhttp_path=$(< /dev/urandom tr -dc 'a-z0-9' | head -c 8)

    # 放行 XHTTP 端口（TCP + UDP 用于 H3/QUIC）以及订阅端口
    allow_port $xhttp_port/tcp $xhttp_port/udp$nginx_port/tcp > /dev/null 2>&1

    # 生成自签证书供 XHTTP TLS / H3 使用
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

    # 生成 Xray 核心配置文件 config.json
    cat > "${work_dir}/config.json" << EOF
{
  "log": {
    "loglevel": "warning",
    "error": "${work_dir}/xray.log"
  },
  "inbounds": [
    {
      "tag": "vless-xhttp",
      "port": $xhttp_port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "splithttp",
        "security": "tls",
        "splithttpSettings": {
          "path": "/${xhttp_path}"
        },
        "tlsSettings": {
          "serverName": "bing.com",
          "alpn": ["h2", "h3"],
          "certificates": [
            {
              "certificateFile": "${work_dir}/cert.pem",
              "keyFile": "${work_dir}/private.key"
            }
          ]
        }
      }
    },
    {
      "tag": "vmess-ws",
      "port": ${ARGO_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess-argo"
        }
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
}

# Systemd 守护进程配置
main_systemd_services() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${work_dir}/xray run -config${work_dir}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh -c "${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >${work_dir}/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray argo
    systemctl start xray argo
}

# 生成节点信息与订阅
get_info() {
    yellow "\n正在获取服务器外网信息与 Argo 域名...\n"
    server_ip=$(get_realip)
    
    for i in {1..6}; do
        argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null)
        [ -n "$argodomain" ] && break
        sleep 2
    done

    isp=$(curl -sm 3 "https://api.ip.sb/geoip" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 || echo "Node")

    VMESS="{ \"v\": \"2\", \"ps\": \"${isp}-Argo\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"

    cat > ${work_dir}/url.txt << EOF
vless://${uuid}@${server_ip}:${xhttp_port}?encryption=none&security=tls&sni=bing.com&alpn=h3,h2&type=splithttp&path=/${xhttp_path}#${isp}-XHTTP

vmess://$(echo "$VMESS" \vert{} base64 -w0 2>/dev/null \vert{}\vert{} echo "$VMESS" | base64)
EOF

    base64 -w0 ${work_dir}/url.txt >${work_dir}/sub.txt 2>/dev/null || base
