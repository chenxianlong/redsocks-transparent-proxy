# redsocks-transparent-proxy

Transparent split routing for a **Linux server in mainland China**:

- **Overseas** (non-China) TCP traffic goes through a SOCKS5/HTTP proxy
- **China** traffic stays direct (fast, uses domestic CDN)
- **DNS is split by domain**: China domains resolve via a domestic DNS directly,
  everything else is resolved through the proxy over **TCP**, defeating DNS poisoning

Built on `redsocks` + `nftables` + `dnsmasq` + `unbound`. No application config changes.

📖 **Online docs: <https://chenxianlong.github.io/redsocks-transparent-proxy/>**

## How it works

![architecture](docs/architecture.en.png)

> Source: [`docs/architecture.svg`](docs/architecture.svg) (中文) / [`docs/architecture.en.svg`](docs/architecture.en.svg);
> regenerate with `python3 docs/architecture.py`, then
> `rsvg-convert -z 2 -o docs/architecture.en.png docs/architecture.en.svg`.

```
app
 ├─ DNS → 127.0.0.1:53 (dnsmasq)
 │         ├─ China domains (110k list + .cn) ──→ 223.5.5.5  (UDP, direct)
 │         └─ everything else ──→ 127.0.0.1:5353 (unbound)
 │                                      └─ upstream TCP 8.8.8.8/1.1.1.1:53 (proxied)
 └─ TCP
       ▼
   nftables (nat/OUTPUT, table ip redsocks)
     ├─ private/reserved, proxy host, direct whitelist, China IPs → RETURN (direct)
     └─ other TCP → REDIRECT 127.0.0.1:12345 → redsocks → SOCKS5/HTTP proxy
```

> unbound's TCP upstream also matches the last rule, so it is proxied and cannot be poisoned.

## Requirements

- **OS** (auto-detected):

  | Distro | redsocks source | Notes |
  | --- | --- | --- |
  | Debian 12/13, Ubuntu 22.04+ | `redsocks` package | original target |
  | RHEL / CentOS / Rocky / Alma / Fedora | **built from source** | CRLF fix patch applied automatically |

- `systemd` + `nftables` + `python3` + `curl`
- root
- a working SOCKS5 / HTTP proxy. Test it first:
  `curl -x socks5h://HOST:PORT -sI https://www.google.com`

> On RHEL-family hosts the installer uses `dnf` to pull build deps
> (`gcc make libevent-devel patch`) and, when SELinux is `Enforcing`, labels the
> non-53 unbound port with `dns_port_t`. See [`docs/platform-support.md`](docs/platform-support.md).

## Install

Clone:

```bash
git clone https://github.com/chenxianlong/redsocks-transparent-proxy
sudo bash redsocks-transparent-proxy/scripts/install.sh --proxy HOST:PORT
```

One-liner (no clone):

```bash
curl -fsSL https://raw.githubusercontent.com/chenxianlong/redsocks-transparent-proxy/main/install.sh \
  | sudo bash -s -- --proxy HOST:PORT
```

> If `raw.githubusercontent.com` is blocked on your network, clone the repo through
> a proxy or a mirror first, then run `scripts/install.sh`.
>
> On RHEL / CentOS / Rocky / Alma nothing else is needed: the script installs deps
> with `dnf`, builds redsocks from source, writes a systemd unit and handles SELinux.

### Options

| Option | Description | Default |
| --- | --- | --- |
| `--proxy HOST:PORT` | proxy address (required) | - |
| `--type` | `socks5` \| `socks4` \| `http-connect` \| `http-relay` | `socks5` |
| `--user` / `--pass` | proxy credentials | none |
| `--direct-dns` | domestic DNS | `223.5.5.5` |
| `--remote-dns` / `--remote-dns2` | foreign DNS, queried over TCP via the proxy | `8.8.8.8` / `1.1.1.1` |
| `--no-dns-split` | route *all* DNS through the proxy | off |
| `--allowlist` | only proxy IPs in `not_cn.txt` (default is China-bypass) | off |
| `--gateway` | also forward for the LAN (`ip_forward` + `nat/prerouting`) | off |
| `--port` | redsocks local port | `12345` |
| `--splice` | `on` / `off`, redsocks data pump | Debian=`on`, RHEL-family=`off` |

```bash
# typical
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --yes

# with auth
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --user me --pass secret

# also act as a gateway for the LAN
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --gateway
```

## Verify

```bash
curl -s -o /dev/null -w 'google: %{http_code}\n' https://www.google.com   # 200
curl -s -o /dev/null -w 'baidu : %{http_code} %{time_total}\n' https://www.baidu.com

dig +short @127.0.0.1 www.baidu.com      # domestic answer
dig +short @223.5.5.5 www.google.com     # poisoned / fake IP
dig +short @127.0.0.1 www.google.com     # real IP

sudo redsocks-nft show
```

## Gateway mode (experimental)

With `--gateway`:

- `net.ipv4.ip_forward=1` (persisted in `/etc/sysctl.d/99-redsocks-transparent-proxy.conf`)
- an extra `nat/prerouting` chain redirects forwarded non-China TCP to redsocks
- `redsocks` binds `0.0.0.0`; `dnsmasq`/`unbound` also listen on the LAN IP
- on the other machines, set **default gateway** and **DNS** to this server's LAN IP
- make sure your firewall/security group allows `FORWARD`

## Performance

Bottom line: **China traffic is essentially free; the cost is almost entirely in
"overseas traffic relayed by redsocks"**, and it is negligible for a normal server
(< 1 Gbps, a few hundred concurrent connections).

### Measured (Debian 13 / x86_64)

| Scenario | Throughput | Connect | redsocks CPU |
| --- | --- | --- | --- |
| China direct (USTC mirror) | 25.2 MB/s (≈202 Mbps) | 31 ms | **0.0 ms** (not involved) |
| Overseas via proxy (Cloudflare 50 MB) | 25.0 MB/s (≈200 Mbps) | 174 ms | **90 ms / 2.0 s = 4.5% of one core** |

That is roughly **225 ms CPU per Gbit** — a single core can do about **2–4 Gbps**
(non-linear at high rates; order-of-magnitude only).

DNS (`dig` Query time):

| Domain | First | Cached |
| --- | --- | --- |
| www.taobao.com / www.163.com (China) | 8 / 4 ms | **0 ms** |
| www.google.com (overseas) | 52 ms | 4 ms |
| www.wikipedia.org / www.reddit.com (overseas) | **408 / 224 ms** | **0 ms** |

redsocks RSS ~1.5 MB, 0% CPU when idle.

### Where there is (almost) no overhead

- **China traffic**: only one extra in-kernel nftables set lookup. `chnroute` is a
  `flags interval` set (rbtree), 5513 entries ≈ 13 comparisons/packet, nanoseconds,
  no userspace cost — measured **0.0 ms** redsocks CPU at line rate.
- **110,573 China domain rules**: dnsmasq matches by a domain suffix tree, largely
  independent of rule count; tens of MB RAM, single-digit ms lookups.
- **Direct whitelist / private ranges**: kernel prefix matching too.

### Where the cost is

1. **First overseas DNS: 200–400 ms** — `dnsmasq → unbound → TCP → redsocks → proxy
   → 8.8.8.8` chains several RTTs. This is the price of anti-poisoning; **0 ms once
   cached**, so it only affects cold starts / new domains.
2. **Overseas TCP: redsocks userspace relay** — each connection is REDIRECTed to
   `127.0.0.1:12345`, accepted by redsocks, which opens SOCKS5 to the proxy and
   forwards both ways. redsocks 0.5 uses **`splice()`** on Linux
   (`redsplice_write_cb` in the log), keeping data in kernel pipes, so it is much
   cheaper than a read/write relay. Still, it is **single-threaded epoll**, so a
   single core caps throughput at very high (> 1 Gbps) rates. One extra hop
   (host → proxy) is added; with the proxy on the LAN this is < 1 ms.
3. **Concurrency (the default is a trap)** — `redsocks_conn_max` defaults to
   `0.75 × nofile / 6` (splice); systemd's `LimitNOFILESoft=1024` means **only 128
   concurrent connections** by default, beyond which connections are dropped. The
   installer now writes `rlimit_nofile = 65536` + `redsocks_conn_max = 8192`
   (tune with `--conn-max`).

### When to choose something else

| Need | Recommendation |
| --- | --- |
| Local browsing / API / normal downloads (< 1 Gbps) | This project is enough; overhead is negligible |
| Heavy downloads, > 1 Gbps | redsocks may be single-core bound; consider a multi-threaded transparent proxy (e.g. `sing-box` tproxy) or a kernel-space setup |
| LAN gateway (tens–hundreds of clients) | This project + `--gateway`, with a generous `--conn-max` |
| Maximum performance, per-app config is fine | Point apps at SOCKS5 directly; skip kernel redirect + redsocks relay |

Full version and reproduction script: [docs/performance.md](docs/performance.md).

## Maintenance

```bash
sudo redsocks-refresh            # refresh China IP list + China domain list
sudo redsocks-refresh-domains    # refresh China domain list only
sudoedit /etc/redsocks/direct_dst.txt && sudo systemctl restart redsocks-nft
```

## Uninstall

```bash
sudo bash scripts/uninstall.sh           # keep packages
sudo bash scripts/uninstall.sh --purge   # also remove redsocks/unbound/dnsmasq
```

## Use as an Agent Skill

This repo is also an [Agent Skills](https://agentskills.io/specification) package
(entry point [`SKILL.md`](SKILL.md)). Install it with:

```bash
git clone https://github.com/chenxianlong/redsocks-transparent-proxy ~/.agents/skills/redsocks-transparent-proxy
# or ~/.pi/agent/skills/ , ~/.claude/skills/
```

## Important pitfalls

1. **Do not use redsocks `redudp` with a clash/mihomo-style proxy.** Such proxies
   answer SOCKS5 UDP from a *random source port*; `redudp` uses a `connect()`ed UDP
   socket and drops those replies (`Client timeout ... last_relay: 0`). This project
   uses DNS-over-TCP instead.
2. **Local DNS is poisoned** for blocked domains — DNS must go through the proxy.
3. **Stopping `redsocks-nft` also breaks DNS** (unbound's upstream depends on the
   redirect). Stop everything, or restore `/etc/resolv.conf`.
4. **ICMP is not proxied**; `ping` to foreign hosts still fails.

See [references/troubleshooting.md](references/troubleshooting.md).

## Related articles

- [Migrating a Debian-only transparent-proxy setup to Rocky Linux 10](docs/blog-rhel-transparent-proxy.md) *(Chinese)*
  — full write-up of the RHEL-family port, including the libevent trap where the
  proxy returns `200 Connection established` but the tunnel hangs forever.
- [Platform support](docs/platform-support.md) — platform matrix and manual steps.

## Data sources

- China IPv4: APNIC `delegated-apnic-latest`
- All regions: ARIN / RIPE NCC / LACNIC / AFRINIC `delegated-*-latest`
- China domains: [felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list)

## License

MIT — see [LICENSE](LICENSE).
