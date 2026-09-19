#!/usr/bin/env python3
"""从各 RIR 的 delegated 文件生成 IP 段表。

输出:
  chnroute.txt : 中国 IPv4 段（redsocks 反向排除：不在表内的走代理）
  not_cn.txt   : 显式的“非中国” IPv4 段（已剔除私有/保留地址）

用法: gen_lists.py <rir文件目录> <输出目录>
"""
import glob
import ipaddress
import math
import os
import sys

# 私有 / 保留 / 组播地址，不属于"可路由的公网地址"
SPECIAL = [
    ipaddress.ip_network(x) for x in
    "0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 "
    "172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 "
    "198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4".split()
]

KEEP_STATUS = {"allocated", "assigned", "legacy"}


def iter_records(files):
    for path in files:
        for line in open(path, errors="ignore"):
            p = line.rstrip("\n").split("|")
            if len(p) < 7 or p[2] != "ipv4":
                continue
            cc, start, cnt, status = p[1], p[3], p[4], p[6].strip()
            if status not in KEEP_STATUS or cc == "*":
                continue
            try:
                n = int(cnt)
                addr = ipaddress.ip_address(start)
            except ValueError:
                continue
            if n & (n - 1) == 0:
                yield cc, ipaddress.ip_network(
                    f"{start}/{32 - int(math.log2(n))}", strict=False)
            else:
                yield from ((cc, net) for net in ipaddress.summarize_address_range(
                    addr, ipaddress.ip_address(int(addr) + n - 1)))


def subtract(nets, holes):
    out = []
    for net in nets:
        parts = [net]
        for hole in holes:
            nxt = []
            for part in parts:
                if part == hole or part.subnet_of(hole):
                    continue
                if hole.subnet_of(part):
                    nxt.extend(part.address_exclude(hole))
                else:
                    nxt.append(part)
            parts = nxt
        out.extend(parts)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    files = sorted(glob.glob(os.path.join(src, "*.txt")))
    if not files:
        sys.exit(f"目录 {src} 下没有 RIR 文件")

    cn, non_cn = [], []
    for cc, net in iter_records(files):
        (cn if cc == "CN" else non_cn).append(net)

    cn_c = list(ipaddress.collapse_addresses(cn))
    non_cn_c = list(ipaddress.collapse_addresses(non_cn))
    non_cn_f = list(ipaddress.collapse_addresses(subtract(non_cn_c, SPECIAL)))

    os.makedirs(dst, exist_ok=True)
    with open(os.path.join(dst, "chnroute.txt"), "w") as f:
        f.write("\n".join(map(str, cn_c)) + "\n")
    with open(os.path.join(dst, "not_cn.txt"), "w") as f:
        f.write("\n".join(map(str, non_cn_f)) + "\n")

    print(f"chnroute.txt: {len(cn_c)} 条")
    print(f"not_cn.txt  : {len(non_cn_f)} 条")


if __name__ == "__main__":
    main()
