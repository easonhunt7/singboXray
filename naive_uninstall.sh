#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本 (sudo -i)"
  exit 1
fi

echo "==> 1. 停止并清理所有 Caddy 进程..."
pkill -f caddy 2>/dev/null
killall -9 caddy 2>/dev/null

echo "==> 2. 卸载 Caddy 服务与删除二进制文件..."
systemctl stop caddy 2>/dev/null
systemctl disable caddy 2>/dev/null
rm -f /etc/systemd/system/caddy.service
rm -f /usr/bin/caddy
systemctl daemon-reload

echo "==> 3. 清理 Caddy 配置文件与证书残留目录..."
rm -rf /etc/caddy
rm -rf /etc/ssl/caddy
rm -rf /root/.local/share/caddy
rm -rf /root/.config/caddy
# 清理你前面提到的 easyshare 目录（存放证书的位置，可根据需要保留）
rm -rf /root/easyshare

echo "==> 4. 重置系统防火墙（可选：清空 iptables 规则）..."
iptables -F
ip6tables -F

echo "=========================================="
echo "🎉 Caddy 及相关代理环境已彻底卸载清理完毕！"
echo "=========================================="
