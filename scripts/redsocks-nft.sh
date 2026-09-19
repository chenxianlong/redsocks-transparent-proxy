#!/bin/bash
# 生成 / 加载 redsocks 透明代理的 nftables 规则
# 用法: redsocks-nft {start|stop|restart|show}
#
# nat/OUTPUT 链:
#   私有/保留、代理服务器、直连白名单、中国 IP  -> RETURN 直连
#   其余 TCP -> REDIRECT 到 redsocks 本地端口 -> SOCKS/HTTP 代理
set -euo pipefail

# shellcheck source=/dev/null
[ -r /etc/redsocks-setup.conf ] && . /etc/redsocks-setup.conf

NFT=${NFT:-/usr/sbin/nft}
TABLE=redsocks
CN_FILE=${CN_FILE:-/etc/redsocks/chnroute.txt}
DIRECT_FILE=${DIRECT_FILE:-/etc/redsocks/direct_dst.txt}
GEN_FILE=${GEN_FILE:-/run/redsocks-redirect.nft}

PROXY_IP=${PROXY_IP:?PROXY_IP 未设置}
TCP_REDIRECT_PORT=${TCP_REDIRECT_PORT:-12345}

# 私有 / 保留 / 组播地址，直连不走代理
LOCAL_NETS='0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4'

gen_ruleset() {
    [ -r "$CN_FILE" ] || { echo "缺少中国 IP 段表: $CN_FILE (可运行 redsocks-refresh 生成)" >&2; exit 1; }
    mkdir -p "$(dirname "$GEN_FILE")"
    python3 - "$CN_FILE" "$DIRECT_FILE" "$GEN_FILE" "$PROXY_IP" "$TCP_REDIRECT_PORT" "$LOCAL_NETS" <<'PY'
import os, sys
cn_file, direct_file, out_file, proxy_ip, tcp_port, local_nets = sys.argv[1:7]

def load(path):
    if not path or not os.path.exists(path):
        return []
    return [l.strip() for l in open(path) if l.strip() and not l.startswith('#')]

cidrs = load(cn_file)
direct = load(direct_file)

def set_block(name, items):
    if not items:
        return ""
    body = ",\n        ".join(items)
    return (f"    set {name} {{\n"
            f"        type ipv4_addr\n"
            f"        flags interval\n"
            f"        auto-merge\n"
            f"        elements = {{\n        {body}\n        }}\n"
            f"    }}\n\n")

ruleset = "table ip redsocks {\n"
ruleset += set_block("chnroute", cidrs)
ruleset += set_block("direct_dst", direct)
ruleset += f"""
    chain output {{
        type nat hook output priority -100; policy accept;

        ip daddr {{ {local_nets} }} return
        ip daddr {proxy_ip} return
"""
if direct:
    ruleset += "        ip daddr @direct_dst return\n"
ruleset += f"""        ip daddr @chnroute return

        meta l4proto tcp redirect to :{tcp_port}
    }}
}}
"""

open(out_file, "w").write(ruleset)
print(f"[redsocks-nft] 生成规则: {out_file} (中国段 {len(cidrs)} 条, 直连白名单 {len(direct)} 条)")
PY
}

start()   { gen_ruleset; "$NFT" -f "$GEN_FILE"; echo "[redsocks-nft] 规则已加载"; }
stop()    { "$NFT" delete table ip "$TABLE" 2>/dev/null || true; rm -f "$GEN_FILE"; echo "[redsocks-nft] 规则已移除"; }
show()    { "$NFT" list table ip "$TABLE"; }

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    show)    show ;;
    *) echo "用法: $0 {start|stop|restart|show}" >&2; exit 1 ;;
esac
