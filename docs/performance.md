# 性能：这套分流到底有多大开销？

结论先说：**国内流量几乎零开销；开销几乎全在「国外流量经 redsocks 中继」这一段**，
而且对普通服务器（< 1 Gbps、几百并发）来说完全可忽略。

## 实测（本机，Debian 13 / x86_64）

| 场景 | 吞吐 | 连接延迟 | redsocks CPU |
| --- | --- | --- | --- |
| 国内直连下载（USTC 镜像） | **25.2 MB/s**（≈202 Mbps） | connect 31 ms | **0.0 ms**（不经过 redsocks） |
| 国外经代理下载（Cloudflare 50 MB） | **25.0 MB/s**（≈200 Mbps） | connect 174 ms | **90 ms / 2.0 s = 单核 4.5%** |

反推：50 MB ≈ 0.4 Gbit，用掉 90 ms CPU → **约 225 ms CPU / Gbit**，
粗略外推单核可跑 **2–4 Gbps**（高带宽下非线性，仅作量级参考）。

DNS 解析（`dig` Query time，本机 `127.0.0.1`）：

| 域名 | 首次 | 缓存后 |
| --- | --- | --- |
| `www.taobao.com`（国内） | 8 ms | **0 ms** |
| `www.163.com`（国内） | 4 ms | **0 ms** |
| `www.google.com`（国外） | 52 ms | 4 ms |
| `www.wikipedia.org`（国外） | **408 ms** | **0 ms** |
| `www.reddit.com`（国外） | **224 ms** | **0 ms** |

redsocks 常驻内存 ~1.5 MB（RSS），空闲 CPU 0%。

## 开销分布

### 几乎无开销的部分

- **国内直连流量**：只多走一遍内核 nftables 的 set 匹配。
  `chnroute` 是 `flags interval` 集，内核用红黑树查找，5513 条 ≈ 每包 13 次比较，
  是纳秒级、且不产生用户态开销 —— 实测 redsocks CPU **0.0 ms**，吞吐打满链路。
- **110,573 条中国域名规则**：dnsmasq 内部是域名树匹配，按后缀走，与规则条数关系不大；
  内存几十 MB 量级，查询延迟仍是个位数 ms。
- **直连白名单 / 私有地址**：同样是内核 set / 前缀匹配。

### 有开销的部分

1. **国外首次 DNS：200–400 ms**
   因为 `dnsmasq → unbound → TCP 连接 → redsocks → 代理 → 8.8.8.8` 要串好几个 RTT。
   这是「防污染」必须付的代价；**命中缓存后为 0 ms**，所以只影响冷启动/新域名。

2. **国外 TCP：redsocks 用户态中继**
   - 每个连接在内核被 REDIRECT 到 `127.0.0.1:12345`，redsocks accept 后
     再以 SOCKS5 连到代理，然后双向转发。
   - redsocks 0.5 在 Linux 上用 **`splice()`**（日志里能看到 `redsplice_write_cb`），
     数据不进用户态、走内核 pipe，所以拷贝开销比普通 read/write 中继小。
   - 但它仍是**单线程 epoll**：每字节都要过一遍 `内核 → splice pipe → 内核`，
     外加每连接的 syscall / 事件处理。**高带宽 + 高并发时单核 CPU 会成为瓶颈**。
   - 延迟上多了一跳：本机 → 代理。本例代理在局域网（`10.75.0.6`），这一跳 <1 ms；
     主要延迟来自代理到目标站点的 RTT。

3. **并发连接数（默认值是个坑）**
   `redsocks_conn_max` 不配置时按 `0.75 * nofile / 6`（splice 模式）计算。
   systemd 默认 `LimitNOFILESoft=1024`，于是 **默认只能同时 128 条连接**，
   超出会被丢弃（日志 `reached redsocks_conn_max limit`）。
   做本机浏览/API 够用，但**做网关或高并发业务会被卡住**。

## 已经做的调优

`scripts/install.sh` 默认写入（可用 `--conn-max` 调整）：

```
rlimit_nofile   = 65536
redsocks_conn_max = 8192
```

实测生效：

```
$ grep 'Max open files' /proc/$(pgrep -x redsocks)/limits
Max open files            65536                65536                files
$ grep -o 'conn_max=[0-9]*' /var/log/redsocks.log | tail -1
conn_max=8192
```

> `rlimit_nofile` 与 `redsocks_conn_max` 写在 `/etc/redsocks.conf` 的 `base` 段里。
> redsocks 在 `setuid` **之前**调用 `setrlimit`，所以能成功提升上限。

## 什么时候需要换方案

| 需求 | 建议 |
| --- | --- |
| 本机浏览 / API / 少量下载（< 1 Gbps） | 本方案足够，开销可忽略 |
| 高强度下载、> 1 Gbps | redsocks 单线程可能成为瓶颈，考虑多线程透明代理（如 `sing-box` tproxy 模式）或内核态方案 |
| 局域网网关（几十~几百个客户端） | 本方案 + `--gateway`，记得 `--conn-max` 给足 |
| 只想要极致性能、不介意每应用配置 | 应用层直接配 SOCKS5，省掉内核转发与 redsocks 中继 |

## 复现测量

```bash
pid=$(pgrep -x redsocks)
ticks(){ awk '{print $14+$15}' /proc/$pid/stat; }
HZ=$(getconf CLK_TCK)
c0=$(ticks)
curl -s -o /dev/null -w 'speed=%{speed_download} B/s time=%{time_total}s\n' \
  'https://speed.cloudflare.com/__down?bytes=50000000'
c1=$(ticks)
awk -v a=$c0 -v b=$c1 -v h=$HZ 'BEGIN{printf "redsocks CPU: %.1f ms\n",(b-a)*1000/h}'
```
