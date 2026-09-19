#!/bin/bash
# redsocks-transparent-proxy 卸载脚本（恢复直连）
# 用法: sudo bash scripts/uninstall.sh [--purge]
set -euo pipefail

PURGE=no
[ "${1:-}" = "--purge" ] && PURGE=yes
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行: sudo bash scripts/uninstall.sh" >&2; exit 1; }

echo "==> 停止服务 / 移除规则"
systemctl disable --now redsocks-nft 2>/dev/null || true
/usr/sbin/nft delete table ip redsocks 2>/dev/null || true
systemctl disable --now redsocks 2>/dev/null || true

echo "==> 停止 dnsmasq / unbound 并移除配置"
systemctl disable --now dnsmasq 2>/dev/null || true
systemctl disable --now unbound 2>/dev/null || true
rm -f /etc/unbound/unbound.conf.d/redsocks.conf \
      /etc/dnsmasq.d/redsocks.conf /etc/dnsmasq.d/china-domains.conf

echo "==> 恢复 DNS"
if [ -f /etc/resolv.conf.redsocks.bak ]; then
    cp -a /etc/resolv.conf.redsocks.bak /etc/resolv.conf
    rm -f /etc/resolv.conf.redsocks.bak
fi
rm -f /etc/systemd/resolved.conf.d/redsocks.conf
CON=$(nmcli -t -f NAME,DEVICE,TYPE,STATE connection show 2>/dev/null | awk -F: '$4=="activated" && $3!="loopback"{print $1; exit}')
DEV=$(nmcli -t -f NAME,DEVICE,TYPE,STATE connection show 2>/dev/null | awk -F: '$4=="activated" && $3!="loopback"{print $2; exit}')
if [ -n "${CON:-}" ]; then
    nmcli con mod "$CON" ipv4.ignore-auto-dns no >/dev/null 2>&1 || true
    nmcli device reapply "$DEV" >/dev/null 2>&1 || true
fi
if [ ! -s /etc/resolv.conf ]; then
    printf 'nameserver 223.5.5.5\n' > /etc/resolv.conf
fi

echo "==> 删除文件"
rm -f /etc/systemd/system/redsocks-nft.service \
      /usr/local/sbin/redsocks-nft \
      /usr/local/sbin/redsocks-refresh \
      /usr/local/sbin/redsocks-refresh-domains \
      /usr/local/lib/redsocks-transparent-proxy/gen_lists.py \
      /usr/local/share/redsocks-transparent-proxy/README.md \
      /etc/redsocks/chnroute.txt /etc/redsocks/not_cn.txt /etc/redsocks/direct_dst.txt \
      /etc/redsocks-setup.conf /var/log/redsocks.log
rmdir /usr/local/lib/redsocks-transparent-proxy /usr/local/share/redsocks-transparent-proxy /etc/redsocks 2>/dev/null || true
systemctl daemon-reload

if [ "$PURGE" = yes ]; then
    echo "==> 卸载软件包"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge redsocks unbound dnsmasq
fi

echo "已卸载，网络恢复直连。"
