#!/bin/bash
# redsocks-transparent-proxy 安装脚本
#
# 目标：Linux 服务器（Debian/Ubuntu 优先）
#   - 访问国外（非中国 IP）的 TCP 流量经 SOCKS/HTTP 代理出去
#   - 中国 IP 直连
#   - DNS 按域名分流：国内域名走国内 DNS，国外域名经代理解析（防污染）
#
# 用法: sudo bash scripts/install.sh --proxy HOST:PORT [选项]
set -euo pipefail

CONF=/etc/redsocks-setup.conf
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="$ROOT/assets"
SCRIPTS="$ROOT/scripts"
LIBDIR=/usr/local/lib/redsocks-transparent-proxy
SBINDIR=/usr/local/sbin
SHAREDIR=/usr/local/share/redsocks-transparent-proxy

die() { echo "错误: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash scripts/install.sh --proxy HOST:PORT [选项]

必需:
  --proxy HOST:PORT     代理服务器, 如 10.0.0.1:1080
选项:
  --type TYPE           代理类型: socks5(默认) | socks4 | http-connect | http-relay
  --user USER           代理用户名
  --pass PASS           代理密码
  --direct-dns IP       国内 DNS, 默认 223.5.5.5
  --remote-dns IP       国外 DNS, 默认 8.8.8.8
  --remote-dns2 IP      国外备用 DNS, 默认 1.1.1.1
  --no-dns-split        关闭国内域名分流（所有 DNS 都经代理）
  --port PORT           redsocks 本地监听端口, 默认 12345
  -y, --yes             非交互
  -h, --help            显示帮助
EOF
}

PROXY=""; PROXY_TYPE=socks5; PROXY_USER=""; PROXY_PASS=""
DIRECT_DNS=223.5.5.5; REMOTE_DNS=8.8.8.8; REMOTE_DNS2=1.1.1.1
DNS_SPLIT=yes; TCP_REDIRECT_PORT=12345

while [ $# -gt 0 ]; do
    case "$1" in
        --proxy)        PROXY=$2; shift 2 ;;
        --type)         PROXY_TYPE=$2; shift 2 ;;
        --user)         PROXY_USER=$2; shift 2 ;;
        --pass)         PROXY_PASS=$2; shift 2 ;;
        --direct-dns)   DIRECT_DNS=$2; shift 2 ;;
        --remote-dns)   REMOTE_DNS=$2; shift 2 ;;
        --remote-dns2)  REMOTE_DNS2=$2; shift 2 ;;
        --no-dns-split) DNS_SPLIT=no; shift ;;
        --port)         TCP_REDIRECT_PORT=$2; shift 2 ;;
        -y|--yes)       shift ;;
        -h|--help)      usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行: sudo bash scripts/install.sh --proxy HOST:PORT"
[ -n "$PROXY" ] || { usage; die "缺少 --proxy HOST:PORT"; }
case "$PROXY" in *:*) ;; *) die "--proxy 需要 HOST:PORT 格式" ;; esac
PROXY_IP=${PROXY%:*}; PROXY_PORT=${PROXY##*:}
[ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ] || die "--proxy 格式错误: $PROXY"
case "$PROXY_TYPE" in
    socks5|socks4|http-connect|http-relay) ;;
    *) die "不支持的 --type: $PROXY_TYPE" ;;
esac

UNBOUND_PORT=5353
[ "$DNS_SPLIT" = yes ] || UNBOUND_PORT=53

case "$PROXY_TYPE" in
    socks5) PSCHEME=socks5h ;;
    socks4) PSCHEME=socks4a ;;
    *)      PSCHEME=http ;;
esac
if [ -n "$PROXY_USER" ]; then
    FALLBACK_PROXY="$PSCHEME://$PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT"
else
    FALLBACK_PROXY="$PSCHEME://$PROXY_IP:$PROXY_PORT"
fi
export FALLBACK_PROXY

echo "==> 1/8 安装软件包"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
PKGS="redsocks unbound"
[ "$DNS_SPLIT" = yes ] && PKGS="$PKGS dnsmasq"
# shellcheck disable=SC2086
apt-get install -y -qq $PKGS
[ "$DNS_SPLIT" = yes ] && { systemctl stop dnsmasq 2>/dev/null || true; }

echo "==> 2/8 写入配置"
install -d -m 0755 /etc/redsocks "$LIBDIR" "$SHAREDIR" /etc/unbound/unbound.conf.d /etc/dnsmasq.d
cat > "$CONF" <<EOF
# redsocks-transparent-proxy 生成，勿手工改动（如需改代理请重跑 install.sh）
PROXY_IP=$PROXY_IP
PROXY_PORT=$PROXY_PORT
PROXY_TYPE=$PROXY_TYPE
PROXY_USER=$PROXY_USER
PROXY_PASS=$PROXY_PASS
TCP_REDIRECT_PORT=$TCP_REDIRECT_PORT
DNS_SPLIT=$DNS_SPLIT
DIRECT_DNS=$DIRECT_DNS
REMOTE_DNS=$REMOTE_DNS
REMOTE_DNS2=$REMOTE_DNS2
EOF
chmod 600 "$CONF"

AUTH=""
if [ -n "$PROXY_USER" ]; then
    AUTH="    login = \"$PROXY_USER\";
    password = \"$PROXY_PASS\";"
fi
cat > /etc/redsocks.conf <<EOF
// 由 redsocks-transparent-proxy 生成
base {
    log_debug = off;
    log_info = on;
    log = "file:/var/log/redsocks.log";
    daemon = on;
    user = redsocks;
    group = redsocks;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $TCP_REDIRECT_PORT;
    ip = $PROXY_IP;
    port = $PROXY_PORT;
    type = $PROXY_TYPE;
$AUTH
}
EOF

cat > /etc/unbound/unbound.conf.d/redsocks.conf <<EOF
# 由 redsocks-transparent-proxy 生成
server:
    interface: 127.0.0.1
    port: $UNBOUND_PORT
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
    do-not-query-localhost: no

forward-zone:
    name: "."
    forward-addr: $REMOTE_DNS
    forward-addr: $REMOTE_DNS2
    forward-tcp-upstream: yes
EOF

if [ "$DNS_SPLIT" = yes ]; then
    cat > /etc/dnsmasq.d/redsocks.conf <<EOF
# 由 redsocks-transparent-proxy 生成
port=53
listen-address=127.0.0.1
bind-interfaces
no-resolv
cache-size=10000
dns-forward-max=1000
server=127.0.0.1#$UNBOUND_PORT
server=/.cn/$DIRECT_DNS
EOF
else
    rm -f /etc/dnsmasq.d/redsocks.conf /etc/dnsmasq.d/china-domains.conf
fi

echo "==> 3/8 安装脚本与资源"
install -m 0755 "$SCRIPTS/redsocks-nft.sh"          "$SBINDIR/redsocks-nft"
install -m 0755 "$SCRIPTS/refresh-lists.sh"         "$SBINDIR/redsocks-refresh"
install -m 0755 "$SCRIPTS/refresh-china-domains.sh" "$SBINDIR/redsocks-refresh-domains"
install -m 0755 "$SCRIPTS/gen_lists.py"             "$LIBDIR/gen_lists.py"
install -m 0644 "$ASSETS/redsocks-nft.service"      /etc/systemd/system/redsocks-nft.service
[ -f /etc/redsocks/direct_dst.txt ] || install -m 0644 "$ASSETS/direct_dst.txt" /etc/redsocks/direct_dst.txt
[ -f /etc/redsocks/chnroute.txt ]   || install -m 0644 "$ASSETS/chnroute.txt"   /etc/redsocks/chnroute.txt
install -m 0644 "$ROOT/README.md" "$SHAREDIR/README.md" 2>/dev/null || true

echo "==> 4/8 启动 redsocks"
systemctl daemon-reload
systemctl enable redsocks >/dev/null 2>&1 || true
systemctl restart redsocks
sleep 1
systemctl is-active --quiet redsocks || die "redsocks 启动失败: journalctl -u redsocks -n50"

echo "==> 5/8 加载 nftables 规则"
systemctl enable redsocks-nft >/dev/null 2>&1 || true
systemctl restart redsocks-nft
systemctl is-active --quiet redsocks-nft || die "规则加载失败: journalctl -u redsocks-nft -n50"

echo "==> 6/8 启动 unbound (127.0.0.1:$UNBOUND_PORT, 上游 TCP 经代理)"
unbound-checkconf || die "unbound 配置有误"
systemctl enable unbound >/dev/null 2>&1 || true
systemctl restart unbound
sleep 1
systemctl is-active --quiet unbound || die "unbound 启动失败: journalctl -u unbound -n50"
echo -n "    经代理解析 www.google.com -> "
timeout 15 dig +short @127.0.0.1 -p "$UNBOUND_PORT" www.google.com | grep -E '^[0-9]' | head -3 | tr '\n' ' '; echo

if [ "$DNS_SPLIT" = yes ]; then
    echo "==> 7/8 生成中国域名表并启动 dnsmasq (127.0.0.1:53)"
    if ! /usr/local/sbin/redsocks-refresh-domains; then
        echo "    下载失败，使用最小回落表(仅 .cn)"
        printf 'server=/.cn/%s\n' "$DIRECT_DNS" > /etc/dnsmasq.d/china-domains.conf
    fi
    dnsmasq --test --conf-dir=/etc/dnsmasq.d || die "dnsmasq 配置有误"
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    systemctl restart dnsmasq
    sleep 1
    systemctl is-active --quiet dnsmasq || die "dnsmasq 启动失败: journalctl -u dnsmasq -n50"
else
    echo "==> 7/8 跳过 DNS 域名分流 (--no-dns-split)"
fi

echo "==> 8/8 系统 DNS -> 127.0.0.1"
cp -a /etc/resolv.conf /etc/resolv.conf.redsocks.bak 2>/dev/null || true
if readlink -f /etc/resolv.conf 2>/dev/null | grep -q 'systemd/resolve'; then
    echo "    检测到 systemd-resolved，关闭其 stub listener"
    install -d /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/redsocks.conf
    systemctl restart systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
elif command -v nmcli >/dev/null 2>&1 && [ "$(nmcli -t -f RUNNING general status 2>/dev/null)" = running ]; then
    CON=$(nmcli -t -f NAME,DEVICE,TYPE,STATE connection show 2>/dev/null | awk -F: '$4=="activated" && $3!="loopback"{print $1; exit}')
    DEV=$(nmcli -t -f NAME,DEVICE,TYPE,STATE connection show 2>/dev/null | awk -F: '$4=="activated" && $3!="loopback"{print $2; exit}')
    if [ -n "${CON:-}" ]; then
        nmcli con mod "$CON" ipv4.dns 127.0.0.1 ipv4.ignore-auto-dns yes >/dev/null
        nmcli device reapply "$DEV" >/dev/null 2>&1 || nmcli con up "$CON" >/dev/null 2>&1 || true
    fi
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
else
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
fi

echo "==> 自检"
for url in https://www.google.com https://github.com https://www.baidu.com; do
    code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "$url" || echo 000)
    printf '    %-28s %s\n' "$url" "$code"
done

cat <<EOF

安装完成。
  代理        : $PROXY_TYPE://$PROXY_IP:$PROXY_PORT
  DNS 分流    : $DNS_SPLIT
  查看规则    : sudo redsocks-nft show
  更新 IP 段表: sudo redsocks-refresh
  更新域名表  : sudo redsocks-refresh-domains
  日志        : sudo tail -f /var/log/redsocks.log
  卸载        : sudo bash $ROOT/scripts/uninstall.sh
EOF
