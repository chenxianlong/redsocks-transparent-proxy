#!/bin/bash
# 下载并生成 dnsmasq 的中国域名分流表 -> /etc/dnsmasq.d/china-domains.conf
# 用法: sudo redsocks-refresh-domains
set -euo pipefail

# shellcheck source=/dev/null
[ -r /etc/redsocks-setup.conf ] && . /etc/redsocks-setup.conf

OUT=${OUT:-/etc/dnsmasq.d/china-domains.conf}
DIRECT_DNS=${DIRECT_DNS:-223.5.5.5}

if [ -z "${FALLBACK_PROXY:-}" ] && [ -n "${PROXY_IP:-}" ]; then
    case "${PROXY_TYPE:-socks5}" in
        socks5) _s=socks5h ;;
        socks4) _s=socks4a ;;
        *)      _s=http ;;
    esac
    if [ -n "${PROXY_USER:-}" ]; then
        FALLBACK_PROXY="$_s://$PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT"
    else
        FALLBACK_PROXY="$_s://$PROXY_IP:$PROXY_PORT"
    fi
fi
BASE="https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master"
FILES="accelerated-domains.china.conf apple.china.conf"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for f in $FILES; do
    echo ">>> 下载 $f ..."
    if ! timeout 180 curl -sfL "$BASE/$f" -o "$TMP/$f"; then
        [ -n "$FALLBACK_PROXY" ] || { echo "    $f 直连下载失败（可设置 FALLBACK_PROXY）" >&2; exit 1; }
        echo "    直连失败，改走代理 ..."
        timeout 180 curl -sfL -x "$FALLBACK_PROXY" "$BASE/$f" -o "$TMP/$f" \
            || { echo "    $f 下载失败" >&2; exit 1; }
    fi
done

TMPOUT="$TMP/china-domains.conf"
{
    echo "# 由 dnsmasq-china-list 生成：$(date -Iseconds)"
    echo "# 国内域名统一走 $DIRECT_DNS（直连）"
    cat "$TMP/accelerated-domains.china.conf" "$TMP/apple.china.conf"
} | grep -E '^server=/' | sed "s#114\.114\.114\.114#$DIRECT_DNS#" | sort -u > "$TMPOUT"

n=$(wc -l < "$TMPOUT")
if [ "$n" -lt 1000 ]; then
    echo "生成结果只有 $n 行，异常，放弃覆盖" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
install -m 0644 "$TMPOUT" "$OUT"
echo ">>> 已写入 $OUT ($n 行)"

if systemctl is-active --quiet dnsmasq 2>/dev/null; then
    dnsmasq --test --conf-dir=/etc/dnsmasq.d && systemctl restart dnsmasq && echo ">>> dnsmasq 已重载"
fi
