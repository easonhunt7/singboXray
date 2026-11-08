#!/bin/bash

# ==========================================
# NaiveProxy 独立自签证书版一键部署脚本
# 兼容: Ubuntu / Debian / Alpine
# ==========================================

# 变量区（可按需修改或通过交互输入）
naive="y"        # 输入 "y" 表示部署，输入 "n" 表示放弃部署
port_input=""    # 留空或直接回车则自动随机生成端口，输入具体数字则使用指定端口

# 检查执行权限
if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本 (sudo -i)"
  exit 1
fi

# 1. 交互逻辑判断
if [ "$naive" != "y" ]; then
  echo "[*] 已选择放弃部署 NaïveProxy 协议，脚本安全退出。"
  exit 0
fi

echo "[+] 开始部署 NaïveProxy (自签证书模式)..."

# 2. 系统环境检测与依赖安装
if [ -f /etc/alpine-release ]; then
    apk update && apk add --no-cache curl openssl jq
elif [ -f /etc/debian_version ]; then
    apt-get update && apt-get install -y curl openssl jq
else
    echo "[-] 不支持的操作系统发行版"
    exit 1
fi

# 3. 确定服务端口
if [ -z "$port_input" ]; then
    # 随机生成一个 10000-60000 之间的端口
    port_nv=$((RANDOM % 50000 + 10000))
    echo "[*] 未指定端口，已自动随机分配端口: $port_nv"
else
    port_nv="$port_input"
    echo "[*] 使用指定端口: $port_nv"
fi

# 4. 生成自签证书与固定目录
CERT_DIR="/etc/naive"
mkdir -p "$CERT_DIR"

# 生成 10 年期的自签证书（SNI 伪装成 bing.com 或 cloudflare.com 均可）
openssl req -x509 -nodes -days 3650 -newkey rsa:2050 \
    -keyout "$CERT_DIR/private.key" \
    -out "$CERT_DIR/cert.crt" \
    -subj "/CN=cloudflare.com" >/dev/null 2>&1

echo "[+] 自签证书已成功生成至: $CERT_DIR"

# 5. 生成固定的 UUID 凭证作为账号密码
if [ ! -f "$CERT_DIR/uuid" ]; then
    cat /proc/sys/kernel/random/uuid > "$CERT_DIR/uuid"
fi
uuid=$(cat "$CERT_DIR/uuid")

# 6. 下载并安装 Sing-box 内核（如果尚未安装）
if ! command -v sing-box &> /dev/null; then
    echo "[+] 正在自动下载并安装 Sing-box 正式版内核..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh) || {
        # 兜底：若官方脚本在部分纯IPv6环境失败，手动获取最新二进制
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && ARCH="amd64"
        [ "$ARCH" = "aarch64" ] && ARCH="arm64"
        VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
        wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
        tar -xz -C /tmp -f /tmp/sing-box.tar.gz
        mv /tmp/sing-box-${VERSION}-linux-${ARCH}/sing-box /usr/local/bin/
        chmod +x /usr/local/bin/sing-box
    }
fi

# 7. 写入 Sing-box 独立配置文件
CONFIG_DIR="/etc/sing-box"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_DIR/config.json" <<EOF
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
      "listen_port": ${port_nv},
      "users": [
        {
          "username": "${uuid}",
          "password": "${uuid}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/cert.crt",
        "key_path": "$CERT_DIR/private.key"
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

# 8. 创建并启动 Systemd 服务
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# 9. 获取本机 IPv6 地址用于拼接分享链接
LOCAL_IP=$(ip -6 addr show scope global | grep -v "inet6 ::1" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
[ -z "$LOCAL_IP" ] && LOCAL_IP="[你的服务器IPv6]"

# 10. 输出结果与客户端链接
echo "=================================================="
echo "🎉 NaïveProxy 自签证书版部署成功！"
echo "=================================================="
echo "监听地址: [::]"
echo "监听端口: $port_nv"
echo "认证账号: $uuid"
echo "认证密码: $uuid"
echo "证书路径: $CERT_DIR/cert.crt"
echo "--------------------------------------------------"
echo "👉 客户端分享链接 (自签模式必须开启 insecure=1):"
echo "naive+https://$uuid:$uuid@[$LOCAL_IP]:$port_nv?security=tls&sni=cloudflare.com&insecure=1&allowInsecure=1#naive-h2-self"
echo "naive+quic://$uuid:$uuid@[$LOCAL_IP]:$port_nv?congestion_control=bbr&security=tls&sni=cloudflare.com&insecure=1&allowInsecure=1#naive-h3-self"
echo "=================================================="
