#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# 初始化变量
port_arg="y"
naive_domain=""
cf_token=""

# 循环遍历所有传入的紧凑参数 (如 port"y" domain"xxx" api"xxx")
for arg in "$@"; do
    case "$arg" in
        port*)
            port_arg="${arg#port}"
            ;;
        domain*)
            naive_domain="${arg#domain}"
            ;;
        api*)
            cf_token="${arg#api}"
            ;;
    esac
done

# 如果变量成功接收，直接跳过交互输入
if [ -n "$naive_domain" ]; then
    echo "检测到传入的域名: $naive_domain"
fi

if [ -n "$cf_token" ]; then
    echo "检测到传入的 Cloudflare API Token"
fi

NAIVE_DATA_SYSTEMD="/usr/local/naive/"
naive_config_systemd="/usr/local/naive/naive.json"

# 2. 系统环境与依赖检查
green "---> 正在检查系统环境与网络..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl systemd nftables openssl jq >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl systemd nftables openssl jq >/dev/null 2>&1
fi

# 3. 架构判断与 xcaddy/caddy (带 cloudflare 插件) 编译准备
# 正统 NaïveProxy 依赖带有 forwardproxy 插件的 Caddy
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

# 生成默认伪装主页
if [ ! -f "${NAIVE_DATA_SYSTEMD}html/index.html" ]; then
    cat >"${NAIVE_DATA_SYSTEMD}html/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome!</title></head>
<body><h1>System Operational</h1></body>
</html>
EOF
fi

# 4. 生成固定的鉴权凭证 (UUID 作为用户名和密码)
uuid_file="${NAIVE_DATA_SYSTEMD}uuid"
if [ ! -f "$uuid_file" ]; then
    naive_uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$naive_uuid" > "$uuid_file"
else
    naive_uuid=$(cat "$uuid_file")
fi

# 计算 NaïveProxy v2.7.6+ 标准的 auth_credentials
auth_str=$(echo -n "${naive_uuid}:${naive_uuid}" | base64 | tr --delete '\n' | base64 | tr --delete '\n')

green "---> 正在生成纯 Cloudflare DNS-01 验证的正统 NaïveProxy 配置文件..."

# 5. 写入纯 CF 验证的 Caddy/Naïve JSON 核心配置
cat >${naive_config_systemd} <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage": {
    "module": "file_system",
    "root": "${NAIVE_DATA_SYSTEMD}file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":${naive_port}"
          ],
          "protocols": [
            "h1",
            "h2",
            "h3"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": [
                            "${auth_str}"
                          ],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "${naive_domain}"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${NAIVE_DATA_SYSTEMD}html/",
                          "index_names": [
                            "index.html",
                            "index.htm"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "${naive_domain}"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": false
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": [
          "${naive_domain}"
        ]
      },
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

# 6. 下载原汁原味的二进制核心并配置 Systemd 服务
green "---> 正在下载并安装服务端核心..."
bin_url="https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-${get_arch}"
curl -fsSL "${bin_url}" -o /usr/local/naive/naive || { red "核心下载失败，请检查网络！"; exit 1; }
chmod +x /usr/local/naive/naive

# 编写 systemd 服务文件
cat > /etc/systemd/system/naive.service << EOF
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
EOF

systemctl daemon-reload
systemctl enable --now naive >/dev/null 2>&1

# 7. 开放防火墙端口
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
    ip6tables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null
fi

# 获取本机公网 IP（完美兼容纯 IPv6）
raw_ip=$(curl -6 -sm 2 ip.sb || curl -4 -sm 2 ip.sb)
[[ "$raw_ip" =~ : ]] && server_ip="[$raw_ip]" || server_ip="$raw_ip"

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
