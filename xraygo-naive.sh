#!/bin/bash

export LANG=en_US.UTF-8
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;31m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请在 root 用户下运行此脚本！" && exit 1

# Cloudflare 安全代理源（“易分享 easysharing”创建）
GITHUB_PROXY=('https://ess.ieshare.workers.dev/')

download_file() {
    local output_path="$1"
    local official_url="$2"
    
    # 智能文件校验函数
    validate_file() {
        local path="$1"
        [ ! -s "$path" ] && return 1
        
        if [[ "$path" == *.zip ]]; then
            head -c 2 "$path" | grep -q "PK"
        elif [[ "$path" == *.tar.gz ]] || [[ "$path" == *.tgz ]]; then
            # 校验 gzip 魔数 (1f 8b)
            local magic=$(od -An -N2 -tx1 "$path" 2>/dev/null | tr -d ' ')
            [ "$magic" = "1f8b" ]
        else
            local fsize=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo 0)
            [ "$fsize" -gt 5000000 ]
        fi
    }

    clean_garbage() {
        [ -f "$output_path" ] && rm -f "$output_path"
    }

    # 1. 优先尝试：GitHub 官方源
    echo "连接 GitHub 官方源中..."
    if curl -# -L --connect-timeout 20 --max-time 180 -o "$output_path" "$official_url"; then
        if validate_file "$output_path"; then
            green "下载+校验成功！"
            return 0
        else
            yellow "校验失败，切换至 Cloudflare 安全代理..."
            clean_garbage
        fi
    else
        yellow "连接超时，切换至 Cloudflare 安全代理..."
        clean_garbage
    fi
    
    # 2. 备选尝试：Cloudflare 安全代理源
    for proxy in "${GITHUB_PROXY[@]}"; do
        local proxy_url="${proxy}${official_url}"
        if curl -# -L --connect-timeout 30 --max-time 240 -o "$output_path" "$proxy_url"; then
            if validate_file "$output_path"; then
                green "下载+校验成功！"
                return 0
            else
                yellow "校验失败，已清除残留..."
                clean_garbage
            fi
        fi
    done

    # 3. 全部失败
    red "下载或校验失败，请检查网络，稍后再试！"
    clean_garbage
    return 1
}

# ==============================================================================
# 1. 解析一键部署指令参数
# ==============================================================================
ENABLE_NAIVE_H2=false
NAIVE_H2_PORT_ARG=""
ENABLE_NAIVE_H3=false
NAIVE_H3_PORT_ARG=""
NAIVE_DOMAIN=""
NAIVE_API=""

ENABLE_XHTTP_H2=false
XHTTP_H2_PORT_ARG=""
ENABLE_XHTTP_H3=false
XHTTP_H3_PORT_ARG=""
XHTTP_DOMAIN=""
XHTTP_API=""

ARGO_PROTOCOL="http2"
ARGO_PORT="8001"
ARGO_DOMAIN=""
ARGO_TOKEN=""

ENABLE_REALITY=false
REALITY_PORT_ARG=""
REALITY_DEST="addons.mozilla.org"

for arg in "$@"; do
    # 自动过滤双引号、单引号，保留等号用于精准截取
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    case "$clean_arg" in
        naive-h2*)
            ENABLE_NAIVE_H2=true
            val="${clean_arg#naive-h2}"
            NAIVE_H2_PORT_ARG="${val#=}"
            ;;
        naive-h3*)
            ENABLE_NAIVE_H3=true
            val="${clean_arg#naive-h3}"
            NAIVE_H3_PORT_ARG="${val#=}"
            ;;
        naive-domain*)
            val="${clean_arg#naive-domain}"
            NAIVE_DOMAIN="${val#=}"
            ;;
        naive-api*)
            val="${clean_arg#naive-api}"
            NAIVE_API="${val#=}"
            ;;
        xhttp-h2*)
            ENABLE_XHTTP_H2=true
            val="${clean_arg#xhttp-h2}"
            XHTTP_H2_PORT_ARG="${val#=}"
            ;;
        xhttp-h3*)
            ENABLE_XHTTP_H3=true
            val="${clean_arg#xhttp-h3}"
            XHTTP_H3_PORT_ARG="${val#=}"
            ;;
        xhttp-domain*)
            val="${clean_arg#xhttp-domain}"
            XHTTP_DOMAIN="${val#=}"
            ;;
        xhttp-api*)
            val="${clean_arg#xhttp-api}"
            XHTTP_API="${val#=}"
            ;;
        argo-protocol*)
            val="${clean_arg#argo-protocol}"
            ARGO_PROTOCOL="${val#=}"
            ;;
        argo-port*)
            val="${clean_arg#argo-port}"
            ARGO_PORT="${val#=}"
            ;;
        argo-domain*)
            val="${clean_arg#argo-domain}"
            ARGO_DOMAIN="${val#=}"
            ;;
        argo-token*)
            val="${clean_arg#argo-token}"
            ARGO_TOKEN="${val#=}"
            ;;
        reality-dest*)
            ENABLE_REALITY=true
            val="${clean_arg#reality-dest}"
            val="${val#=}"
            [ -n "$val" ] && REALITY_DEST="$val"
            ;;
        reality-port*)
            ENABLE_REALITY=true
            val="${clean_arg#reality-port}"
            REALITY_PORT_ARG="${val#=}"
            ;;
    esac
done

# 端口分配辅助函数（支持随机生成与防冲突）
USED_PORTS=()
get_free_port() {
    local input="$1"
    local port=""
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        port="$input"
    else
        while : ; do
            port=$(shuf -i 10000-65000 -n 1)
            local conflict=false
            for p in "${USED_PORTS[@]}"; do
                [ "$p" = "$port" ] && conflict=true && break
            done
            [ "$conflict" = false ] && break
        done
    fi
    USED_PORTS+=("$port")
    echo "$port"
}

# 计算各协议启用状态与端口
enable_naive=false
if [ "$ENABLE_NAIVE_H2" = true ] || [ "$ENABLE_NAIVE_H3" = true ]; then
    if [ -z "$NAIVE_DOMAIN" ] || [ -z "$NAIVE_API" ]; then
        red "错误：NaiveProxy 缺少必填参数（domain/api），部署已中止！"
        exit 1
    fi
    enable_naive=true
    [ "$ENABLE_NAIVE_H2" = true ] && naive_h2_port=$(get_free_port "$NAIVE_H2_PORT_ARG")
    [ "$ENABLE_NAIVE_H3" = true ] && naive_h3_port=$(get_free_port "$NAIVE_H3_PORT_ARG")
fi

# 2. 严格校验 Argo 隧道必填参数
enable_argo=false
if [ -n "$ARGO_DOMAIN" ] || [ -n "$ARGO_TOKEN" ]; then
    if [ -z "$ARGO_PORT" ] || [ -z "$ARGO_DOMAIN" ] || [ -z "$ARGO_TOKEN" ] || [ -z "$ARGO_PROTOCOL" ]; then
        red "错误：xHTTP Argo 缺少必填参数（port/domain/token），部署已中止！"
        exit 1
    fi
    enable_argo=true
    USED_PORTS+=("$ARGO_PORT")
fi

enable_xhttp_direct=false
if [ "$ENABLE_XHTTP_H2" = true ] || [ "$ENABLE_XHTTP_H3" = true ]; then
    enable_xhttp_direct=true
    [ "$ENABLE_XHTTP_H2" = true ] && xhttp_h2_port=$(get_free_port "$XHTTP_H2_PORT_ARG")
    [ "$ENABLE_XHTTP_H3" = true ] && xhttp_h3_port=$(get_free_port "$XHTTP_H3_PORT_ARG")
fi

reality_port=""
if [ "$ENABLE_REALITY" = true ]; then
    reality_port=$(get_free_port "$REALITY_PORT_ARG")
fi

if [ "$enable_naive" = false ] && [ "$enable_xhttp_direct" = false ] && [ "$enable_argo" = false ] && [ "$ENABLE_REALITY" = false ]; then
    yellow "提示：未检测到有效协议及变量，脚本未启动！"
    exit 0
fi

# ==============================================================================
# 2. 环境初始化与依赖安装
# ==============================================================================
work_dir="/etc/xray"
SBX_DIR="/usr/local/singbox_naive"
NAIVE_CERT_DIR="/root/easyshare/naive"
XHTTP_CERT_DIR="/root/easyshare/xhttp"

systemctl stop xray 2>/dev/null || rc-service xray stop 2>/dev/null || true
systemctl stop naive 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true

green "正在初始化环境与安装必要依赖，请耐心等待..."
if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y curl wget unzip tar openssl iptables coreutils socat jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip tar openssl iptables coreutils socat jq >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add --no-cache bash curl wget unzip tar openssl iptables coreutils socat jq gcompat libc6-compat >/dev/null 2>&1
else
    yellow "未识别的系统包管理器，无法自动安装依赖！"
    exit 1
fi

for cmd in curl unzip tar openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "错误：系统缺少必要组件 [$cmd]，请手动安装后重试！"
        exit 1
    fi
done

ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64') ARCH='64'; GO_ARCH='amd64' ;;
    'aarch64' | 'arm64') ARCH='arm64-v8a'; GO_ARCH='arm64' ;;
    *) ARCH='64'; GO_ARCH='amd64' ;;
esac

# ==============================================================================
# 3. 公共 ACME 证书申请函数 (Cloudflare DNS-01)
# ==============================================================================
issue_cf_cert() {
    local domain="$1"
    local token="$2"
    local dest_dir="$3"
    
    mkdir -p "$dest_dir"
    green "正在为域名 [${domain}] 通过 Cloudflare DNS-01 申请 SSL 证书..."
    export CF_Token="${token}"
    
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    echo "正在安装 acme.sh..."
    curl -# -L --connect-timeout 20 https://get.acme.sh | sh -s email=admin@${domain} --nocron >/dev/null 2>&1
fi
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        rm -rf /tmp/acme.sh-master
        download_file "/tmp/acme.zip" "https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.zip"
        unzip -qo /tmp/acme.zip -d /tmp/ && rm -f /tmp/acme.zip
        (cd /tmp/acme.sh-master && ./acme.sh --install --nocron --accountemail "admin@${domain}" >/dev/null 2>&1)
        rm -rf /tmp/acme.sh-master
    fi
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        red "错误：acme.sh 安装失败，请检查网络，稍后再试！"
        exit 1
    fi
    
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "${domain}" --force || {
        red "错误：[${domain}] 证书申请失败，请检查CF中 API & DNS 设置；若触发次数限制，请更换域名再试！"
        exit 1
    }
    
    "$HOME/.acme.sh/acme.sh" --install-cert -d "${domain}" \
        --cert-file "${dest_dir}/cert.crt" \
        --key-file "${dest_dir}/private.key" \
        --fullchain-file "${dest_dir}/fullchain.cer" \
        --reloadcmd "rc-service xray restart 2>/dev/null; rc-service naive restart 2>/dev/null; systemctl restart xray naive >/dev/null 2>&1" >/dev/null 2>&1
        
    [[ ! -f "${dest_dir}/fullchain.cer" ]] && red "错误：证书安装至 ${dest_dir} 失败！" && exit 1
    green "域名 [${domain}] 证书申请并配置成功！"
}

# ==============================================================================
# 4. 部署 NaiveProxy (基于 Sing-box 原生内核)
# ==============================================================================
if [ "$enable_naive" = true ]; then
    green "---> 开始部署 NaiveProxy (Sing-box 内核)..."
    mkdir -p "${SBX_DIR}"
    
    uuid_file="${SBX_DIR}/uuid"
    if [ ! -f "$uuid_file" ]; then
        naive_uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c 1-16)
        echo "$naive_uuid" > "$uuid_file"
    else
        naive_uuid=$(cat "$uuid_file")
    fi

    # 申请 NaiveProxy 域名证书
    issue_cf_cert "$NAIVE_DOMAIN" "$NAIVE_API" "$NAIVE_CERT_DIR"

    echo "正在获取最新 Sing-box 内核..."
    SB_VERSION=""
    for i in {1..3}; do
        # 尝试通过 GitHub API 获取最新 Release 标签
        SB_VERSION=$(curl -s --connect-timeout 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"v([^"]+)".*/\1/' | tr -d '[:space:]')
        [ -n "$SB_VERSION" ] && break
        sleep 2
    done
    
    # 兜底逻辑：如果 API 获取失败或为空，锁定为 1.14.4 稳定版
    if [ -z "$SB_VERSION" ]; then
        SB_VERSION="1.14.4"
        yellow "未检测到在线版本，已启用 1.14.4 稳定版。"
    else
        green "检测到 Sing-box 最新版本: v${SB_VERSION}"
    fi

    SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${GO_ARCH}.tar.gz"
    echo "正在下载 Sing-box v${SB_VERSION}..."
    download_file "/tmp/sing-box.tar.gz" "$SB_URL" || exit 1

    rm -rf /tmp/sing-box-*
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || {
        red "错误: Sing-box 解压失败！"
        rm -f /tmp/sing-box.tar.gz
        exit 1
    }

    extracted_dir=$(ls -d /tmp/sing-box-*-linux-${GO_ARCH} 2>/dev/null | head -n 1)
    if [ -d "$extracted_dir" ] && [ -f "$extracted_dir/sing-box" ]; then
        mv "$extracted_dir/sing-box" "${SBX_DIR}/sing-box"
        chmod +x "${SBX_DIR}/sing-box"
        green "已启用 Sing-box 内核。"
    else
        red "错误: 未能定位解压后的 sing-box 二进制文件！"
        exit 1
    fi
    rm -rf /tmp/sing-box* /tmp/sing-box.tar.gz

    # ==============================================================================
    # 构建 H2 与 H3 节点配置块
    # ==============================================================================
    naive_inbounds=""

    # 1. 构建 H2 节点（TCP）
    if [ "$ENABLE_NAIVE_H2" = true ]; then
        naive_inbounds='    {
      "type": "naive",
      "tag": "naive-h2-in",
      "network": "tcp",
      "listen": "::",
      "listen_port": '"$naive_h2_port"',
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
        "certificate_path": "'"$NAIVE_CERT_DIR"'/fullchain.cer",
        "key_path": "'"$NAIVE_CERT_DIR"'/private.key"
      }
    }'
    fi

    # 2. 构建 H3 节点（QUIC ）
    if [ "$ENABLE_NAIVE_H3" = true ]; then
        h3_block='    {
      "type": "naive",
      "tag": "naive-h3-in",
      "network": "udp",
      "listen": "::",
      "listen_port": '"$naive_h3_port"',
      "quic_congestion_control": "bbr",
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
        "certificate_path": "'"$NAIVE_CERT_DIR"'/fullchain.cer",
        "key_path": "'"$NAIVE_CERT_DIR"'/private.key"
      }
    }'
        
        # 安全拼接：
        if [ -n "$naive_inbounds" ]; then
            naive_inbounds="${naive_inbounds},"$'\n'"$h3_block"
        else
            naive_inbounds="$h3_block"
        fi
    fi

  # 写入 JSON 配置文件
    cat > "${SBX_DIR}/config.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "warning",
    "timestamp": true
  },
  "inbounds": [
$naive_inbounds
  ]
}
EOF

    # 写入 systemd / OpenRC 服务并启动
    if pidof systemd >/dev/null 2>&1 || [ -d /etc/systemd/system ]; then
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
    else
        cat > /etc/init.d/naive << 'EOF'
#!/sbin/openrc-run
description="Sing-box NaiveProxy Service"
command="/usr/local/singbox_naive/sing-box"
command_args="run -c /usr/local/singbox_naive/config.json"
pidfile="/run/naive.pid"
command_background="yes"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/naive
        rc-update add naive default
        rc-service naive restart
    fi
fi

# ==============================================================================
# 5. 部署 Xray-core (xHTTP直连 / xHTTP-Argo / Reality)
# ==============================================================================
enable_xray=false
if [ "$enable_xhttp_direct" = true ] || [ "$enable_argo" = true ] || [ "$ENABLE_REALITY" = true ]; then
    enable_xray=true
    mkdir -p "${work_dir}"
   
    # 处理 xHTTP 直连证书（域名+API 真实证书 vs 自签证书）
    xhttp_use_acme=false
    if [ "$enable_xhttp_direct" = true ]; then
        if [ -n "$XHTTP_DOMAIN" ] && [ -n "$XHTTP_API" ]; then
            green "---> 开始部署 XHTTP (Xray-core)..."
            issue_cf_cert "$XHTTP_DOMAIN" "$XHTTP_API" "$XHTTP_CERT_DIR"
            xhttp_cert_file="${XHTTP_CERT_DIR}/fullchain.cer"
            xhttp_key_file="${XHTTP_CERT_DIR}/private.key"
            xhttp_sni="$XHTTP_DOMAIN"
            xhttp_insecure="0"
            xhttp_use_acme=true
        else
            echo "xHTTP 未填写域名与 API，将使用自签证书..."
            openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
            openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
            xhttp_cert_file="${work_dir}/cert.pem"
            xhttp_key_file="${work_dir}/private.key"
            xhttp_sni="bing.com"
            xhttp_insecure="1"
        fi
    fi
    
if [ "$enable_argo" = true ]; then
        echo "正在下载 Cloudflared..."
        download_file "${work_dir}/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${GO_ARCH}" || exit 1
        chmod +x "${work_dir}/cloudflared"
    fi
 echo "正在下载 Xray-core..."
    download_file "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip" || exit 1
    unzip -qo "${work_dir}/xray.zip" -d "${work_dir}/" && rm -f "${work_dir}/xray.zip"
    chmod +x "${work_dir}/xray"
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    xhttp_h2_path="${uuid}-xh2"
    xhttp_h3_path="${uuid}-xh3"
    argo_path="${uuid}-argo"

# 启动 Cloudflared 服务（已适配 systemd 与 OpenRC 双系统）
    if [ "$enable_argo" = true ]; then
        argo_connections="1"
        argo_proto_lower=$(echo "$ARGO_PROTOCOL" | tr '[:upper:]' '[:lower:]')
        [ "$argo_proto_lower" = "http2" ] && argo_connections="4"

    green "启动 Cloudflare Argo 固定隧道 (协议: ${ARGO_PROTOCOL}, 连接数: ${argo_connections})..."
        
        if pidof systemd >/dev/null 2>&1 || [ -d /etc/systemd/system ]; then
            cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnels Service
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=${work_dir}/cloudflared tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${ARGO_PROTOCOL} --ha-connections ${argo_connections} run --token ${ARGO_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now cloudflared >/dev/null 2>&1
        else
            cat > /etc/init.d/cloudflared << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnels Service"
command="${work_dir}/cloudflared"
command_args="tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${ARGO_PROTOCOL} --ha-connections ${argo_connections} run --token ${ARGO_TOKEN}"
pidfile="/run/cloudflared.pid"
command_background="yes"

depend() {
    need net
}
EOF
            chmod +x /etc/init.d/cloudflared
            rc-update add cloudflared default >/dev/null 2>&1
            rc-service cloudflared restart
        fi
    fi

    # 生成 Reality 密钥对
    if [ "$ENABLE_REALITY" = true ]; then
       green "---> 开始部署 VLESS TCP Reality Vision..."
        key_pair=$("${work_dir}/xray" x25519)
        private_key_x=$(echo "$key_pair" | awk -F':' '/PrivateKey/ {print $2}' | xargs)
        public_key_x=$(echo "$key_pair" | awk -F':' '/Password/ {print $2}' | xargs)
        short_id_x=$(date +%s%N | sha256sum | cut -c 1-8)
        green "-> VLESS TCP Reality Vision 部署完成。"
    fi

    inbounds_arr=()

    # 4.1 Reality Inbound
    if [ "$ENABLE_REALITY" = true ]; then
        inbounds_arr+=( "{
      \"tag\": \"tcp-reality\",
      \"listen\": \"::\",
      \"port\": $reality_port,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"fingerprint\": \"chrome\",
          \"target\": \"$REALITY_DEST:443\",
          \"serverNames\": [\"$REALITY_DEST\"],
          \"privateKey\": \"$private_key_x\",
          \"shortIds\": [\"$short_id_x\"]
        }
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"metadataOnly\": false}
    }" )
    fi

    # 4.2 xHTTP-H2 直连 Inbound
    if [ "$ENABLE_XHTTP_H2" = true ]; then
        inbounds_arr+=( "{
      \"tag\": \"xhttp-h2\",
      \"listen\": \"::\",
      \"port\": $xhttp_h2_port,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [{\"id\": \"$uuid\", \"flow\": \"\"}],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"tls\",
        \"xhttpSettings\": {
          \"mode\": \"auto\",
          \"path\": \"/$xhttp_h2_path\"
        },
        \"tlsSettings\": {
          \"alpn\": [\"h2\", \"http/1.1\"],
          \"certificates\": [{\"certificateFile\": \"$xhttp_cert_file\", \"keyFile\": \"$xhttp_key_file\"}]
        }
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"metadataOnly\": false}
    }" )
    fi

    # 4.3 xHTTP-H3 直连 Inbound
    if [ "$ENABLE_XHTTP_H3" = true ]; then
        inbounds_arr+=( "{
      \"tag\": \"xhttp-h3\",
      \"listen\": \"::\",
      \"port\": $xhttp_h3_port,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [{\"id\": \"$uuid\", \"flow\": \"\"}],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"tls\",
        \"xhttpSettings\": {
          \"mode\": \"auto\",
          \"path\": \"/$xhttp_h3_path\"
        },
        \"tlsSettings\": {
          \"alpn\": [\"h3\"],
          \"certificates\": [{\"certificateFile\": \"$xhttp_cert_file\", \"keyFile\": \"$xhttp_key_file\"}]
        }
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"metadataOnly\": false}
    }" )
    fi

    # 4.4 xHTTP-Argo Inbound
    if [ "$enable_argo" = true ]; then
        inbounds_arr+=( "{
      \"tag\": \"xhttp-argo\",
      \"listen\": \"127.0.0.1\",
      \"port\": $ARGO_PORT,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [{\"id\": \"$uuid\"}],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"none\",
        \"xhttpSettings\": {
          \"path\": \"/$argo_path\",
          \"mode\": \"auto\"
        }
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"metadataOnly\": false}
    }" )
    fi

    inbounds_json=$(IFS=,; echo "${inbounds_arr[*]}")

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

    # 启动 Xray 服务
    if pidof systemd >/dev/null 2>&1 || [ -d /etc/systemd/system ]; then
        green "已启用 Xray-core 服务..."
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
    else
        green "已启用 Xray-core 服务 (OpenRC)..."
        cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray Service"
command="/etc/xray/xray"
command_args="run -config /etc/xray/config.json"
pidfile="/run/xray.pid"
command_background="yes"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default
        rc-service xray restart
    fi
fi

# ==============================================================================
# 6. 统一防火墙放行
# ==============================================================================
for p in "$naive_h2_port" "$naive_h3_port" "$xhttp_h2_port" "$xhttp_h3_port" "$reality_port"; do
    [ -z "$p" ] && continue
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow $p/tcp >/dev/null 2>&1
        ufw allow $p/udp >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport $p -j ACCEPT 2>/dev/null
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -I INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null
        ip6tables -I INPUT -p udp --dport $p -j ACCEPT 2>/dev/null
    fi
done

# ==============================================================================
# 7. 获取 IP / GeoIP 并生成全协议节点输出
# ==============================================================================
echo "获取服务器 IP 与节点信息中..."
raw_ip=$(curl -4 -sm 2 ip.sb || curl -6 -sm 2 ip.sb)
if [[ "$raw_ip" =~ : ]]; then
    server_ip="[$raw_ip]"
else
    server_ip="$raw_ip"
fi

declare -A sc=([A]=ᴀ [B]=ʙ [C]=ᴄ [D]=ᴅ [E]=ᴇ [F]=ꜰ [G]=ɢ [H]=ʜ [I]=ɪ [J]=ᴊ [K]=ᴋ [L]=ʟ [M]=ᴍ [N]=ɴ [O]=ᴏ [P]=ᴘ [Q]=ꞯ [R]=ʀ [S]=ꜱ [T]=ᴛ [U]=ᴜ [V]=ᴠ [W]=ᴡ [X]=x [Y]=ʏ [Z]=ᴢ)

uc=$(curl -sm 3 "https://ipinfo.io/country" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
if [ -z "$uc" ] || [ ${#uc} -ne 2 ]; then
    uc=$(curl -sm 3 "https://api.ip.sb/geoip" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
fi

isp="${sc[${uc:0:1}]}${sc[${uc:1:1}]}"
[[ -z "$isp" ]] && isp="ɴᴅ"

ESS="ᴇꜱꜱ"
cfip_h2="www.visa.com.hk"
cfip_h3="www.teamviewer.com"
cfport="443"

clear
echo "=========================================================================================="
echo " 部署完成！节点链接如下："
echo "=========================================================================================="

# 1. NaiveProxy 输出
if [ "$enable_naive" = true ]; then
    green "[sing-box] NaiveProxy 节点 (支持 v2rayN / Hiddify)："
    [ "$ENABLE_NAIVE_H2" = true ] && echo -e "\e[1;33mnaive+https://${naive_uuid}:${naive_uuid}@${NAIVE_DOMAIN}:${naive_h2_port}?security=tls&sni=${NAIVE_DOMAIN}#${isp}%20Naive-H2%20${ESS}\e[0m"
    [ "$ENABLE_NAIVE_H3" = true ] && echo -e "\e[1;33mnaive+quic://${naive_uuid}:${naive_uuid}@${NAIVE_DOMAIN}:${naive_h3_port}?congestion_control=bbr&security=tls&sni=${NAIVE_DOMAIN}#${isp}%20Naive-H3%20${ESS}\e[0m"
    echo "------------------------------------------------------------------------------------------"
fi

if [ "$enable_xray" = true ]; then
    xhttp_connect_host="$server_ip"
    [ "$xhttp_use_acme" = true ] && xhttp_connect_host="$XHTTP_DOMAIN"

    # 2. xHTTP 直连输出
    if [ "$ENABLE_XHTTP_H2" = true ] || [ "$ENABLE_XHTTP_H3" = true ]; then
        green "[Xray-core] xHTTP 直连节点 (支持 v2rayN / Hiddify / Karing / NekoBox)："
        [ "$ENABLE_XHTTP_H2" = true ] && echo -e "\e[1;33mvless://${uuid}@${xhttp_connect_host}:${xhttp_h2_port}?encryption=none&security=tls&sni=${xhttp_sni}&alpn=h2&fp=chrome&type=xhttp&mode=auto&path=/${xhttp_h2_path}&allowInsecure=${xhttp_insecure}#${isp}%20XHTTP-H2%20${ESS}\e[0m"
        [ "$ENABLE_XHTTP_H3" = true ] && echo -e "\e[1;33mvless://${uuid}@${xhttp_connect_host}:${xhttp_h3_port}?encryption=none&security=tls&sni=${xhttp_sni}&alpn=h3&fp=chrome&type=xhttp&mode=auto&path=/${xhttp_h3_path}&allowInsecure=${xhttp_insecure}#${isp}%20XHTTP-H3%20${ESS}\e[0m"
        echo "------------------------------------------------------------------------------------------"
    fi
    
    # 3. xHTTP Argo 隧道输出
    if [ "$enable_argo" = true ]; then
        green "[Xray-core] xHTTP Argo 隧道节点 (支持 v2rayN / Hiddify / Karing / NekoBox)："
        echo -e "\e[1;33mvless://${uuid}@${cfip_h2}:${cfport}?encryption=none&security=tls&alpn=h2&sni=${ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${ARGO_DOMAIN}&path=/${argo_path}#${isp}%20Argo-H2%20${ESS}\e[0m"
        echo -e "\e[1;33mvless://${uuid}@${cfip_h3}:${cfport}?encryption=none&security=tls&alpn=h3&sni=${ARGO_DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${ARGO_DOMAIN}&path=/${argo_path}#${isp}%20Argo-H3%20${ESS}\e[0m"
        echo "------------------------------------------------------------------------------------------"
    fi

    # 4. VLESS TCP Reality Vision 输出
    if [ "$ENABLE_REALITY" = true ]; then
        green "[Xray-core] VLESS TCP Reality Vision 节点 (支持 v2rayN / Hiddify / Karing / NekoBox)："
        echo -e "\e[1;33mvless://${uuid}@${server_ip}:${reality_port}?encryption=none&security=reality&sni=${REALITY_DEST}&fp=chrome&pbk=${public_key_x}&sid=${short_id_x}&type=tcp&flow=xtls-rprx-vision#${isp}%20Reality-Vision%20${ESS}\e[0m"
        echo "------------------------------------------------------------------------------------------"
    fi
fi

# ==============================================================================
# 8. 自动配置跨平台证书续期定时任务 (Cron)
# ==============================================================================
# 【只有当 NaiveProxy 启用（100%绑定 acme）或者 xHTTP 直连确实成功调用了 acme 申请时才执行
if [ "$enable_naive" = true ] || [ "$xhttp_use_acme" = true ]; then
    echo "正在配置 DNS-01 证书自动续期守护任务..."
    
    if ! command -v crontab >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            apt install -y cron >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y cronie >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache dcron >/dev/null 2>&1 || true
            rc-update add crond default 2>/dev/null || true
            rc-service crond start 2>/dev/null || crond 2>/dev/null || true
        fi
    fi

    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -q "acme.sh") || {
            (crontab -l 2>/dev/null; echo "0 3 * * * \"/root/.acme.sh\"/acme.sh --cron --home \"/root/.acme.sh\" > /dev/null 2>&1") | crontab -
        }
        green "DNS-01 证书自动续期定时任务已成功配置（每日凌晨 3 点自动检查）！"
        echo "一键查询定时任务状态 & 证书有效期："
        yellow "crontab -l && '/root/.acme.sh/acme.sh' --cron --home '/root/.acme.sh'"
    else
        yellow "提示：当前系统未检测到 crontab 工具，已跳过自动续期任务配置。"
    fi
    echo "=========================================================================================="
fi
echo "一键卸载 (如需移除 Xray-go，请执行)："
yellow "bash <(curl -Ls https://raw.githubusercontent.com/eishare/Xray-go/main/xraygo-uninstall.sh)"
