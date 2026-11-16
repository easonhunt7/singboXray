#!/bin/bash

export LANG=en_US.UTF-8
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;31m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请在 root 用户下运行此卸载脚本！" && exit 1

echo "=========================================================================================="
yellow " 正在开始完全卸载 Xray-core、Sing-box、Argo 隧道及 acme.sh..."
echo "=========================================================================================="

# 1. 停止并禁用 systemd 服务
if pidof systemd >/dev/null 2>&1 || [ -d /etc/systemd/system ]; then
    for svc in xray cloudflared naive; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            echo "正在停止并移除 ${svc} 服务..."
            systemctl stop "$svc" >/dev/null 2>&1
            systemctl disable "$svc" >/dev/null 2>&1
        fi
        rm -f "/etc/systemd/system/${svc}.service"
    done
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed >/dev/null 2>&1
fi

# 2. 兼容清理 OpenRC 服务 (Alpine 等系统)
if command -v rc-service >/dev/null 2>&1; then
    for svc in xray cloudflared naive; do
        if [ -f "/etc/init.d/${svc}" ]; then
            echo "正在停止并移除 OpenRC 服务 ${svc}..."
            rc-service "$svc" stop >/dev/null 2>&1
            rc-update del "$svc" default >/dev/null 2>&1
            rm -f "/etc/init.d/${svc}"
        fi
    done
fi

# 3. 彻底结束残留进程
pkill -9 -f "/etc/xray/xray" 2>/dev/null || true
pkill -9 -f "/etc/xray/cloudflared" 2>/dev/null || true
pkill -9 -f "/usr/local/singbox_naive/sing-box" 2>/dev/null || true
pkill -9 -f "cloudflared" 2>/dev/null || true

# 4. 清理程序文件、配置及证书目录
echo "正在清理安装目录、配置文件及证书残留..."
rm -rf /etc/xray
rm -rf /usr/local/singbox_naive
rm -rf /root/easyshare
rm -rf /tmp/sing-box* /tmp/xray*

# 5. 彻底卸载 acme.sh 及其定时任务
if [ -f "$HOME/.acme.sh/acme.sh" ]; then
    echo "正在卸载 acme.sh 及其系统定时任务..."
    "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1
    rm -rf "$HOME/.acme.sh"
    # 清理可能残留的 crontab 任务
    crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - 2>/dev/null || true
    green "acme.sh 已彻底卸载！"
else
    yellow "未检测到 acme.sh 安装路径，跳过..."
fi

echo "=========================================================================================="
green " 卸载完成！所有节点服务、配置文件、Argo 隧道以及 acme.sh 已全部彻底清除。"
echo "=========================================================================================="
