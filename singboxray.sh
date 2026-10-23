#!/bin/bash

# =========================================================================
# Xray XHTTP 纯净直连安装脚本 (singboxray.sh) - 甬哥标准对齐版
# 协议: 支持 VLESS-XHTTP-H3 与 VLESS-XHTTP-REALITY
# 用法: bash singboxray.sh h3"[参数]" reality"[参数]"
# 参数说明: "y"/"Y"(随机端口), "数字"(指定端口), "n"/"N"/留空(放弃部署)
# 示例: bash singboxray.sh h3"y" reality"y"
# =========================================================================

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

ARG_H3=""
ARG_REALITY=""

# 智能识别粘合参数（完美适配 h3"y" -> h3y、reality"443" 等写法）
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    if [[ "$clean_arg" =~ ^[hH]3(.*)$ ]]; then
        ARG_H3="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[rR][eE][aA][lL][iI][tT][yY](.*)$ ]]; then
        ARG_REALITY="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[0-9]+$ ]] || [[ "$clean_arg" =~ ^[yYnN]$ ]]; then
        if [ -z "$ARG_H3" ]; then
            ARG_H3="$clean_arg"
        elif [ -z "$ARG_REALITY" ]; then
            ARG_REALITY="$clean_arg"
        fi
    fi
done

parse_port() {
    local input="$1"
    if [ "$input" = "n" ] || [ "$input" = "N" ] || [ -z "$input" ]; then
        echo ""
    elif [ "$input" = "y" ] || [ "$input" = "Y" ]; then
        shuf -i 1000-65000 -n 1
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        echo ""
    fi
}

h3_port=$(parse_port "$ARG_H3")
reality_port=$(parse_port "$ARG_REALITY")

if [ -z "$h3_port" ] && [ -z "$reality_port" ]; then
    yellow "提示：未检测到有效的部署参数（H3和REALITY均未启用或均选择为n）。"
    yellow "正确用法示例: bash singboxray.sh h3\"y\" reality\"y\""
    exit 0
fi

work_dir="/etc/xray"
[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 1. 清理旧服务并安装依赖
systemctl stop xray 2>/dev/null || true
yellow "正在更新系统并安装必要组件，请耐心等待..."
apt update && apt install -y curl wget unzip openssl iptables 2>/dev/null || yum install -y curl wget unzip openssl iptables 2>/dev/null

# 2. 下载 Xray-core
mkdir -p "${work_dir}"
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64') ARCH='64' ;;
    'aarch64' | 'arm64') ARCH='arm64-v8a' ;;
    *) ARCH='64' ;;
esac

curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
unzip -qo "${work_dir}/xray.zip" -d "${work_dir}/" && rm -f "${work_dir}/xray.zip"
chmod +x ${work_dir}/xray

# 3. 生成变量、自签证书与 REALITY 密钥对
uuid=$(cat /proc/sys/kernel/random/uuid)
h3_path="${uuid}-xu" 
reality_path="${uuid}-xh" 
ym_vl_re="apple.com"

# H3 自签证书
openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

# Reality 密钥对生成
key_pair=$("${work_dir}/xray" x25519)
private_key_x=$(echo "$key_pair" | awk -F':' '/PrivateKey/ {print $2}' | xargs)
public_key_x=$(echo "$key_pair" | awk -F':' '/Password/ {print $2}' | xargs)
short_id_x=$(date +%s%N | sha256sum | cut -c 1-8)

# 4. 构建多 Inbound 配置
inbounds_json=""

# 如果配置了 REALITY
if [ -n "$reality_port" ]; then
    inbounds_json+='{
      "tag": "xhttp-reality",
      "listen": "::",
      "port": '"$reality_port"',
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "'"$uuid"'",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "target": "'"$ym_vl_re"':443",
          "serverNames": [
            "'"$ym_vl_re"'"
          ],
          "privateKey": "'"$private_key_x"'",
          "shortIds": ["'"$short_id_x"'"]
        },
        "xhttpSettings": {
          "host": "",
          "path": "/'"$reality_path"'",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }'
fi

# 如果配置了 H3
if [ -n "$h3_port" ]; then
    [ -n "$inbounds_json" ] && inbounds_json+=','
    inbounds_json+='{
      "tag": "xhttp-h3",
      "listen": "::",
      "port": '"$h3_port"',
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "'"$uuid"'",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/'"$h3_path"'"
        },
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "'"$work_dir"'/cert.pem",
              "keyFile": "'"$work_dir"'/private.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }'
fi

cat > "${work_dir}/config.json" << EOF
{
  "log": {
    "loglevel": "warning",
    "error": "${work_dir}/xray.log"
  },
  "inbounds": [
    $inbounds_json
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

# 5. 配置 Systemd 服务
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${work_dir}/xray run -config ${work_dir}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray

# 6. 放行对应的防火墙端口
for p in "$h3_port" "$reality_port"; do
    [ -z "$p" ] && continue
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow $p/tcp >/dev/null 2>&1
        ufw allow $p/udp >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -A INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null
        iptables -A INPUT -p udp --dport $p -j ACCEPT 2>/dev/null
    fi
done

# 7. 获取 IP 并输出节点链接与 Base64 编码
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

isp=$(curl -sm 3 "https://api.ip.sb/geoip" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 || echo "Node")

> "${work_dir}/url.txt"
[ -n "$reality_port" ] && echo "vless://${uuid}@${server_ip}:${reality_port}?encryption=none&security=reality&sni=${ym_vl_re}&fp=chrome&pbk=${public_key_x}&sid=${short_id_x}&type=xhttp&path=/${reality_path}#${isp}Reality-XHTTP_easyshare" >> "${work_dir}/url.txt"
[ -n "$h3_port" ] && echo "vless://${uuid}@${server_ip}:${h3_port}?encryption=none&security=tls&sni=bing.com&alpn=h3&type=xhttp&path=/${h3_path}&allowInsecure=1#${isp}H3-XHTTP_easyshare" >> "${work_dir}/url.txt"

base64_str=$(cat "${work_dir}/url.txt" | base64 | tr -d '\n' | tr -d '\r')

clear
green "=========================================================================================="
green " Xray XHTTP (H3 + REALITY) 节点部署成功（Base64）！"
green "=========================================================================================="
green "$base64_str"
green "=========================================================================================="
