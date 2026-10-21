#!/bin/bash

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 恢复默认颜色

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：必须使用 root 用户运行此脚本！请使用 sudo -i 切换后重试。${NC}"
   exit 1
fi

# ==================== 安装功能 ====================
function install_singbox() {
    echo -e "\n${YELLOW}📝 请输入节点配置信息：${NC}"

    read -p "👉 请输入你的解析好的域名 (例如: naive.example.com): " DOMAIN
    read -p "👉 请输入你的邮箱 (用于 Let's Encrypt 自动申请证书): " EMAIL
    read -p "👉 请设置 NaiveProxy 用户名 (默认直接回车为 user123): " USERNAME
    USERNAME=${USERNAME:-user123}
    read -p "👉 请设置 NaiveProxy 密码 (默认直接回车为 pass123): " PASSWORD
    PASSWORD=${PASSWORD:-pass123}
    read -p "👉 请给这个节点起个名字 (默认直接回车为 NaiveProxy): " NODE_NAME
    NODE_NAME=${NODE_NAME:-NaiveProxy}

    echo -e "\n${YELLOW}🧹 [1/4] 正在清理旧环境，释放 80 和 443 端口...${NC}"
    systemctl stop caddy sing-box nginx apache2 2>/dev/null
    pkill -9 caddy sing-box nginx apache2 2>/dev/null

    echo -e "${YELLOW}📦 [2/4] 正在下载并安装 Sing-box (1.13.0)...${NC}"
    cd /tmp
    wget -qO sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.13.0-rc.5/sing-box-1.13.0-rc.5-linux-amd64.tar.gz
    tar -zxf sing-box.tar.gz
    cp sing-box-1.13.0-rc.5-linux-amd64/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-1.13.0-rc.5-linux-amd64

    echo -e "${YELLOW}⚙️ [3/4] 正在生成服务端配置文件...${NC}"
    mkdir -p /etc/sing-box
    cat << 'EOF' > /etc/sing-box/config.json
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "username": "REPLACE_USERNAME",
          "password": "REPLACE_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REPLACE_DOMAIN",
        "acme": {
          "domain": ["REPLACE_DOMAIN"],
          "email": "REPLACE_EMAIL"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # 替换配置文件里的变量
    sed -i "s/REPLACE_USERNAME/$USERNAME/g" /etc/sing-box/config.json
    sed -i "s/REPLACE_PASSWORD/$PASSWORD/g" /etc/sing-box/config.json
    sed -i "s/REPLACE_DOMAIN/$DOMAIN/g" /etc/sing-box/config.json
    sed -i "s/REPLACE_EMAIL/$EMAIL/g" /etc/sing-box/config.json

    echo -e "${YELLOW}🚀 [4/4] 正在配置系统服务并启动 Sing-box...${NC}"

    echo -e "${YELLOW}🛡️ 正在自动放行系统防火墙端口...${NC}"
    ufw allow 80,443/tcp 2>/dev/null
    ufw allow 443/udp 2>/dev/null
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null
    
    cat << 'EOF' > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box

    SHARE_LINK="naive+https://${USERNAME}:${PASSWORD}@${DOMAIN}:443?padding=true#${NODE_NAME}"

    echo -e "\n${GREEN}==================================================${NC}"
    echo -e "${GREEN}🎉 搭建彻底完成！${NC}"
    echo -e "--------------------------------------------------"
    echo -e "${YELLOW}👇 请复制下方链接，直接导入到你的 Flowz 客户端：${NC}"
    echo -e ""
    echo -e "${CYAN}${SHARE_LINK}${NC}"
    echo -e ""
    echo -e "--------------------------------------------------"
    echo -e "${YELLOW}⚠️ 注意事项：${NC}"
    echo -e "1. 首次启动时，Sing-box 需要向 Let's Encrypt 申请证书，请等待 1-2 分钟后再连接。"
    echo -e "2. 如果连接失败，请在 VPS 运行以下命令查看证书是否申请成功："
    echo -e "   ${GREEN}journalctl -u sing-box -f${NC}"
    echo -e "${GREEN}==================================================${NC}"
}

# ==================== 卸载功能 ====================
function uninstall_singbox() {
    echo -e "\n${YELLOW}⚠️ 准备卸载 Sing-box...${NC}"
    read -p "确定要彻底卸载 Sing-box 及其所有配置文件吗？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${GREEN}已取消卸载。${NC}"
        exit 0
    fi

    echo -e "${YELLOW}正在停止并禁用系统服务...${NC}"
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null

    echo -e "${YELLOW}正在删除核心文件和配置文件...${NC}"
    rm -f /usr/local/bin/sing-box
    rm -rf /etc/sing-box
    rm -f /etc/systemd/system/sing-box.service

    echo -e "${YELLOW}正在重载系统守护进程...${NC}"
    systemctl daemon-reload

    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}🗑️ 卸载完成！Sing-box 已从你的系统中彻底移除。${NC}"
    echo -e "${GREEN}==================================================${NC}"
}

# ==================== 主菜单 ====================
function main_menu() {
    clear
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${CYAN}      Sing-box (NaiveProxy 协议) 一键管理脚本     ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "  ${YELLOW}1.${NC} 安装 Sing-box (Naive 协议)"
    echo -e "  ${YELLOW}2.${NC} 彻底卸载 Sing-box"
    echo -e "  ${YELLOW}0.${NC} 退出脚本"
    echo -e "${GREEN}==================================================${NC}"
    read -p "请输入数字选择 [0-2]: " choice

    case "$choice" in
        1)
            install_singbox
            ;;
        2)
            uninstall_singbox
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请输入正确的数字！${NC}"
            sleep 2
            main_menu
            ;;
    esac
}

# 运行主菜单
main_menu
