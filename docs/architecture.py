#!/usr/bin/env python3
"""生成架构图 SVG（中文 + 英文）。

用法:
    python3 docs/architecture.py          # 写出 docs/architecture.svg / .en.svg
    rsvg-convert -z 2 -o docs/architecture.png docs/architecture.svg

依赖: 无（只用标准库）。渲染 PNG 需要 rsvg-convert（librsvg2-bin）。
"""
import html
import pathlib

W, H = 1060, 860
FONT = "Noto Sans CJK SC, Noto Sans CJK, DejaVu Sans, sans-serif"

C = {
    "ink": "#1e293b",
    "muted": "#64748b",
    "line": "#94a3b8",
    "app_f": "#f8fafc", "app_s": "#334155",
    "dns_f": "#eff6ff", "dns_s": "#2563eb",
    "tcp_f": "#f5f3ff", "tcp_s": "#7c3aed",
    "prox_f": "#fef2f2", "prox_s": "#dc2626",
    "dir_f": "#f0fdf4", "dir_s": "#16a34a",
}

L = {
    "zh": {
        "title": "redsocks-transparent-proxy 架构",
        "app": "应用",
        "dns_q": "DNS 查询", "tcp_c": "TCP 连接",
        "dnsmasq_t": "dnsmasq   127.0.0.1:53", "dnsmasq_s": "按域名分流",
        "cn_domain": "国内域名", "other_domain": "其它域名",
        "dom_t": "223.5.5.5", "dom_s": "国内 DNS · 直连",
        "unbound_t": "unbound   127.0.0.1:5353", "unbound_s": "上游强制 TCP",
        "remote_t": "8.8.8.8 / 1.1.1.1:53", "remote_s": "经代理解析",
        "via_proxy": "经代理",
        "nft_t": "nftables   nat/OUTPUT", "nft_sub": "table ip redsocks",
        "nft_b1": "私有/保留 · 代理服务器 · direct_dst · 中国 IP   →  直连",
        "nft_b2": "其它 TCP   →   REDIRECT 127.0.0.1:12345",
        "redirect": "重定向",
        "redsocks_t": "redsocks   127.0.0.1:12345",
        "proxy_t": "SOCKS5 / HTTP 代理", "proxy_s": "10.75.0.6:6789",
        "socks5": "SOCKS5", "internet": "Internet",
        "direct": "中国 IP / 白名单  直连",
        "legend": "图例",
        "leg": ["直连（不代理）", "DNS 分流", "TCP 走代理", "代理服务器"],
    },
    "en": {
        "title": "redsocks-transparent-proxy architecture",
        "app": "Application",
        "dns_q": "DNS query", "tcp_c": "TCP connect",
        "dnsmasq_t": "dnsmasq   127.0.0.1:53", "dnsmasq_s": "domain-based split",
        "cn_domain": "China domains", "other_domain": "other domains",
        "dom_t": "223.5.5.5", "dom_s": "domestic DNS · direct",
        "unbound_t": "unbound   127.0.0.1:5353", "unbound_s": "TCP upstream",
        "remote_t": "8.8.8.8 / 1.1.1.1:53", "remote_s": "resolved via proxy",
        "via_proxy": "via proxy",
        "nft_t": "nftables   nat/OUTPUT", "nft_sub": "table ip redsocks",
        "nft_b1": "private · proxy host · direct_dst · China IPs   ->   direct",
        "nft_b2": "other TCP   ->   REDIRECT 127.0.0.1:12345",
        "redirect": "redirect",
        "redsocks_t": "redsocks   127.0.0.1:12345",
        "proxy_t": "SOCKS5 / HTTP proxy", "proxy_s": "10.75.0.6:6789",
        "socks5": "SOCKS5", "internet": "Internet",
        "direct": "China IP / whitelist  ->  direct",
        "legend": "Legend",
        "leg": ["direct (not proxied)", "DNS split", "TCP via proxy", "proxy server"],
    },
}


def esc(s):
    return html.escape(s, quote=True)


def rect(x, y, w, h, fill, stroke, rx=10, sw=1.6, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
            f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def text(x, y, s, size=13, fill=None, anchor="middle", weight="normal"):
    return (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
            f'fill="{fill or C["ink"]}" text-anchor="{anchor}" '
            f'font-weight="{weight}">{esc(s)}</text>')


def path(d, color, marker, dash=None):
    m = f' marker-end="url(#a-{marker})"' if marker else ""
    dn = f' stroke-dasharray="{dash}"' if dash else ""
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="1.8"{dn}{m}/>'


def build(lang):
    t = L[lang]
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'viewBox="0 0 {W} {H}">']
    o.append("<defs>")
    for k, col in [("line", C["line"]), ("dns", C["dns_s"]), ("tcp", C["tcp_s"]),
                   ("prox", C["prox_s"]), ("dir", C["dir_s"])]:
        o.append(f'<marker id="a-{k}" viewBox="0 0 10 10" refX="9" refY="5" '
                 f'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                 f'<path d="M0,0 L10,5 L0,10 z" fill="{col}"/></marker>')
    o.append("</defs>")
    o.append(rect(0, 0, W, H, "#ffffff", "#ffffff", rx=0, sw=0))

    o.append(text(W // 2, 34, t["title"], size=20, weight="bold"))

    # 背景盒
    o.append(rect(390, 50, 240, 56, C["app_f"], C["app_s"]))
    o.append(rect(110, 170, 290, 76, C["dns_f"], C["dns_s"]))
    o.append(rect(50, 330, 190, 76, C["dir_f"], C["dir_s"]))
    o.append(rect(265, 330, 230, 90, C["dns_f"], C["dns_s"]))
    o.append(rect(285, 480, 190, 76, C["dns_f"], C["dns_s"]))
    o.append(rect(610, 170, 380, 140, C["tcp_f"], C["tcp_s"]))
    o.append(rect(690, 360, 220, 80, C["tcp_f"], C["tcp_s"]))
    o.append(rect(670, 590, 260, 80, C["prox_f"], C["prox_s"]))
    o.append(rect(700, 730, 200, 54, C["app_f"], C["app_s"]))

    # 箭头
    o.append(path("M440,106 V138 H255 V168", C["line"], "line"))
    o.append(path("M580,106 V138 H800 V168", C["line"], "line"))
    o.append(path("M200,246 L150,328", C["dir_s"], "dir"))
    o.append(path("M310,246 L365,328", C["dns_s"], "dns"))
    o.append(path("M380,420 V478", C["dns_s"], "dns"))
    o.append(path("M380,556 V630 H668", C["dns_s"], "dns"))
    o.append(path("M800,310 V358", C["tcp_s"], "tcp"))
    o.append(path("M800,440 V588", C["tcp_s"], "tcp"))
    o.append(path("M800,670 V728", C["prox_s"], "prox"))
    o.append(path("M990,210 H1025 V757 H904", C["dir_s"], "dir", dash="6 5"))

    # 盒内文字
    o.append(text(510, 84, t["app"], size=17, weight="bold"))
    o.append(text(255, 200, t["dnsmasq_t"], size=14, weight="bold"))
    o.append(text(255, 224, t["dnsmasq_s"], size=12, fill=C["muted"]))
    o.append(text(145, 361, t["dom_t"], size=15, weight="bold"))
    o.append(text(145, 383, t["dom_s"], size=11, fill=C["muted"]))
    o.append(text(380, 362, t["unbound_t"], size=13, weight="bold"))
    o.append(text(380, 386, t["unbound_s"], size=12, fill=C["muted"]))
    o.append(text(380, 510, t["remote_t"], size=14, weight="bold"))
    o.append(text(380, 532, t["remote_s"], size=11, fill=C["muted"]))
    o.append(text(800, 196, t["nft_t"], size=14, weight="bold"))
    o.append(text(800, 218, t["nft_sub"], size=11, fill=C["muted"]))
    o.append(text(632, 252, t["nft_b1"], size=12, anchor="start"))
    o.append(text(632, 278, t["nft_b2"], size=12, anchor="start"))
    o.append(text(800, 404, t["redsocks_t"], size=14, weight="bold"))
    o.append(text(800, 622, t["proxy_t"], size=15, weight="bold"))
    o.append(text(800, 646, t["proxy_s"], size=12, fill=C["muted"]))
    o.append(text(800, 763, t["internet"], size=15, weight="bold"))

    # 箭头标签
    o.append(text(300, 130, t["dns_q"], size=12, fill=C["muted"], anchor="start"))
    o.append(text(650, 130, t["tcp_c"], size=12, fill=C["muted"], anchor="start"))
    o.append(text(140, 292, t["cn_domain"], size=12, fill=C["dir_s"], anchor="middle"))
    o.append(text(360, 292, t["other_domain"], size=12, fill=C["dns_s"], anchor="middle"))
    o.append(text(470, 622, t["via_proxy"], size=12, fill=C["dns_s"], anchor="start"))
    o.append(text(818, 340, t["redirect"], size=12, fill=C["tcp_s"], anchor="start"))
    o.append(text(818, 516, t["socks5"], size=12, fill=C["tcp_s"], anchor="start"))
    o.append(f'<text x="1035" y="480" font-family="{FONT}" font-size="12" '
             f'fill="{C["dir_s"]}" text-anchor="middle" '
             f'transform="rotate(90 1035 480)">{esc(t["direct"])}</text>')

    # 图例
    o.append(rect(30, 470, 250, 178, "#ffffff", "#e2e8f0"))
    o.append(text(50, 500, t["legend"], size=13, weight="bold", anchor="start"))
    rows = [(C["dir_s"], "6 5"), (C["dns_s"], None), (C["tcp_s"], None), (C["prox_s"], None)]
    for i, ((col, dash), lab) in enumerate(zip(rows, t["leg"])):
        y = 530 + i * 28
        da = f' stroke-dasharray="{dash}"' if dash else ""
        o.append(f'<path d="M50,{y} H88" stroke="{col}" stroke-width="2"{da}/>')
        o.append(text(98, y + 5, lab, size=12, anchor="start"))

    o.append("</svg>\n")
    return "\n".join(o)


def main():
    out = pathlib.Path(__file__).resolve().parent
    (out / "architecture.svg").write_text(build("zh"), encoding="utf-8")
    (out / "architecture.en.svg").write_text(build("en"), encoding="utf-8")
    print("wrote", out / "architecture.svg", "and", out / "architecture.en.svg")


if __name__ == "__main__":
    main()
