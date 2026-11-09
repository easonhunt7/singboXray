#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "必须以 root 用户运行此脚本！" && exit 1

port_arg="y"
naive_domain=""
cf_token=""

# 智能解析紧凑无等号参数
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

# 防错兜底
if [ -z "$naive_domain" ]; then
    for arg in "$@"; do
        if [[ "$arg" == *naivedomain* ]]; then
            naive_domain=$(echo "$arg" | sed 's/.*naivedomain//;s/[\"'\'']//g')
        fi
    done
fi

if [ -z "$cf_token" ]; then
    for arg in "$@"; do
        if [[ "$arg" == *api* ]]; then
            cf_token=$(echo "$arg" | sed 's/.*api//;s/[\"'\'']//g')
        fi
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

NAIVE_DATA_SYSTEMD="/usr/local/naive/"

green "---> 正在检查系统环境与网络..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl systemd openssl jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl systemd openssl jq >/dev/null 2>&1
fi

get_arch="amd64"
[[ $(arch) =~ ("aarch64"|"arm64") ]] && get_arch="arm64"

mkdir -p ${NAIVE_DATA_SYSTEMD}
mkdir -p ${NAIVE_DATA_SYSTEMD}html/

if [ ! -f "${NAIVE_DATA_SYSTEMD}html/index.html" ]; then
    cat >"${NAIVE_DATA_SYSTEMD}html/index.html" <<EOF
<!DOCTYPE html>
<html><head><title>Welcome!</title></head><body><h1>System Operational</h1></body></html>
EOF
fi

uuid_file="${NAIVE_DATA_SYSTEMD}uuid"
if [ ! -f "$uuid_file" ]; then
    naive_uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$naive_uuid" > "$uuid_file"
else
    naive_uuid=$(cat "$uuid_file")
fi

auth_str=$(echo -n "${naive_uuid}:${naive_uuid}" | base64 | tr -d '\n' | base64 | tr -d '\n')

green "---> 正在下载并安装服务端核心..."
bin_url="https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-${get_arch}"
curl -fLss "${bin_url}" -o /usr/local/naive/naive || { red "核心下载失败，请检查网络！"; exit 1; }
chmod +x /usr/local/naive/naive

green "---> 正在生成 NaïveProxy 配置文件..."
cat > "${NAIVE_DATA_SYSTEMD}naive.json" << EOF
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
EOF

cat > /etc/systemd/system/naive.service << EOF
[Unit]
Description=Official NaiveProxy Service (Cloudflare DNS-01)
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/naive/naive run --config ${NAIVE_DATA_SYSTEMD}naive.json
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
