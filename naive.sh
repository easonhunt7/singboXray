cat << 'EOF' > /tmp/naive_run.sh
#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "必须以 root 用户运行此脚本！" && exit 1

# 初始化变量
ARG_NAIVE=""
ARG_NAIVEDOMAIN=""
ARG_API=""

# 智能解析复合与紧凑关键字参数（参考你提供的优雅逻辑）
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    if [[ "$clean_arg" =~ ^[nN][aA][iI][vV][eE](.*)$ ]]; then
        ARG_NAIVE="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[nN][aA][iI][vV][eE][dD][oO][mM][aA][iI][nN](.*)$ ]]; then
        ARG_NAIVEDOMAIN="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[aA][pP][iI](.*)$ ]]; then
        ARG_API="${BASH_REMATCH[1]}"
    fi
done

# 变量映射与兜底
port_arg="${ARG_NAIVE:-y}"
naive_domain="${ARG_NAIVEDOMAIN}"
cf_token="${ARG_API}"

# 严格校验必填参数（绝不卡住等待输入）
[[ -z "${naive_domain}" ]] && red "错误: 未检测到有效的域名参数！" && exit 1
[[ -z "${cf_token}" ]] && red "错误: 未检测到有效的 Cloudflare API Token！" && exit 1

if [ "$port_arg" = "y" ] || [ "$port_arg" = "Y" ] || [ -z "$port_arg" ]; then
    naive_port=$(shuf -i 10000-65000 -n 1)
elif [[ "$port_arg" =~ ^[0-9]+$ ]]; then
    naive_port="$port_arg"
else
    naive_port=$(shuf -i 10000-65000 -n 1)
fi

NAIVE_DATA_SYSTEMD="/usr/local/naive/"
naive_config_systemd="/usr/local/naive/naive.json"

green "---> 正在检查系统环境与网络..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl systemd nftables openssl jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl systemd nftables openssl jq >/dev/null 2>&1
fi

get_arch=""
if [[ $(arch) =~ ("x86_64"|"amd64") ]]; then
    get_arch="amd64"
elif [[ $(arch) =~ ("aarch64"|"arm64") ]]; then
    get_arch="arm64"
else
    red "仅支持 x86_64/amd64 与 arm64/aarch64 架构"
    exit 1
fi

mkdir -p ${NAIVE_DATA_SYSTEMD}
mkdir -p ${NAIVE_DATA_SYSTEMD}html/

if [ ! -f "${NAIVE_DATA_SYSTEMD}html/index.html" ]; then
    cat >"${NAIVE_DATA_SYSTEMD}html/index.html" <<HTMLEOF
<!DOCTYPE html>
<html><head><title>Welcome!</title></head><body><h1>System Operational</h1></body></html>
HTMLEOF
fi

uuid_file="${NAIVE_DATA_SYSTEMD}uuid"
if [ ! -f "$uuid_file" ]; then
    naive_uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$naive_uuid" > "$uuid_file"
else
    naive_uuid=$(cat "$uuid_file")
fi

auth_str=$(echo -n "${naive_uuid}:${naive_uuid}" | base64 | tr --delete '\n' | base64 | tr --delete '\n')

green "---> 正在生成纯 Cloudflare DNS-01 验证的正统 NaïveProxy 配置文件..."

cat >${naive_config_systemd} <<JSONEOF
{
  "admin": { "disabled": true },
  "logging": {
    "sink": { "writer": { "output": "stderr" } },
    "logs": { "default": { "writer": { "output": "stderr" } } }
  },
  "storage": { "module": "file_system", "root": "${NAIVE_DATA_SYSTEMD}file_system/" },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [ ":${naive_port}" ],
          "protocols": [ "h1", "h2", "h3" ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": [ "${auth_str}" ],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [ { "host": [ "${naive_domain}" ] } ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_SYSTEMD}html/",
                          "index_names": [ "index.html", "index.htm" ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [ { "match": { "sni": [ "${naive_domain}" ] } } ],
          "automatic_https": { "disable": false }
        }
      }
    },
    "tls": {
      "certificates": { "automate": [ "${naive_domain}" ] },
      "automation": {
        "policies": [
          {
            "issuers": [
              {
                "module": "acme",
                "challenges": {
                  "dns": {
                    "provider": {
                      "name": "cloudflare",
                      "api_token": "${cf_token}"
                    }
                  }
                }
              }
            ]
          }
        ]
      }
    }
  }
}
JSONEOF

green "---> 正在下载并安装服务端核心..."
bin_url="https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-${get_arch}"
curl -fLss "${bin_url}" -o /usr/local/naive/naive || { red "核心下载失败，请检查网络！"; exit 1; }
chmod +x /usr/local/naive/naive

cat > /etc/systemd/system/naive.service << SVIEOF
[Unit]
Description=Official NaiveProxy Service (Cloudflare DNS-01)
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/naive/naive run --config ${naive_config_systemd}
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SVIEOF

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
green " 正统 NaïveProxy (Caddy + forwardproxy) 部署成功！"
green "=========================================================================================="
green "👉 验证方式: Cloudflare DNS-01 自动签证 (不占用 80/443 端口)"
green "👉 绑定的域名: ${naive_domain}"
green "👉 服务端口: ${naive_port}"
green "------------------------------------------------------------------------------------------"
green "👉 客户端分享链接 (可在 v2rayN 中直接导入)："
green "------------------------------------------------------------------------------------------"
echo -e "\e[1;33mnaive+https://${naive_uuid}:${naive_uuid}@${naive_domain}:${naive_port}?security=tls&sni=${naive_domain}#Naive-Official-CF\e[0m"
echo -e "\e[1;33mnaive+quic://${naive_uuid}:${naive_uuid}@${naive_domain}:${naive_port}?congestion_control=bbr&security=tls&sni=${naive_domain}#Naive-Official-QUIC\e[0m"
green "=========================================================================================="
EOF
