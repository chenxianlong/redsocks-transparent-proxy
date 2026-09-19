# redsocks-transparent-proxy

在**中国大陆的 Linux 服务器**上做透明分流：

- 访问**国外**（非中国 IP）的 TCP 流量 → 经 SOCKS5/HTTP 代理出去
- **中国 IP** 直连（国内的网站/服务速度快）
- **DNS 按域名分流**：国内域名走国内 DNS 直连，国外域名经代理用 TCP 解析，**规避 DNS 污染**

基于 `redsocks` + `nftables` + `dnsmasq` + `unbound`，纯内核转发，无需改应用配置。

## 架构

```
应用
 ├─ DNS → 127.0.0.1:53 (dnsmasq)
 │         ├─ 中国域名(11万条表 + .cn) ──→ 223.5.5.5  (UDP 直连)
 │         └─ 其它域名 ──→ 127.0.0.1:5353 (unbound)
 │                              └─ 上游 TCP 8.8.8.8/1.1.1.1:53
 └─ TCP
       ▼
   nftables (nat/OUTPUT, table ip redsocks)
     ├─ 私有/保留地址、代理服务器、直连白名单、中国 IP 段 → RETURN 直连
     └─ 其它 TCP → REDIRECT 127.0.0.1:12345 → redsocks → SOCKS5/HTTP 代理
```

> unbound 的上游 TCP 同样会被最后一条规则代理出去，所以 DNS 不会被污染。

## 环境要求

- Debian 12/13 或 Ubuntu 22.04+（systemd + nftables + python3 + curl）
- root 权限
- 一个可用的 SOCKS5 / HTTP 代理，先自测：
  `curl -x socks5h://HOST:PORT -sI https://www.google.com`

## 安装

```bash
sudo bash scripts/install.sh --proxy HOST:PORT
```

常用参数：

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--proxy HOST:PORT` | 代理地址（必填） | - |
| `--type` | `socks5` / `socks4` / `http-connect` / `http-relay` | `socks5` |
| `--user` / `--pass` | 代理认证 | 无 |
| `--direct-dns` | 国内 DNS | `223.5.5.5` |
| `--remote-dns` / `--remote-dns2` | 国外 DNS（经代理 TCP 查询） | `8.8.8.8` / `1.1.1.1` |
| `--no-dns-split` | 所有 DNS 都走代理 | 关闭 |
| `--port` | redsocks 本地端口 | `12345` |

示例：

```bash
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --type socks5 --yes
```

## 验证

```bash
curl -s -o /dev/null -w 'google: %{http_code}\n'  https://www.google.com   # 200
curl -s -o /dev/null -w 'baidu : %{http_code} %{time_total}\n' https://www.baidu.com

dig +short @127.0.0.1 www.baidu.com      # 国内解析（与 @223.5.5.5 一致）
dig +short @223.5.5.5 www.google.com     # 被污染（假 IP）
dig +short @127.0.0.1 www.google.com     # 真实 IP

sudo redsocks-nft show
```

## 维护

```bash
sudo redsocks-refresh            # 更新中国 IP 段表 + 中国域名表
sudo redsocks-refresh-domains    # 只更新中国域名表
sudoedit /etc/redsocks/direct_dst.txt   # 直连白名单，改完 systemctl restart redsocks-nft
```

`direct_dst.txt` 用于把某些 IP/CIDR 排除出代理，例如某个国外 API 直连更稳定。

## 卸载

```bash
sudo bash scripts/uninstall.sh           # 保留软件包
sudo bash scripts/uninstall.sh --purge   # 连同 redsocks/unbound/dnsmasq 一起卸载
```

## 作为 Agent Skill 使用

本仓库同时是一个 [Agent Skills](https://agentskills.io/specification) 技能包，
入口是 [`SKILL.md`](SKILL.md)。可放到：

```bash
git clone <repo> ~/.agents/skills/redsocks-transparent-proxy
# 或 ~/.pi/agent/skills/ 、 ~/.claude/skills/
```

## 重要注意事项 / 踩坑

1. **不要用 redsocks 的 `redudp` 配 clash/mihomo 类代理做 DNS**：这类代理的
   SOCKS5 UDP 回复来自**随机源端口**，而 `redudp` 用 `connect()` 过的 UDP
   socket，会丢弃源端口不符的包。现象是 `Client timeout ... last_relay: 0`。
   本方案改用 **DNS over TCP** 绕开该问题。
2. **本地 DNS 对墙外域名是被污染的**，DNS 必须走代理。
3. **单独 `systemctl stop redsocks-nft` 会连带 DNS 一起挂**（unbound 上游依赖它）。
   要停就整套停，或把 `/etc/resolv.conf` 改回 `223.5.5.5`。
4. **ICMP 不会被代理**，`ping` 墙外地址仍然不通，redsocks 只处理 TCP。
5. 检测 SOCKS5 UDP relay 时注意回复源端口可能不同，要用**未 connect** 的 socket 看。

## 数据来源

- 中国 IP：APNIC `delegated-apnic-latest`
- 非中国 IP：APNIC / ARIN / RIPE NCC / LACNIC / AFRINIC `delegated-*-latest`
- 中国域名：[felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list)

## 许可证

MIT（见 [LICENSE](LICENSE)）
