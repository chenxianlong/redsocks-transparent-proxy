# redsocks-transparent-proxy

在**中国大陆的 Linux 服务器**上做透明分流：

- 访问**国外**（非中国 IP）的 TCP 流量 → 经 SOCKS5/HTTP 代理出去
- **中国 IP** 直连（国内网站/服务速度快、走国内 CDN）
- **DNS 按域名分流**：国内域名走国内 DNS 直连，国外域名经代理用 **TCP** 解析，**规避 DNS 污染**

基于 `redsocks` + `nftables` + `dnsmasq` + `unbound`，纯内核转发，无需改应用配置。

English: [README.en.md](README.en.md) · 变更记录: [CHANGELOG.md](CHANGELOG.md)

## 架构

![架构图](docs/architecture.png)

> 源文件：[`docs/architecture.svg`](docs/architecture.svg)（中文）/ [`docs/architecture.en.svg`](docs/architecture.en.svg)（English）；
> 用 `python3 docs/architecture.py` 重新生成，PNG 用 `rsvg-convert -z 2 -o docs/architecture.png docs/architecture.svg` 渲染。

```
应用
 ├─ DNS → 127.0.0.1:53 (dnsmasq)
 │         ├─ 中国域名(11万条表 + .cn) ──→ 223.5.5.5  (UDP 直连)
 │         └─ 其它域名 ──→ 127.0.0.1:5353 (unbound)
 │                              └─ 上游 TCP 8.8.8.8/1.1.1.1:53（经代理）
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

方式一，克隆后安装：

```bash
git clone https://github.com/chenxianlong/redsocks-transparent-proxy
sudo bash redsocks-transparent-proxy/scripts/install.sh --proxy HOST:PORT
```

方式二，一行安装（无需克隆）：

```bash
curl -fsSL https://raw.githubusercontent.com/chenxianlong/redsocks-transparent-proxy/main/install.sh \
  | sudo bash -s -- --proxy HOST:PORT
```

> 若 `raw.githubusercontent.com` 被墙，请先通过代理或镜像 clone 仓库，再执行
> `sudo bash scripts/install.sh --proxy HOST:PORT`。

### 参数

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--proxy HOST:PORT` | 代理地址（必填） | - |
| `--type` | `socks5` / `socks4` / `http-connect` / `http-relay` | `socks5` |
| `--user` / `--pass` | 代理认证 | 无 |
| `--direct-dns` | 国内 DNS | `223.5.5.5` |
| `--remote-dns` / `--remote-dns2` | 国外 DNS（经代理 TCP 查询） | `8.8.8.8` / `1.1.1.1` |
| `--no-dns-split` | 所有 DNS 都走代理 | 关闭 |
| `--allowlist` | 只代理 `not_cn.txt` 里的 IP（默认是「中国 IP 直连」的 bypass 模式） | 关闭 |
| `--gateway` | 同时为局域网其它机器转发（`ip_forward` + `nat/prerouting`） | 关闭 |
| `--port` | redsocks 本地端口 | `12345` |

```bash
# 最常见
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --yes

# 带认证
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --user me --pass secret

# 同时做局域网网关
sudo bash scripts/install.sh --proxy 10.0.0.1:1080 --gateway
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

## 两种分流模式

- **bypass（默认，推荐）**：把中国 IP 段表 `chnroute.txt` 作为排除集。不在表内的
  （即国外 IP）一律走代理。漏掉的国内 IP 最多多走一次代理，不会导致国外站点直连失败。
- **allowlist**：只把 `not_cn.txt` 里列出的（已分配的）国外 IP 走代理。
  适合你想严格控制「哪些目标走代理」的场景。

```bash
sudo bash scripts/install.sh --proxy HOST:PORT --allowlist
```

## 网关模式（实验性）

加 `--gateway` 后：

- `net.ipv4.ip_forward=1`（持久化到 `/etc/sysctl.d/99-redsocks-transparent-proxy.conf`）
- 额外生成 `nat/prerouting` 链，把其它机器转发进来的「非中国 TCP」重定向到 redsocks
- `redsocks` 监听 `0.0.0.0`；`dnsmasq`/`unbound` 额外监听本机 LAN IP
- 其它机器把**默认网关**和 **DNS** 都指向本机 LAN IP
- 若本机还有额外防火墙/安全组，记得放行 `FORWARD`

## 性能

- **国内流量**：只多一遍内核 nftables 集合匹配（红黑树，纳秒级），实测 redsocks **CPU 0.0 ms**，吞吐打满链路。
- **国外流量**：redsocks 用 `splice()` 做用户态中继。实测 200 Mbps 下载仅占**单核 4.5%**，粗略单核可跑 2–4 Gbps。
- **代价**：国外**首次** DNS 200–400 ms（命中缓存后 0 ms）；redsocks 是单线程，极高带宽时会 CPU 受限。
- **并发**：`redsocks_conn_max` 默认只有 **128**（systemd `LimitNOFILESoft=1024` 导致），
  安装脚本已默认调到 **8192**（`--conn-max` 可改）。

详细数据与复现方法见 [docs/performance.md](docs/performance.md)。

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
git clone https://github.com/chenxianlong/redsocks-transparent-proxy \
  ~/.agents/skills/redsocks-transparent-proxy
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

更多细节见 [references/troubleshooting.md](references/troubleshooting.md)。

## 数据来源

- 中国 IP：APNIC `delegated-apnic-latest`
- 非中国 IP：APNIC / ARIN / RIPE NCC / LACNIC / AFRINIC `delegated-*-latest`
- 中国域名：[felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list)

## 许可证

MIT（见 [LICENSE](LICENSE)）
