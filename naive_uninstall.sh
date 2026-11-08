#!/bin/bash

# ==========================================
# NaiveProxy 自签证书版一键卸载脚本
# 兼容: Ubuntu / Debian / Alpine
# ==========================================

# 检查执行权限
if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 root 权限运行此脚本 (sudo -i)"
  exit 1
fi

echo "[+] 开始清理并卸载 NaïveProxy 及相关组件..."

# 1. 停止并禁用 Sing-box 服务
if systemctl list-units --type=service --all | grep -q "sing-box.service"; then
    echo "[*] 正在停止 sing-box 服务..."
    systemctl stop sing-box
    systemctl disable sing-box
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    echo "[+] sing-box 服务已清除"
fi

# 2. 删除 Sing-box 二进制文件
if [ -f /usr/local/bin/sing-box ]; then
    rm -f /usr/local/bin/sing-box
    echo "[+] 已删除 sing-box 内核主程序"
fi

# 3. 删除自签证书与账号凭证目录
if [ -d /etc/naive ]; then
    rm -rf /etc/naive
    echo "[+] 已清理证书与认证目录 (/etc/naive)"
fi

# 4. 删除配置文件目录
if [ -d /etc/sing-box ]; then
    rm -rf /etc/sing-box
    echo "[+] 已清理配置文件目录 (/etc/sing-box)"
fi

echo "=================================================="
echo "🎉 NaïveProxy 卸载完成！服务器已恢复干净状态。"
echo "=================================================="
