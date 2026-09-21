# 把「Debian 专属」的透明分流方案移植到 Rocky Linux 10：一次踩穿三个坑的完整记录

> 国内服务器想优雅地访问外网，通常的做法是「透明分流」：非中国 IP 的 TCP 走代理，中国 IP 直连，DNS 按域名分流以规避污染。开源方案 [redsocks-transparent-proxy](https://github.com/chenxianlong/redsocks-transparent-proxy) 做得很好——但它只支持 Debian/Ubuntu。
>
> 本文记录我把它完整移植到 **Rocky Linux 10**（RHEL 系）的全过程：从「包都不存在」到「CONNECT 返回 200 却永远卡住」，再到把改动以 PR 形式合并回上游。

---

## 一、先看效果

目标很朴素：**不配置任何应用、不设任何 `*_proxy` 环境变量，机器上的程序自动访问外网，国内流量不受影响。**

```
$ curl --noproxy '*' -o /dev/null -w '%{http_code} %{time_total}s\n' https://www.google.com
200 0.22s

$ curl --noproxy '*' -o /dev/null -w '%{http_code} %{time_total}s\n' https://www.baidu.com
200 0.03s          # 国内直连，几乎零开销

$ curl --noproxy '*' -s https://ipinfo.io/ip
<taiwan-exit-ip>   # 出口在台湾
```

注意 `--noproxy '*'`：它强制绕过环境变量代理。所以这里走的是**内核透明重定向**，而不是靠 `http_proxy`。这才叫「透明」。

---

## 二、方案原理

```
应用
 ├─ DNS → 127.0.0.1:53 (dnsmasq)
 │         ├─ 中国域名(11万条 + .cn) ──→ 223.5.5.5（UDP 直连）
 │         └─ 其它域名 ──→ 127.0.0.1:5353 (unbound)
 │                              └─ 上游 TCP 8.8.8.8 / 1.1.1.1:53（经代理）
 └─ TCP
       ▼
   nftables (table ip redsocks, nat/OUTPUT)
     ├─ 私有/保留地址、代理服务器、直连白名单、中国 IP 段 → RETURN（直连）
     └─ 其它 TCP → REDIRECT 127.0.0.1:12345 → redsocks → SOCKS5/HTTP 代理
```

关键点有两个：

1. **TCP 层**：用 `nftables` 的 `nat/OUTPUT` 把「非中国」目标的连接重定向到本机 `redsocks`，由它转发给上游代理。纯内核转发，应用无感知。
2. **DNS 层**：本地 DNS 对墙外域名是被污染的，所以 DNS 也必须走代理。但很多代理（clash/mihomo 类）的 SOCKS5 UDP 回复来自随机源端口，`redsocks` 的 `redudp` 用 `connect()` 过的 UDP socket，会丢弃源端口不符的包。**因此改用 DNS-over-TCP**：`unbound` 的 `forward-tcp-upstream` 让上游查询走 TCP，这段 TCP 又会被 nft 规则重定向并经代理出去。

这套设计在 Debian 上跑得很好。问题出在——我们的机器是 Rocky Linux 10。

---

## 三、环境

| 项 | 值 |
| --- | --- |
| OS | Rocky Linux 10.2（RHEL 10 系） |
| 初始化 | systemd |
| 防火墙 | firewalld（nftables 后端） |
| DNS | NetworkManager 托管 `/etc/resolv.conf` |
| SELinux | **Enforcing** |
| 代理 | 一个内网 HTTP CONNECT 代理 `HOST:PORT` |

第一眼结论：**官方安装脚本是 Debian 专用的**（`apt-get`、`/etc/unbound/unbound.conf.d/`、依赖发行版 `redsocks` 包……），直接跑必然失败。于是有了下面一连串的坑。

---

## 四、坑 1：RHEL 系根本没有 `redsocks` 包

```
$ dnf list --available redsocks
错误：没有匹配的软件包可以列出
```

`redsocks` 在 EL10 上已经被 EPEL 移除，仓库里没有。而 `unbound` / `dnsmasq` 都在 AppStream，无需 EPEL。

**解法：从源码编译 `release-0.5`。** 依赖也就 `gcc make libevent-devel patch`：

```bash
curl -L https://github.com/darkk/redsocks/archive/refs/tags/release-0.5.tar.gz | tar xz
cd redsocks-release-0.5
make -j"$(nproc)"
install -m0755 redsocks /usr/sbin/redsocks
groupadd -r redsocks; useradd -r -g redsocks -s /sbin/nologin -d /nonexistent redsocks
```

看起来平平无奇，但编译出来之后，才暴露出真正的坑。

---

## 五、坑 2：`redsocks` 的 `daemon = on` 在 systemd 下「假死」

先按 Debian 的习惯写配置：`daemon = on`，然后丢给 systemd。结果：

```
redsocks.service: Can't open PID file '/run/redsocks/redsocks.pid' (yet?) after start
```

服务卡在 `activating`，**没有进程、没有 PID 文件、没有报错**。

翻 `base.c` 就明白了：`redsocks` 在 `daemon = on` 时会 **先 `setuid` 再 `fork`**：

```c
if (instance.user)  setuid(uid);
if (instance.daemon) {
    switch (fork()) {
    case 0:  break;              // child 继续
    default: exit(EXIT_SUCCESS); // parent 退出
    }
}
```

在 systemd 的进程管理下，这套 daemonize 流程会让子进程异常退出，systemd 于是一直等在 `activating`。

**解法：别 daemon 了，前台跑 + `Type=simple`。**

```ini
[Service]
Type=simple
ExecStartPre=/usr/sbin/redsocks -t -c /etc/redsocks.conf
ExecStart=/usr/sbin/redsocks -c /etc/redsocks.conf
```

配置里对应 `daemon = off;`。这是 RHEL 系与原 Debian 方案的第一处分叉。

---

## 六、坑 3（最硬核）：代理明明返回了 `200 Connection established`，却一直卡住

这是整场排查里最有意思的一个。

### 现象

`redsocks` 起来了，nft 规则也加载了。国内网站秒开，国外网站……超时：

```
$ curl --noproxy '*' -o /dev/null -w '%{http_code} %{time_total}s\n' https://github.com
000 20.00s
```

`redsocks` 日志却显得很正常：

```
info  redsocks.c: accepted [192.0.2.10:50638->203.0.113.10:443]
info  redsocks.c: accepted [192.0.2.10:46850->203.0.113.10:443]
...
```

只有 `accepted`，之后 20 秒超时断开。代理到底通没通？上 `strace`：

```
accept(...) = 10
getsockopt(10, SOL_IP, 0x50 /* SO_ORIGINAL_DST */, ...) = 0   # 拿到原始目标
socket(AF_INET, SOCK_STREAM, ...) = 11
connect(11, {sin_port=htons(6789), sin_addr="198.51.100.6"}) = -1 EINPROGRESS
getsockopt(11, SOL_SOCKET, SO_ERROR, [0]) = 0                 # 连上代理
writev(11, [{iov_base="CONNECT 203.0.113.10:443 HTTP/", iov_len=39}], 1) = 39
readv(10, [...1558 bytes...]) = 1558                          # 客户端 TLS ClientHello 到了
readv(11, [{iov_base="HTTP/1.0 200 Connection establis"...}], 1) = 39   # 代理回 200 了！
# 然后……就没有然后了。客户端那 1558 字节一直没被转发出去。
```

**代理已经回了 `HTTP/1.0 200 Connection established`，`redsocks` 也读到了**，但它既不转发客户端数据，也不报错，就这么挂着。

### 定位：CONNECT 响应没被解析完

给 `http-connect.c` 的 `httpc_read_cb` 加了几行调试日志重新编译，一眼看穿：

```
HTTPC read_cb ENTER state=1 inlen=39
HTTPC firstline=[HTTP/1.0 200 Connection established]
HTTPC read_cb EXIT state=2         # 卡在 httpc_reply_came，没进 headers_skipped
```

`http-connect` 的状态机是这样的：

```c
typedef enum {
    httpc_new, httpc_request_sent,
    httpc_reply_came,        // 收到 200，正在跳过响应头
    httpc_headers_skipped,   // 头部跳完了 → 启动隧道
    ...
} httpc_state;
```

它逐行读代理响应：第一行解析出 `200` → `reply_came`；再读到一个**空行**才算头部结束 → `headers_skipped`。而这里读完第一行后，**空行没被识别出来**，状态停在 `reply_came`，隧道永远不启动。

代理发的是标准响应：`HTTP/1.0 200 Connection established\r\n\r\n`（39 字节，末尾是 CRLF + 空行 CRLF）。

### 真凶：`evbuffer_readline` 会一口吞掉 `\r\n\r\n`

`redsocks` 读行的封装在 `utils.c`：

```c
char *redsocks_evbuffer_readline(struct evbuffer *buf)
{
#if _EVENT_NUMERIC_VERSION >= 0x02000000
    return evbuffer_readln(buf, NULL, EVBUFFER_EOL_CRLF);   // 正确
#else
    return evbuffer_readline(buf);                          // 已废弃，有坑
#endif
}
```

问题就在这个版本判断。在部分 libevent 2.1 的头文件里，**`_EVENT_NUMERIC_VERSION` 根本没有被定义**（它其实是 `event2/event-config.h` 里的东西，而 `redsocks` 只 `#include <event.h>`）。未定义的宏在做 `>=` 比较时按 `0` 处理，于是走了 `#else` 分支的**废弃函数 `evbuffer_readline()`**。

写个小 C 程序对比两者行为：

```c
// 输入: "HTTP/1.0 200 Connection established\r\n\r\n"
l1 = evbuffer_readln(b, NULL, EVBUFFER_EOL_CRLF);  // 正确
l2 = evbuffer_readln(b, NULL, EVBUFFER_EOL_CRLF);
// l1=[HTTP/1.0 200 Connection established]  l2=[]  remaining=0   ✅

l1 = evbuffer_readline(b);   // 废弃版
l2 = evbuffer_readline(b);
// l1=[HTTP/1.0 200 Connection established] (len 35)  l2=(null)  remaining=0  ❌
```

看明白了吗？**旧的 `evbuffer_readline()` 会把末尾连续的两个 `\r\n` 当成一个整体吞掉**：第一次就消费了全部 39 字节，第二次直接返回 `NULL`。于是 `http-connect` 永远读不到那个「空行」，状态机卡死。

> 这也是为什么同一个方案在 Debian 上没事：Debian 的 libevent 头文件恰好定义了 `_EVENT_NUMERIC_VERSION`，走了正确分支。**代码里一个看不见的宏，决定了整条链路通不通。**

### 修复

一行搞定——别判断了，永远用新 API：

```c
char *redsocks_evbuffer_readline(struct evbuffer *buf)
{
    /* libevent 2.x 头文件不一定会定义 _EVENT_NUMERIC_VERSION；
     * 旧的 evbuffer_readline() 会把 CONNECT 响应末尾的 CRLF 空行一起吞掉，
     * 导致 http-connect 永远等不到空行而卡死。统一用 evbuffer_readln。 */
    return evbuffer_readln(buf, NULL, EVBUFFER_EOL_CRLF);
}
```

补丁：`scripts/patches/redsocks-0.5-evbuffer-readline.patch`（在编译前由构建脚本自动应用）。

另外 RHEL 系默认把 `splice = off`（改用 buffer pump），进一步规避握手期数据处理的边界情况：

```conf
redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = HOST; port = PORT;
    type = http-connect;
    splice = off;
}
```

修完之后：

```
$ curl --noproxy '*' -o /dev/null -w '%{http_code} %{time_total}s\n' https://github.com
200 0.41s     ✅
```

---

## 七、坑 4：SELinux 不让 `unbound` 绑 5353

分流设计里 `unbound` 监听 `5353`。Rocky 默认 **SELinux Enforcing**，于是：

```
error: can't bind socket: Permission denied for 127.0.0.1 port 5353
avc: denied { name_bind } for ... scontext=system_u:system_r:unbound_t:s0
    tcontext=system_u:object_r:unreserved_port_t:s0 tclass=tcp_socket
```

原因：`unbound` 的 SELinux 域只被允许绑定 `dns_port_t` 类型（默认 53、853）。给它加个标签即可（持久化）：

```bash
dnf install -y policycoreutils-python-utils
semanage port -a -t dns_port_t -p tcp 5353
semanage port -a -t dns_port_t -p udp 5353
```

---

## 八、坑 5：`unbound` 的 include 目录不一样

Debian 的 `unbound` 会自动 include `/etc/unbound/unbound.conf.d/*.conf`；而 RHEL 系 include 的是 `/etc/unbound/conf.d/*.conf`。

把配置写错目录，**不会有任何报错**——它只是安静地不生效。所以安装脚本必须按发行版选择目录。同理还有：

- DNS 接管：Debian 常用 systemd-resolved 或 nmcli，RHEL 系走 NetworkManager（`nmcli con mod ... ipv4.dns 127.0.0.1`）。
- 包管理器：`apt` ↔ `dnf`。

---

## 九、把这些做成通用方案

修完坑之后，我把适配整理成了对上游的多发行版支持（已 PR 合并）。核心是让安装脚本**自动识别发行版并分支**：

| 项目 | Debian/Ubuntu | RHEL/CentOS/Rocky/Alma |
| --- | --- | --- |
| 包管理器 | `apt-get` | `dnf` |
| `redsocks` | 发行版包 | **源码编译** + 补丁 |
| 运行方式 | `daemon=on`（发行版 unit） | `daemon=off` + `Type=simple` |
| 数据泵 | `splice` 开 | `splice` 关 |
| unbound 配置 | `unbound.conf.d/` | `conf.d/` |
| SELinux | 一般不启用 | Enforcing 时打 `dns_port_t` |
| DNS 接管 | systemd-resolved / nmcli | NetworkManager(`nmcli`) |

脚本关键片段（发行版检测）：

```bash
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) DISTRO_FAMILY=debian ;;
    *" rhel "*|*" fedora "*|*" centos "*|" rocky "*|*" alma "*) DISTRO_FAMILY=rhel ;;
esac

if [ "$DISTRO_FAMILY" = rhel ]; then
    UNBOUND_CONF_DIR=/etc/unbound/conf.d
    REDSOCKS_DAEMON=off      # 前台运行
    SPLICE_DEFAULT=off
fi
```

安装时自动安装依赖、编译 `redsocks`、生成 systemd unit、处理 SELinux、切换 DNS，一条命令搞定：

```bash
sudo bash scripts/install.sh --proxy HOST:PORT --type http-connect
```

输出：

```
==> 发行版: Rocky Linux 10.2 (Red Quartz) (family=rhel)
==> 1b/9 RHEL 系无 redsocks 软件包，从源码编译
==> 2b/9 SELinux: 允许 unbound 绑定端口 5353
==> 9/9 自检
    https://www.google.com       200
    https://github.com           200
    https://www.baidu.com        200
```

---

## 十、完整验证

```bash
# 透明链路（强制绕过 env 代理，证明是内核重定向在工作）
for u in https://www.google.com https://github.com \
         https://www.youtube.com https://www.wikipedia.org https://www.baidu.com; do
  curl --noproxy '*' -s -o /dev/null -w "$u  %{http_code}  %{time_total}s\n" "$u"
done
# google 200 0.22s / github 200 0.41s / youtube 200 0.36s
# wikipedia 200 0.72s / baidu 200 0.03s

# DNS 分流
dig +short @127.0.0.1 www.baidu.com   # 国内直连解析
dig +short @127.0.0.1 www.google.com  # 真实 IP（未被污染）

# 全新环境（无任何 *_proxy）也照样通
env -i /bin/bash -l -c 'curl -s -o /dev/null -w "%{http_code}\n" https://www.google.com'
```

最后的杀手锏验证——**连不读代理环境变量的 Python / Node 程序也能透明出网**：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    python3 -c "import urllib.request; print(urllib.request.urlopen('https://www.google.com').status)"
# 200
```

这才是「透明」的意义：**应用什么都不用改。**

---

## 十一、几个附加提醒

- **`ping` 墙外依然不通**：`redsocks` 只处理 TCP，ICMP 不代理。别拿 ping 判断成败。
- **停 `redsocks-nft` 会连带 DNS 挂掉**：`unbound` 的 TCP 上游依赖这条重定向。要停就整套停，或先把 `/etc/resolv.conf` 指回国内 DNS。
- **删除 `/etc/profile.d/proxy.sh` 之类环境变量代理 ≠ 立刻生效**：已在运行的进程仍持有旧变量，需要重新登录/重启才彻底干净。
- **本机若无全局 IPv6**：AAAA 能解析但连不通，应用会自动回落 IPv4（被代理），一般无碍。

---

## 十二、小结与经验

1. **同一个方案在不同发行版上失败，往往不是配置问题，而是二进制/内核行为的细微差异。** 这次的真凶是一个未定义宏 + 一个废弃 API，与发行版无关，却只在某些 libevent 头文件下触发。
2. **`strace` 是穿透「应用层日志一切正常」的利器。** `accepted` 之后到底有没有 `write`、有没有 `read`，一看便知。
3. **别迷信「API 名字对就行」。** `evbuffer_readline` 和 `evbuffer_readln` 只差一个字母，语义却差之千里。
4. **SELinux 的 `Permission denied` 先看 `ausearch -m avc`**，绝大多数情况加个端口/文件标签就能解决，不必关 SELinux。
5. **把踩坑固化成补丁和脚本**，而不是留在自己的终端历史里——顺手提个 PR，下一个人就不用再踩一遍。

## 参考

- 项目地址：https://github.com/chenxianlong/redsocks-transparent-proxy
- 本文对应的适配 PR：https://github.com/chenxianlong/redsocks-transparent-proxy/pull/1
- 平台支持文档：[docs/platform-support.md](platform-support.md)
- `redsocks`：https://github.com/darkk/redsocks
- 中国域名表：https://github.com/felixonmars/dnsmasq-china-list

---

*本文基于一次真实的生产适配整理，所有 IP、代理地址已脱敏。*
