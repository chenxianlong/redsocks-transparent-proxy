#!/bin/bash
# 生成 / 加载 redsocks 透明代理的 nftables 规则
# 用法: redsocks-nft {start|stop|restart|show}
#
# 两种模式（/etc/redsocks-setup.conf 里的 MODE）:
#   bypass    : 默认。中国 IP 直连，其余 TCP 走代理（推荐）
#   allowlist : 只有 not_cn.txt 里的 IP 走代理，其余直连
#
# GATEWAY=yes 时额外生成 nat/prerouting 链，为局域网其它机器转发
set -euo pipefail

# shellcheck source=/dev/null
[ -r /etc/redsocks-setup.conf ] && . /etc/redsocks-setup.conf

NFT=${NFT:-/usr/sbin/nft}
TABLE=redsocks
MODE=${MODE:-bypass}
GATEWAY=${GATEWAY:-no}
CN_FILE=${CN_FILE:-/etc/redsocks/chnroute.txt}
NOT_CN_FILE=${NOT_CN_FILE:-/etc/redsocks/not_cn.txt}
DIRECT_FILE=${DIRECT_FILE:-/etc/redsocks/direct_dst.txt}
GEN_FILE=${GEN_FILE:-/run/redsocks-redirect.nft}

PROXY_IP=${PROXY_IP:?PROXY_IP 未设置}
TCP_REDIRECT_PORT=${TCP_REDIRECT_PORT:-12345}

# 私有 / 保留 / 组播地址，直连不走代理
LOCAL_NETS='0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4'

gen_ruleset() {
    local list_file
    if [ "$MODE" = allowlist ]; then
        list_file=$NOT_CN_FILE
        [ -r "$list_file" ] || { echo "allowlist 模式需要 $list_file (可运行 redsocks-refresh 生成)" >&2; exit 1; }
    else
        list_file=$CN_FILE
        [ -r "$list_file" ] || { echo "bypass 模式需要 $list_file (可运行 redsocks-refresh 生成)" >&2; exit 1; }
    fi
    mkdir -p "$(dirname "$GEN_FILE")"
    python3 - "$list_file" "$DIRECT_FILE" "$GEN_FILE" "$PROXY_IP" "$TCP_REDIRECT_PORT" "$LOCAL_NETS" "$MODE" "$GATEWAY" <<'PY'
import os, sys

(list_file, direct_file, out_file, proxy_ip, tcp_port,
 local_nets, mode, gateway) = sys.argv[1:9]

def load(path):
    if not path or not os.path.exists(path):
        return []
    return [l.strip() for l in open(path) if l.strip() and not l.startswith('#')]

ips = load(list_file)
direct = load(direct_file)
setname = "not_cn" if mode == "allowlist" else "chnroute"


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


def chain(name, hook, with_local_check):
    lines = [f"    chain {name} {{",
             f"        type nat hook {hook} priority -100; policy accept;",
             ""]
    if with_local_check:
        # 目标是本机自己的包不做 DNAT（局域网访问网关自身）
        lines.append("        fib daddr type local return")
    lines.append(f"        ip daddr {{ {local_nets} }} return")
    lines.append(f"        ip daddr {proxy_ip} return")
    if direct:
        lines.append("        ip daddr @direct_dst return")
    if mode == "allowlist":
        lines.append(f"        ip daddr @{setname} meta l4proto tcp redirect to :{tcp_port}")
    else:
        lines.append(f"        ip daddr @{setname} return")
        lines.append(f"        meta l4proto tcp redirect to :{tcp_port}")
    lines.append("    }")
    return "\n".join(lines) + "\n"


ruleset = "table ip redsocks {\n"
ruleset += set_block(setname, ips)
ruleset += set_block("direct_dst", direct)
ruleset += "\n"
ruleset += chain("output", "output", with_local_check=False)
if gateway == "yes":
    ruleset += "\n"
    ruleset += chain("prerouting", "prerouting", with_local_check=True)
ruleset += "}\n"

open(out_file, "w").write(ruleset)
print(f"[redsocks-nft] 生成规则: {out_file} "
      f"(模式 {mode}, {setname} {len(ips)} 条, 直连白名单 {len(direct)} 条, 网关 {gateway})")
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
