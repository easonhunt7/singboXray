cat << 'EOF' > /root/singboxray.sh
#!/bin/bash

# =========================
# Xray XHTTP 直连 & Argo 四合一安装脚本
# =========================

export LANG=en_US.UTF-8
re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

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
export CFIP=${CFIP:-'cdns.doon.eu.org'} 
export ARGO_PORT='8001' 
export CFPORT=${CFPORT:-'443'} 

[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 核心安装逻辑
clear
echo "正在准备安装 Xray-core..."
mkdir -p "${work_dir}"
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64') ARCH='64' ;;
    'aarch64' | 'arm64') ARCH='arm64-v8a' ;;
    *) ARCH='64' ;;
esac

curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
apt update && apt install -y unzip curl jq openssl nginx 2>/dev/null || yum install -y unzip curl jq openssl nginx 2>/dev/null
unzip -qo "${work_dir}/xray.zip" -d "${work_dir}/" && rm -f "${work_dir}/xray.zip"
curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
chmod +x ${work_dir}/xray ${work_dir}/argo

uuid=$(cat /proc/sys/kernel/random/uuid)
xhttp_path=$(< /dev/urandom tr -dc 'a-z0-9' | head -c 8)
nginx_port=$(($xhttp_port + 1))
password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

cat > "${work_dir}/config.json" << EOF
{
  "inbounds": [
    {
      "port": $xhttp_port,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$uuid" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "splithttp",
        "security": "tls",
        "splithttpSettings": { "path": "/${xhttp_path}" },
        "tlsSettings": {
          "serverName": "bing.com",
          "alpn": ["h2", "h3"],
          "certificates": [{ "certificateFile": "${work_dir}/cert.pem", "keyFile": "${work_dir}/private.key" }]
        }
      }
    },
    {
      "port": ${ARGO_PORT},
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "$uuid" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 配置 Systemd
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${work_dir}/xray run -config ${work_dir}/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/bin/sh -c "${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --protocol http2 > ${work_dir}/argo.log 2>&1"
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now xray argo

# 获取 IP 与 Argo 域名
server_ip=$(curl -4 -s ip.sb || curl -6 -s ip.sb)
sleep 4
argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null)

cat > ${work_dir}/url.txt << EOF
vless://${uuid}@${server_ip}:${xhttp_port}?encryption=none&security=tls&sni=bing.com&alpn=h3,h2&type=splithttp&path=/${xhttp_path}#Xray-XHTTP
EOF

base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt 2>/dev/null || base64 ${work_dir}/url.txt | tr -d '\n' > ${work_dir}/sub.txt

cat > /etc/nginx/conf.d/xray.conf << EOF
server {
    listen $nginx_port;
    location = /$password {
        alias ${work_dir}/sub.txt;
        default_type 'text/plain; charset=utf-8';
    }
    location / { return 404; }
}
EOF
systemctl reload nginx || systemctl start nginx

green "安装完成！订阅地址: http://${server_ip}:${nginx_port}/${password}"
EOF
