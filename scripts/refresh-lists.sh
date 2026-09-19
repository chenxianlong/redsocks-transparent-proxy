#!/bin/bash
# 重新下载各 RIR 的 IP 分配数据，并重新生成 chnroute.txt / not_cn.txt
# 同时（可选）更新中国域名表并重载 nft 规则
# 用法: sudo redsocks-refresh
set -euo pipefail

OUT_DIR=${OUT_DIR:-/etc/redsocks}
GEN=${GEN:-/usr/local/lib/redsocks-transparent-proxy/gen_lists.py}

# shellcheck source=/dev/null
[ -r /etc/redsocks-setup.conf ] && . /etc/redsocks-setup.conf

# 下载优先直连，失败后回退到本机代理
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

declare -A URLS=(
    [apnic]="https://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest"
    [arin]="https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest"
    [ripencc]="https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest"
    [lacnic]="https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-extended-latest"
    [afrinic]="https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-extended-latest"
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for k in "${!URLS[@]}"; do
    echo ">>> 下载 $k ..."
    if ! timeout 180 curl -sfL "${URLS[$k]}" -o "$TMP/$k.txt"; then
        [ -n "$FALLBACK_PROXY" ] || { echo "    $k 直连下载失败（可设置 FALLBACK_PROXY）" >&2; exit 1; }
        echo "    直连失败，改走代理 ..."
        timeout 180 curl -sfL -x "$FALLBACK_PROXY" "${URLS[$k]}" -o "$TMP/$k.txt" \
            || { echo "    $k 下载失败" >&2; exit 1; }
    fi
done

python3 "$GEN" "$TMP" "$OUT_DIR"

if systemctl is-active --quiet redsocks-nft 2>/dev/null; then
    echo ">>> 重新加载 nftables 规则 ..."
    systemctl restart redsocks-nft
fi

if [ -x /usr/local/sbin/redsocks-refresh-domains ]; then
    echo ">>> 同步更新中国域名表 ..."
    /usr/local/sbin/redsocks-refresh-domains || true
fi
echo ">>> IP 段表已更新: $OUT_DIR"
