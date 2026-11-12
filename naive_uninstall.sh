#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本 (sudo -i)"
  exit 1
fi

echo "==> 1. 停止并清理所有 Sing-box 进程..."
pkill -f sing-box 2>/dev/null
killall -9 sing-box 2>/dev/null

echo "==> 2. 卸载 NaiveProxy 服务与删除 systemd 单元..."
systemctl stop naive 2>/dev/null
systemctl disable naive 2>/dev/null
rm -f /etc/systemd/system/naive.service
systemctl daemon-reload

echo "==> 3. 清理 Sing-box 核心及证书残留目录..."
rm -rf /usr/local/singbox_naive
rm -rf /root/easyshare

echo "==> 4. 顺手清理历史可能残留的 Caddy 文件（防范残留）..."
pkill -f caddy 2>/dev/null
killall -9 caddy 2>/dev/null
rm -f /usr/bin/caddy
rm -rf /usr/local/easyshare_core
rm -rf /root/.local/share/caddy
rm -rf /root/.config/caddy

echo "=========================================="
echo "🎉 Sing-box 原生 NaiveProxy 环境已彻底卸载清理完毕！"
echo "=========================================="
