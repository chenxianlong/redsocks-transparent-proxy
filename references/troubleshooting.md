# Troubleshooting & design notes

Notes collected while building and debugging this setup. Useful when something
breaks or when adapting to a different proxy.

## 1. `redudp` never receives DNS replies

**Symptom**

`/var/log/redsocks.log` shows, repeatedly:

```
redudp_first_pkt_from_client(...) [10.0.0.2:48202->8.8.8.8:53]: got 1st packet from client
redudp_flush_queue(...)           [10.0.0.2:48202->8.8.8.8:53]: Starting UDP relay
redudp_timeout(...)               [10.0.0.2:48202->8.8.8.8:53]: Client timeout. ... last_relay: 0.
```

`last_relay: 0` means redudp never got a packet back from the SOCKS5 relay.

**Cause**

Many SOCKS5 servers (clash / mihomo and friends) answer the UDP relay from a
**random source port**, not from the port advertised in the UDP ASSOCIATE reply.
You can confirm it with a raw check (note the reply source **port**):

```python
import socket, struct
P = ("10.0.0.6", 6789)
t = socket.create_connection(P, 5); t.settimeout(6)
t.sendall(b"\x05\x01\x00"); t.recv(2)                       # no-auth
t.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
r = t.recv(10)
relay_port = struct.unpack(">H", r[8:10])[0]                # e.g. 6789
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(6)
q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" \
    b"\x03www\x06google\x03com\x00\x00\x01\x00\x01"
u.sendto(b"\x00\x00\x00\x01" + socket.inet_aton("8.8.8.8") +
         struct.pack(">H", 53) + q, ("10.0.0.6", relay_port))
data, src = u.recvfrom(2048)
print("reply from", src)     # <- may be 10.0.0.6:<random>, not relay_port
```

`redudp` uses a `connect()`ed UDP socket (`redudp.c` `connect(fd, &udprelayaddr)`),
so the kernel discards datagrams whose source address:port differ. There is no
config option to use an unconnected socket.

**Fix**

Use DNS over TCP (`unbound` with `forward-tcp-upstream: yes`). If you really
need UDP DNS, put a user-space forwarder in front that uses an unconnected UDP
socket, or use DoT/DoH.

## 2. Local DNS is poisoned

```
$ dig +short @223.5.5.5 www.google.com
157.240.7.20            # a Facebook IP -> forged

$ dig +short @223.5.5.5 twitter.com
                        # nothing
```

Because `redsocks` forwards the *already-resolved* destination IP (the app
resolved it locally), a poisoned answer means the proxy is asked to reach the
wrong host. DNS must therefore be resolved through the proxy.

## 3. `unbound` upstream must be TCP

`forward-tcp-upstream: yes` (per forward-zone) or `tcp-upstream: yes` (global)
forces TCP. Plain UDP DNS from the server to `8.8.8.8:53` is either polluted or
reset. TCP is redirected by the nft rule into `redsocks` and reaches the proxy.

## 4. `systemctl stop redsocks-nft` kills DNS

Once `/etc/resolv.conf` points at `127.0.0.1` and unbound's upstream goes
through the proxy redirect, removing the nft rules leaves unbound unable to
reach `8.8.8.8` (direct TCP/53 is blocked). To disable everything, restore
`/etc/resolv.conf` first, or run `uninstall.sh`.

## 5. Verifying the split actually works

Compare answers:

```bash
dig +short @127.0.0.1 taobao.com          # dnsmasq front
dig +short @223.5.5.5 taobao.com          # domestic DNS -> identical => split works
dig +short @223.5.5.5 www.google.com      # forged
dig +short @127.0.0.1 www.google.com      # real => foreign path works
```

If `taobao` differs between the two, the China domain list isn't loaded:
check `/etc/dnsmasq.d/china-domains.conf`, `dnsmasq --test --conf-dir=/etc/dnsmasq.d`,
and that `/etc/default/dnsmasq`'s `CONFIG_DIR` includes `/etc/dnsmasq.d` (the
`conf-dir` lines in `/etc/dnsmasq.conf` are commented out on Debian).

## 6. nftables vs iptables

This skill uses native nftables (no `iptables`/`ipset` packages needed).
Mixing `ipset` with `iptables-nft` is fragile because they use different set
stores; native nft sets avoid that entirely.

Test a ruleset without touching the host:

```bash
unshare -rn /usr/sbin/nft -c -f /tmp/ruleset.nft     # syntax check in a netns
```

## 7. Selecting the right bypass strategy

- **China list + default redirect** (used here): any IP *not* in `chnroute` is
  proxied. Missing entries only cost an extra hop; safer.
- Explicit non-China allowlist (`not_cn.txt` is generated too): only listed IPs
  are proxied. A missing foreign IP would leak direct (fail closed the wrong
  way). Prefer the China-bypass approach.

## 8. Data sources

- China IPv4: `https://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest`
- All regions: ARIN / RIPE NCC / LACNIC / AFRINIC `delegated-*-latest`
- China domains: `https://github.com/felixonmars/dnsmasq-china-list`

## 9. RHEL family: no `redsocks` package

On RHEL/CentOS/Rocky/Alma 8/9/10 `redsocks` is not shipped (EPEL dropped it for
EL10). The installer builds release 0.5 from source via
`scripts/redsocks-build.sh`. It needs `gcc make libevent-devel patch` and network
access to fetch the tarball (falls back to the `--proxy` when direct GitHub is
blocked). The built binary lands in `/usr/sbin/redsocks`; the `redsocks`
system user is created automatically.

## 10. RHEL family: `redsocks` `daemon = on` dies under systemd

With `daemon = on`, redsocks `setuid`s to `redsocks` **before** `fork()` and the
child can exit during daemonization, leaving `systemd` stuck in `activating` with
no PID file:

```
redsocks.service: Can't open PID file '/run/redsocks/redsocks.pid' (yet?) after start
```

Fix: run in the foreground (`daemon = off`) with a generated unit:

```ini
[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c /etc/redsocks.conf
```

The installer writes this unit on RHEL-family hosts.

## 11. RHEL family: SELinux blocks unbound on the split-DNS port

`unbound` runs as `named_t`, which may only bind `dns_port_t` (53, 853). With the
split design unbound listens on `5353`, so it fails:

```
error: can't bind socket: Permission denied for 127.0.0.1 port 5353
avc: denied { name_bind } ... scontext=system_u:system_r:named_t:s0
    tcontext=system_u:object_r:unreserved_port_t:s0 tclass=tcp_socket
```

Fix (persistent):

```bash
sudo semanage port -a -t dns_port_t -p tcp 5353
sudo semanage port -a -t dns_port_t -p udp 5353
```

(requires `policycoreutils-python-utils`). The installer does this automatically
when SELinux is `Enforcing`.

## 12. RHEL family: unbound include directory

Debian's `unbound` includes `/etc/unbound/unbound.conf.d/*.conf`; RHEL's includes
`/etc/unbound/conf.d/*.conf`. Writing to the wrong directory silently does
nothing. The installer picks the right one per distro.
