---
name: redsocks-transparent-proxy
description: Set up transparent split routing on a Linux server (mainland China) so that non-China TCP traffic is forwarded through a SOCKS5/HTTP proxy while China traffic stays direct, with domain-split DNS (dnsmasq + unbound over TCP) to defeat DNS poisoning. Use when asked to route a server's foreign traffic through a proxy, transparently bypass the GFW, keep domestic traffic fast, or configure redsocks/nftables for split tunneling.
license: MIT
compatibility: Debian 12/13 or Ubuntu 22.04+, systemd, nftables, root access, outbound internet.
metadata:
  author: chenxianlong
  repository: https://github.com/chenxianlong/redsocks-transparent-proxy
---

# redsocks Transparent Proxy (China / overseas split routing)

Routes a Linux server's traffic as follows:

- **DNS** via `dnsmasq` (127.0.0.1:53), split by domain name:
  - China domains -> domestic DNS (default `223.5.5.5`), resolved directly.
  - Everything else -> `unbound` (127.0.0.1:5353) with **TCP upstream** that is
    itself proxied, so blocked domains get real answers.
- **TCP** via `nftables` (nat/OUTPUT) + `redsocks`:
  - private/reserved ranges, the proxy host, a direct whitelist, and China IPs
    (`chnroute`) -> direct.
  - every other TCP connection -> `redsocks` -> SOCKS5/HTTP proxy.

## Prerequisites

- Debian/Ubuntu with `systemd`, `nftables` (`/usr/sbin/nft`), `python3`, `curl`.
- Root access.
- A working SOCKS5 (or HTTP CONNECT) proxy. Verify first:
  `curl -x socks5h://HOST:PORT -sI https://www.google.com`

## Install

```bash
# from a clone
sudo bash scripts/install.sh --proxy HOST:PORT

# or one-liner (no clone)
curl -fsSL https://raw.githubusercontent.com/chenxianlong/redsocks-transparent-proxy/main/install.sh \
  | sudo bash -s -- --proxy HOST:PORT
```

Common options:

| Option | Meaning | Default |
| --- | --- | --- |
| `--proxy HOST:PORT` | proxy address (required) | - |
| `--type` | `socks5` \| `socks4` \| `http-connect` \| `http-relay` | `socks5` |
| `--user` / `--pass` | proxy credentials | none |
| `--direct-dns` | domestic DNS | `223.5.5.5` |
| `--remote-dns` / `--remote-dns2` | foreign DNS (queried over TCP via proxy) | `8.8.8.8` / `1.1.1.1` |
| `--no-dns-split` | route *all* DNS through the proxy | off |
| `--allowlist` | only proxy IPs in `not_cn.txt` (default is China-bypass) | off |
| `--gateway` | also forward for the LAN (`ip_forward` + `nat/prerouting`) | off |
| `--port` | redsocks local port | `12345` |

Example:

```bash
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --type socks5 --yes
```

Routing modes:

- **bypass** (default): China IPs (`chnroute.txt`) are excluded; everything else is
  proxied. Recommended.
- **allowlist** (`--allowlist`): only IPs in `not_cn.txt` are proxied.

Gateway mode (`--gateway`, experimental): enables `ip_forward`, adds a
`nat/prerouting` chain and makes redsocks/`dnsmasq`/`unbound` listen on the LAN
IP so other machines can use this host as gateway + DNS.

## Verify

```bash
# foreign site through the proxy
curl -s -o /dev/null -w '%{http_code}\n' https://www.google.com      # 200

# domestic site direct + fast
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' https://www.baidu.com

# DNS is split: baidu == domestic answer, google == real (not poisoned)
dig +short @127.0.0.1 www.baidu.com
dig +short @223.5.5.5 www.google.com   # polluted -> a fake IP
dig +short @127.0.0.1 www.google.com   # real 142.251.x

sudo redsocks-nft show                 # inspect nft rules
```

## Maintenance

```bash
sudo redsocks-refresh            # refresh China IP list + China domain list
sudo redsocks-refresh-domains    # refresh China domain list only
# add a direct-bypass target (e.g. an API that is more stable direct):
sudoedit /etc/redsocks/direct_dst.txt && sudo systemctl restart redsocks-nft
```

## Uninstall

```bash
sudo bash scripts/uninstall.sh          # keep packages
sudo bash scripts/uninstall.sh --purge  # also remove redsocks/unbound/dnsmasq
```

## Critical pitfalls (do not repeat these)

1. **Do not use redsocks `redudp` for DNS with a clash/mihomo-style proxy.**
   Such proxies answer SOCKS5 UDP from a *random source port*, while `redudp`
   uses a `connect()`ed UDP socket and drops replies from any other port.
   Symptom: `Client timeout ... last_relay: 0`, no DNS at all.
   Use DNS-over-TCP (this skill) instead.
2. **Local DNS is poisoned** for blocked domains (e.g. `223.5.5.5` returns a
   Facebook IP for `www.google.com`). DNS must go through the proxy.
3. **Stopping `redsocks-nft` also breaks DNS**, because unbound's TCP upstream
   needs the redirect. Stop the whole thing or restore `/etc/resolv.conf`.
4. **ICMP is not proxied** (`ping` to foreign hosts still fails); redsocks only
   handles TCP.
5. When testing a UDP relay, remember replies may come from a different source
   port; use an *unconnected* socket to observe them.

See [references/troubleshooting.md](references/troubleshooting.md) for details.
