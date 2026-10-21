#!/usr/bin/env bash
export LANG=en_US.UTF-8

# =========================================================================
# 无交互位置参数映射（完全对标甬哥变量习惯）：
# $1: nvpt -> NaiveProxy 变量 ("y" = 随机端口，数字 = 指定端口，"" = 不部署)
# $2: xhpt -> 保留扩展位置
# $3: ARGO_PORT -> Argo 固定隧道回源本地端口 (默认 8001)
# $4: ARGO_DOMAIN -> Argo 固定隧道域名 (必须与 AUTH 同时具备才部署)
# $5: ARGO_AUTH -> Argo 固定隧道 Token (必须与 DOMAIN 同时具备才部署)
# =========================================================================
export nvpt="${1:-}"
export xhpt="${2:-}"
export ARGO_PORT="${3:-8001}"
export ARGO_DOMAIN="${4:-}"
export ARGO_AUTH="${5:-}"

ARGO_PROTOCOL="${ARGO_PROTOCOL:-quic}"
ARGO_CONNECTIONS="${ARGO_CONNECTIONS:-1}"
CFIP="${CFIP:-www.teamviewer.com}"
CFPORT="${CFPORT:-443}"

v46url="https://icanhazip.com"

# 基础信息打印
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Sing-box NaiveProxy + Xray xHTTP Argo 隧道一键无交互脚本"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

case $(uname -m) in
    arm64|aarch64) cpu=arm64 ;;
    amd64|x86_64) cpu=amd64 ;;
    *) echo "目前脚本不支持 $(uname -m) 架构" && exit 1
;;
esac

# 1. 完全采用甬哥的稳健依赖安装逻辑（自带超时及包管理器兼容，绝不卡死）
mkdir -p "$HOME/agsbx/cert"
cd "$HOME/agsbx" || exit

if [ ! -f sbx_update ]; then
    echo "执行必要的脚本依赖中，请稍等……"
    if command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1 && apk add --no-cache bash busybox-extras gcompat libc6-compat iptables openssl jq curl wget >/dev/null 2>&1
    elif command -v apt >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt update >/dev/null 2>&1 && apt install -y busybox coreutils util-linux iptables cron openssl jq curl wget ca-certificates >/dev/null 2>&1
    fi
    touch sbx_update
fi

# 2. 获取公网 IP（完全采用甬哥双保险逻辑）
v4=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 -k "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- "$v46url" 2>/dev/null) )
[ -z "$v4" ] && v4="127.0.0.1"

# 3. UUID 生成与初始化（完全对齐 index.js 逻辑）
if [ -z "$uuid" ] && [ ! -e "$HOME/agsbx/uuid" ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)
    echo "$uuid" > "$HOME/agsbx/uuid"
else
    [ -n "$uuid" ] && echo "$uuid" > "$HOME/agsbx/uuid"
fi
uuid=$(cat "$HOME/agsbx/uuid" | tr '[:upper:]' '[:lower:]')
XHTTP_PATH="/${uuid}-xhttp"
echo "当前 UUID: $uuid"

# 4. 内核下载函数（采用甬哥原汁原味的二进制下载与赋权）
upsingbox(){
    url="https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-linux-$cpu.tar.gz"
    out="$HOME/agsbx/singbox.tar.gz"
    (command -v curl >/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget >/dev/null 2>&1 && timeout 5 wget -O "$out" --tries=2 "$url")
    tar -xzf "$out" --wildcards "*/sing-box" --strip-components=1 2>/dev/null || tar -xzf "$out" sing-box 2>/dev/null
    [ -f "sing-box" ] && chmod +x sing-box
    rm -f "$out"
    sbcore=$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}')
    echo "已安装 Sing-box 内核版本：$sbcore"
}

upxray(){
    x_arch="64"
    [ "$cpu" = "arm64" ] && x_arch="arm64-v8a"
    url="https://github.com/XTLS/Xray-core/releases/download/v25.1.30/Xray-linux-$x_arch.zip"
    out="$HOME/agsbx/xray.zip"
    (command -v curl >/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget >/dev/null 2>&1 && timeout 5 wget -O "$out" --tries=2 "$url")
    if command -v python3 &>/dev/null; then
        python3 -c "import zipfile; zipfile.ZipFile('$out').extract('xray', '.')"
    elif command -v unzip &>/dev/null; then
        unzip -qo "$out" xray
    fi
    [ -f "xray" ] && chmod +x xray
    rm -f "$out"
    sbcore=$("$HOME/agsbx/xray" version 2>/dev/null | awk '/^Xray/{print $2}')
    echo "已安装 Xray 内核版本：$sbcore"
}

GLOBAL_LINKS=""
HAS_SB=false
HAS_XR=false

# =========================================================================
# 5. NaiveProxy (Sing-box) 部署逻辑
# =========================================================================
if [ -n "$nvpt" ] && [ "$nvpt" != "n" ] && [ "$nvpt" != "N" ]; then
    HAS_SB=true
    if [ "$nvpt" = "y" ] || [ "$nvpt" = "Y" ]; then
        if [ -z "$port_nv" ] && [ ! -e "$HOME/agsbx/port_nv" ]; then
            port_nv=$(shuf -i 10000-65535 -n 1)
            echo "$port_nv" > "$HOME/agsbx/port_nv"
        else
            port_nv=$(cat "$HOME/agsbx/port_nv")
        fi
    else
        port_nv="$nvpt"
        echo "$port_nv" > "$HOME/agsbx/port_nv"
    fi
    echo "NaiveProxy 端口: $port_nv"

    if [ ! -e "$HOME/agsbx/sing-box" ]; then
        upsingbox
    fi

    # 生成自签证书供 NaiveProxy 使用
    if [ ! -f "cert/cert.pem" ] || [ ! -f "cert/private.key" ]; then
        openssl ecparam -genkey -name prime256v1 -out cert/private.key 2>/dev/null
        openssl req -new -x509 -days 3650 -key cert/private.key -out cert/cert.pem -subj "/CN=bing.com" 2>/dev/null
        chmod 600 cert/private.key
    fi

    cat > "$HOME/agsbx/sb.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": ${port_nv},
      "users": [{ "username": "${uuid}", "password": "${uuid}" }],
      "tls": {
        "enabled": true,
        "certificate_path": "$HOME/agsbx/cert/cert.pem",
        "key_path": "$HOME/agsbx/cert/private.key",
        "alpn": ["h3", "h2"]
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    GLOBAL_LINKS+="naive+https://${uuid}:${uuid}@${v4}:${port_nv}?sni=bing.com&alpn=h3,h2&allowInsecure=1#NaiveProxy_Direct\n"
fi

# =========================================================================
# 6. Xray xHTTP 固定隧道 (Argo) 部署逻辑
# =========================================================================
domainTrim="$(echo "$ARGO_DOMAIN" | xargs)"
authTrim="$(echo "$ARGO_AUTH" | xargs)"
portTrim="$(echo "$ARGO_PORT" | xargs)"

if [ -n "$portTrim" ] && [ "$portTrim" != "0" ] && [ -n "$domainTrim" ] && [ "${#authTrim}" -gt 30 ]; then
    HAS_XR=true
    echo "检测到完整的 Argo 隧道参数，准备配置 Xray xHTTP 回源..."

    if [ ! -e "$HOME/agsbx/xray" ]; then
        upxray
    fi

    # 下载 Cloudflared
    if [ ! -e "$HOME/agsbx/cloudflared" ]; then
        echo "正在下载 Cloudflared..."
        cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        (command -v curl >/dev/null 2>&1 && curl -Lo "$HOME/agsbx/cloudflared" -# --retry 2 "$cf_url") || (command -v wget >/dev/null 2>&1 && timeout 5 wget -O "$HOME/agsbx/cloudflared" --tries=2 "$cf_url")
        chmod +x "$HOME/agsbx/cloudflared"
    fi

    cat > "$HOME/agsbx/xr.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": ${portTrim},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "auto", "scMaxConcurrentStreams": 16 }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

    GLOBAL_LINKS+="vless://${uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h2&sni=${domainTrim}&fp=chrome&type=xhttp&mode=auto&host=${domainTrim}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H2\n"
    GLOBAL_LINKS+="vless://${uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&alpn=h3&sni=${domainTrim}&fp=chrome&type=xhttp&mode=auto&host=${domainTrim}&path=$(echo -n "$XHTTP_PATH" | jq -sRr @uri)#xHTTP_Argo_H3\n"
fi

# =========================================================================
# 7. 服务启动与托管逻辑（完全复刻甬哥完美的 systemd 与 OpenRC 兼容代码）
# =========================================================================
if [ "$HAS_SB" = true ]; then
    if pidof systemd >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        cat > /etc/systemd/system/singbox.service <<EOF
[Unit]
Description=Sing-box Service (NaiveProxy)
After=network.target
[Service]
Type=simple
WorkingDirectory=$HOME/agsbx
ExecStart=$HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable singbox >/dev/null 2>&1
        systemctl restart singbox >/dev/null 2>&1
    else
        pkill -9 -x sing-box 2>/dev/null
        nohup "$HOME/agsbx/sing-box" run -c "$HOME/agsbx/sb.json" >/dev/null 2>&1 &
    fi
fi

if [ "$HAS_XR" = true ]; then
    if pidof systemd >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (Argo xHTTP)
After=network.target
[Service]
Type=simple
WorkingDirectory=$HOME/agsbx
ExecStart=$HOME/agsbx/xray run -c $HOME/agsbx/xr.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel Service
After=network.target
[Service]
Type=simple
WorkingDirectory=$HOME/agsbx
ExecStart=$HOME/agsbx/cloudflared tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${ARGO_PROTOCOL} --ha-connections ${ARGO_CONNECTIONS} run --token ${authTrim}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable xray cloudflared >/dev/null 2>&1
        systemctl restart xray cloudflared >/dev/null 2>&1
    else
        pkill -9 -x xray 2>/dev/null
        pkill -9 -x cloudflared 2>/dev/null
        nohup "$HOME/agsbx/xray" run -c "$HOME/agsbx/xr.json" >/dev/null 2>&1 &
        nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol "${ARGO_PROTOCOL}" --ha-connections "${ARGO_CONNECTIONS}" run --token "${authTrim}" >/dev/null 2>&1 &
    fi
fi

# =========================================================================
# 8. 输出订阅
# =========================================================================
if [ -n "$GLOBAL_LINKS" ]; then
    BASE64_SUB=$(echo -e "$GLOBAL_LINKS" | base64 | tr -d '\n')
    echo "$BASE64_SUB" > "$HOME/agsbx/sub.txt"
    
    echo
    echo "====================== 节点部署完成 ======================"
    echo "订阅文件路径: $HOME/agsbx/sub.txt"
    echo "----------------------------------------------------------"
    echo "【Base64 订阅内容】:"
    echo "$BASE64_SUB"
    echo "=========================================================="
else
    echo "提示：未部署任何节点，请检查你的入参变量！"
fi
