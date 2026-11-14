#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请在 root 用户下运行此卸载脚本！" && exit 1

green "=========================================================================================="
green " 开始彻底卸载 Xray-core / Sing-box (NaiveProxy) / Cloudflared / acme.sh..."
green "=========================================================================================="

# 1. 停止并禁用 systemd 服务 (Ubuntu / Debian / CentOS)
if command -v systemctl >/dev/null 2>&1; then
    for svc in xray naive cloudflared; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            echo "正在停止并移除 ${svc} 系统服务..."
            systemctl stop "${svc}" >/dev/null 2>&1
            systemctl disable "${svc}" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${svc}.service"
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed >/dev/null 2>&1
fi

# 2. 兼容 Alpine Linux (OpenRC) 服务清理
if command -v rc-service >/dev/null 2>&1; then
    for svc in xray naive cloudflared; do
        if [ -f "/etc/init.d/${svc}" ]; then
            echo "正在停止并移除 ${svc} (OpenRC) 服务..."
            rc-service "${svc}" stop >/dev/null 2>&1
            rc-update del "${svc}" default >/dev/null 2>&1
            rm -f "/etc/init.d/${svc}"
        fi
    done
fi

# 3. 强制结束可能残留的后台进程
pkill -9 -f "/etc/xray/xray" >/dev/null 2>&1 || true
pkill -9 -f "/etc/xray/cloudflared" >/dev/null 2>&1 || true
pkill -9 -f "/usr/local/singbox_naive/sing-box" >/dev/null 2>&1 || true

# 4. 删除程序目录与共享证书目录
echo "正在删除程序文件、配置文件及证书目录..."
rm -rf /etc/xray
rm -rf /usr/local/singbox_naive
rm -rf /root/easyshare

# 5. 卸载 acme.sh 及其定时续签任务 (crontab)
if [ -d "$HOME/.acme.sh" ]; then
    echo "正在卸载 acme.sh 及清理定时任务..."
    "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1
    rm -rf "$HOME/.acme.sh"
fi

# 6. 清理系统环境变量中可能残留的 CF_Token
sed -i '/CF_Token/d' ~/.bashrc ~/.profile 2>/dev/null || true

green "=========================================================================================="
green " 卸载完成！所有相关服务、内核程序、证书文件及定时任务均已彻底清除。"
green "=========================================================================================="
