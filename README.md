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

结论：**国内流量几乎零开销；开销几乎全在「国外流量经 redsocks 中继」这一段**，
对普通服务器（< 1 Gbps、几百并发）可以忽略。

### 实测（Debian 13 / x86_64）

| 场景 | 吞吐 | 连接延迟 | redsocks CPU |
| --- | --- | --- | --- |
| 国内直连下载（USTC 镜像） | 25.2 MB/s（≈202 Mbps） | connect 31 ms | **0.0 ms**（不经过 redsocks） |
| 国外经代理下载（Cloudflare 50 MB） | 25.0 MB/s（≈200 Mbps） | connect 174 ms | **90 ms / 2.0 s = 单核 4.5%** |

反推：50 MB ≈ 0.4 Gbit 用掉 90 ms CPU → 约 **225 ms CPU / Gbit**，
粗略外推单核可跑 **2–4 Gbps**（高带宽下非线性，仅作量级参考）。

DNS 解析（`dig` Query time，本机 `127.0.0.1`）：

| 域名 | 首次 | 缓存后 |
| --- | --- | --- |
| `www.taobao.com` / `www.163.com`（国内） | 8 / 4 ms | **0 ms** |
| `www.google.com`（国外） | 52 ms | 4 ms |
| `www.wikipedia.org` / `www.reddit.com`（国外） | **408 / 224 ms** | **0 ms** |

redsocks 常驻内存 ~1.5 MB（RSS），空闲 CPU 0%。

### 几乎无开销的部分

- **国内直连流量**：只多走一遍内核 nftables 集合匹配。`chnroute` 是 `flags interval` 集，
  内核用红黑树查找，5513 条约 13 次比较/包，纳秒级且**不产生用户态开销** ——
  实测 redsocks **CPU 0.0 ms**，吞吐打满链路。
- **110,573 条中国域名规则**：dnsmasq 内部是域名树后缀匹配，与规则条数关系不大；
  内存几十 MB 量级，查询仍是个位数 ms。
- **直连白名单 / 私有地址**：同样是内核 set / 前缀匹配。

### 有开销的部分

1. **国外首次 DNS：200–400 ms**
   因为 `dnsmasq → unbound → TCP 连接 → redsocks → 代理 → 8.8.8.8` 要串好几个 RTT。
   这是「防污染」必须付的代价；**命中缓存后为 0 ms**，只影响冷启动/新域名。
2. **国外 TCP：redsocks 用户态中继**
   每个国外连接在内核被 REDIRECT 到 `127.0.0.1:12345`，redsocks accept 后再以 SOCKS5
   连到代理并双向转发。redsocks 0.5 在 Linux 上用 **`splice()`**（日志里能看到
   `redsplice_write_cb`），数据不进用户态、走内核 pipe，比普通 read/write 中继省很多；
   但它仍是**单线程 epoll**，极高带宽（> 1 Gbps）时单核会成为瓶颈。
   延迟上多一跳「本机 → 代理」，本例代理在局域网，这一跳 <1 ms。
3. **并发连接数（默认值是个坑）**
   `redsocks_conn_max` 不配置时 = `0.75 × nofile / 6`（splice 模式）。
   systemd 默认 `LimitNOFILESoft=1024` → **默认只能同时 128 条连接**，超出直接丢。
   安装脚本已默认写入 `rlimit_nofile = 65536` + `redsocks_conn_max = 8192`
   （`--conn-max` 可调），实测生效 `conn_max=8192`。

### 什么时候需要换方案

| 需求 | 建议 |
| --- | --- |
| 本机浏览 / API / 一般下载（< 1 Gbps） | 本方案足够，开销可忽略 |
| 高强度下载、> 1 Gbps | redsocks 单线程可能成瓶颈，考虑多线程透明代理（如 `sing-box` tproxy）或内核态方案 |
| 局域网网关（几十~几百客户端） | 本方案 + `--gateway`，`--conn-max` 给足 |
| 只要极致性能、不介意每应用配置 | 应用层直配 SOCKS5，省掉内核转发与 redsocks 中继 |

完整版与复现脚本见 [docs/performance.md](docs/performance.md)。

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
