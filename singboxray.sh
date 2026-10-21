#!/bin/bash

# =========================================================================
# Xray XHTTP 纯净直连安装脚本 (singboxray.sh)
# 协议: 支持 VLESS-XHTTP-H3 与 VLESS-XHTTP-H2 (严格按参部署、无订阅逻辑)
# 用法: bash singboxray.sh [h2参数] [h3参数]
# 参数说明: y/Y(随机端口), 数字(指定端口), 留空/n/N(放弃部署)
# =========================================================================

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

# 接收并解析命令行双参数
ARG_H2="$1"
ARG_H3="$2"

parse_port() {
    local input="$1"
    # 如果明确传了 n 或 N，或者为空，则返回空
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

h2_port=$(parse_port "$ARG_H2")
h3_port=$(parse_port "$ARG_H3")

# 如果两个参数解析出来都为空，说明用户未指定或选择放弃，直接安全退出
if [ -z "$h2_port" ] && [ -z "$h3_port" ]; then
    yellow "提示：未检测到有效的部署参数（H2和H3均未启用）。脚本已安全退出。"
    exit 0
fi

work_dir="/etc/xray"
[[ $EUID -ne 0 ]] && red "请在root用户下运行" && exit 1

# 1. 清理旧服务并安装依赖
systemctl stop xray 2>/dev/null || true
yellow "正在更新系统并安装必要组件..."
apt update && apt install -y curl wget jq unzip openssl iptables 2>/dev/null || yum install -y curl wget jq unzip openssl iptables 2>/dev/null

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

# 3. 生成通用变量与自签证书
uuid=$(cat /proc/sys/kernel/random/uuid)
h3_path="${uuid}-xu" 
h2_path="${uuid}-xc" 

openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

# 4. 动态构建多 Inbound 的 Xray 核心配置
cat > "${work_dir}/config.json" << EOF
{
  "log": {
    "loglevel": "warning",
    "error": "${work_dir}/xray.log"
  },
  "inbounds": [
EOF

first_inbound=true

# 如果配置了 H2 端口
if [ -n "$h2_port" ]; then
    cat >> "${work_dir}/config.json" << EOF
    {
      "tag": "xhttp-h2",
      "listen": "::",
      "port": $h2_port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
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
          "path": "/${h2_path}"
        },
        "tlsSettings": {
          "serverName": "bing.com",
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "${work_dir}/cert.pem",
              "keyFile": "${work_dir}/private.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
EOF
    first_inbound=false
fi

# 如果配置了 H3 端口
if [ -n "$h3_port" ]; then
    if [ "$first_inbound" = false ]; then
        sed -i '$s/$/,/' "${work_dir}/config.json"
    fi
    cat >> "${work_dir}/config.json" << EOF
    {
      "tag": "xhttp-h3",
      "listen": "::",
      "port": $h3_port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
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
          "path": "/${h3_path}"
        },
        "tlsSettings": {
          "serverName": "bing.com",
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "${work_dir}/cert.pem",
              "keyFile": "${work_dir}/private.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
EOF
fi

cat >> "${work_dir}/config.json" << EOF
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
for p in "$h2_port" "$h3_port"; do
    [ -z "$p" ] && continue
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow $p/tcp >/dev/null 2>&1
        ufw allow $p/udp >/dev/null 2>&1
    fi
    iptables -A INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport $p -j ACCEPT 2>/dev/null
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
[ -n "$h3_port" ] && echo "vless://${uuid}@${server_ip}:${h3_port}?encryption=none&security=tls&sni=bing.com&alpn=h3&type=xhttp&path=/${h3_path}&allowInsecure=1#${isp}-XHTTP-H3" >> "${work_dir}/url.txt"
[ -n "$h2_port" ] && echo "vless://${uuid}@${server_ip}:${h2_port}?encryption=none&security=tls&sni=bing.com&alpn=h2&type=xhttp&path=/${h2_path}&allowInsecure=1#${isp}-XHTTP-H2" >> "${work_dir}/url.txt"

base64_str=$(cat "${work_dir}/url.txt" | base64 | tr -d '\n' | tr -d '\r')

clear
green "=========================================================================================="
green " Xray XHTTP 纯净直连节点部署成功（严格按参、无订阅逻辑）！"
green "=========================================================================================="
cat "${work_dir}/url.txt"
green "------------------------------------------------------------------------------------------"
yellow "Base64 编码链接（可直接用于客户端批量导入）："
green "$base64_str"
green "=========================================================================================="
