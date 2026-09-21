# 平台支持：在 RHEL / CentOS / Rocky / Alma 上部署

本项目最初只支持 Debian/Ubuntu。经过在 **Rocky Linux 10** 上的完整适配，现在
安装脚本会自动识别发行版并走对应逻辑。本文记录平台差异、原理与踩坑。

## 平台矩阵

| 项目 | Debian 12/13、Ubuntu 22.04+ | RHEL / CentOS / Rocky / Alma / Fedora |
| --- | --- | --- |
| 包管理器 | `apt-get` | `dnf` |
| `redsocks` | 发行版软件包（自带 systemd unit） | **仓库无包 → 源码编译** `release-0.5` |
| `redsocks` 运行方式 | `daemon = on`（fork 后台） | `daemon = off`（前台）+ `Type=simple` |
| 数据泵 | `splice` 默认开 | `splice = off`（buffer pump） |
| unbound 配置目录 | `/etc/unbound/unbound.conf.d/` | `/etc/unbound/conf.d/` |
| DNS 接管 | systemd-resolved stub / nmcli | NetworkManager (`nmcli`) |
| SELinux | 一般不启用 | **常为 `Enforcing`**，需处理端口标签 |
| `nft` | `/usr/sbin/nft` | `/usr/sbin/nft` |

> `unbound` / `dnsmasq` 在 RHEL 系的 AppStream 仓库中都有，无需 EPEL；
> 只有 `redsocks` 需要编译。

## 安装（一行）

```bash
git clone https://github.com/chenxianlong/redsocks-transparent-proxy
sudo bash redsocks-transparent-proxy/scripts/install.sh --proxy HOST:PORT --type http-connect
```

脚本会自动：`dnf` 安装依赖 → 编译 redsocks → 生成 systemd unit → 处理 SELinux →
启动 redsocks/nftables/unbound/dnsmasq → 切换系统 DNS。

## 三个必须知道的坑

### 1) `redsocks` 的 `daemon = on` 在 systemd 下会“假死”

`redsocks` 在 `daemon = on` 时会 **先 `setuid` 再 `fork`**。在 systemd 下子进程可能
在 daemonize 过程中退出，于是 `redsocks.service` 卡在 `activating`，没有进程、没有
PID 文件：

```
redsocks.service: Can't open PID file '/run/redsocks/redsocks.pid' (yet?) after start
```

**解法**：前台运行 + 生成的 unit：

```ini
[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c /etc/redsocks.conf
```

配置里对应 `daemon = off;`。脚本在 RHEL 系会自动这样生成。

### 2) `redsocks_evbuffer_readline()` 吞掉 CONNECT 响应的空行（致命）

`redsocks 0.5` 的代码：

```c
#if _EVENT_NUMERIC_VERSION >= 0x02000000
    return evbuffer_readln(buf, NULL, EVBUFFER_EOL_CRLF);
#else
    return evbuffer_readline(buf);   // 旧的、已废弃
#endif
```

在部分 libevent 2.1 头文件里 **`_EVENT_NUMERIC_VERSION` 未定义**，于是走了旧的
`evbuffer_readline()`。它会把 `HTTP/1.0 200 Connection established\r\n\r\n` 里的
**两个 CRLF 一次性吃掉**，导致 `http-connect` 永远等不到“空行”而卡死：

- 现象：`redsocks` 日志只有 `accepted`，之后 20s 超时断开；`curl` 得到 `HTTP 000`。
- `strace` 可见：已向代理发出 `CONNECT`、已收到 `200`，但客户端先发的 TLS
  ClientHello 一直没被转发。

**解法**：强制使用 `evbuffer_readln(EVBUFFER_EOL_CRLF)`。补丁见
[`scripts/patches/redsocks-0.5-evbuffer-readline.patch`](https://github.com/chenxianlong/redsocks-transparent-proxy/blob/main/scripts/patches/redsocks-0.5-evbuffer-readline.patch)，
`scripts/redsocks-build.sh` 在编译前自动应用。

同时 RHEL 系默认 `splice = off`（用 buffer pump），进一步规避握手期数据处理差异。

### 3) SELinux 默认禁止 unbound 绑定非 53 端口

分流设计里 unbound 监听 `5353`，但 `unbound` 以 `named_t` 运行，只被允许绑定
`dns_port_t`（53、853）：

```
error: can't bind socket: Permission denied for 127.0.0.1 port 5353
avc: denied { name_bind } for ... scontext=system_u:system_r:named_t:s0
    tcontext=system_u:object_r:unreserved_port_t:s0 tclass=tcp_socket
```

**解法**（持久化）：

```bash
sudo dnf install -y policycoreutils-python-utils
sudo semanage port -a -t dns_port_t -p tcp 5353
sudo semanage port -a -t dns_port_t -p udp 5353
```

脚本在 SELinux 为 `Enforcing` 时自动执行。

## 手动部署步骤（Rocky 10 实战）

想手工复现或用其它初始化系统时，按此顺序：

```bash
# 1. 依赖
dnf install -y gcc make libevent-devel patch tar gzip unbound dnsmasq bind-utils

# 2. 编译 redsocks（带 CRLF 补丁）
curl -L https://github.com/darkk/redsocks/archive/refs/tags/release-0.5.tar.gz | tar xz
cd redsocks-release-0.5
patch -p1 < /path/to/scripts/patches/redsocks-0.5-evbuffer-readline.patch
make -j"$(nproc)" && install -m0755 redsocks /usr/sbin/redsocks
groupadd -r redsocks; useradd -r -g redsocks -s /sbin/nologin -d /nonexistent redsocks

# 3. redsocks 配置（注意 daemon=off、splice=off、type=http-connect）
cat >/etc/redsocks.conf <<'EOF'
base { log_info=on; log="file:/var/log/redsocks.log"; daemon=off;
       user=redsocks; group=redsocks; redirector=iptables;
       rlimit_nofile=65536; redsocks_conn_max=8192; }
redsocks { local_ip=127.0.0.1; local_port=12345;
           ip=PROXY_IP; port=PROXY_PORT; type=http-connect; splice=off; }
EOF

# 4. systemd unit（Type=simple）
# 5. unbound 配置写入 /etc/unbound/conf.d/redsocks.conf（端口 5353，forward-tcp-upstream）
# 6. SELinux 打 5353 标签
# 7. nftables 规则（scripts/redsocks-nft.sh）
# 8. dnsmasq(53) → unbound(5353)，并把系统 DNS 指向 127.0.0.1（nmcli）
```

完整参数化实现见 [`scripts/install.sh`](https://github.com/chenxianlong/redsocks-transparent-proxy/blob/main/scripts/install.sh)。

## 验证

```bash
# 绕过任何 env 代理，纯透明链路
curl --noproxy '*' -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://www.google.com
curl --noproxy '*' -s https://ipinfo.io/ip          # 应显示代理出口 IP

# DNS 分流
dig +short @127.0.0.1 www.baidu.com                 # 国内直连解析
dig +short @127.0.0.1 www.google.com                # 真实 IP（未被污染）

# 服务与规则
systemctl status redsocks redsocks-nft unbound dnsmasq
sudo redsocks-nft show
```

## 常见附加问题

- **不能 `ping` 墙外**：`redsocks` 只处理 TCP，ICMP 不代理。
- **本机无全局 IPv6**：AAAA 能解析但连不通，应用会自动回落 IPv4（被代理）。
- **`systemctl stop redsocks-nft` 会连带 DNS 失效**：unbound 的 TCP 上游依赖该重定向；
  要停就整套停，或先把 `/etc/resolv.conf` 改回国内 DNS。
- **只删除 `/etc/profile.d/proxy.sh` 之类环境变量代理不够**：已在运行的进程仍持有旧变量，
  需重新登录/重启才会彻底干净。

## 回滚

```bash
sudo bash scripts/uninstall.sh          # 保留软件包
sudo bash scripts/uninstall.sh --purge  # 连同 redsocks/unbound/dnsmasq 一起卸载，并撤销 SELinux 标签
```
