# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.3.0] - 2026-09-21

### Added

- **RHEL 系支持**：RHEL / CentOS / Rocky / Alma / Fedora。安装脚本自动识别发行版，
  RHEL 系在仓库无 `redsocks` 软件包时从源码编译（`scripts/redsocks-build.sh`）
- `scripts/patches/redsocks-0.5-evbuffer-readline.patch`：修复 http-connect 在
  未定义 `_EVENT_NUMERIC_VERSION` 的 libevent 上把 CONNECT 响应尾部 `\r\n\r\n`
  一次吞掉、导致隧道卡死的严重 bug
- 新增 `--splice on|off` 选项（RHEL 系默认 `off`，buffer pump 更稳）
- RHEL 系自动创建 `redsocks.service`（`Type=simple` + `daemon = off`）
- RHEL 系自动处理 SELinux：为非 53 端口（unbound `5353`）打 `dns_port_t` 标签
- unbound 配置目录按发行版区分（Debian `unbound.conf.d/`，RHEL `conf.d/`）
- 新增 `docs/platform-support.md`：平台差异、发行版适配与踩坑记录
- 新增 `docs/blog-rhel-transparent-proxy.md`：RHEL 适配全过程长文（可投稿博客/掘金）
- README / README.en 增加「相关文章」入口

### Changed

- `scripts/install.sh` 重构为多发行版：包管理器（`apt`/`dnf`）、redsocks 获取方式、
  systemd unit、unbound 路径、SELinux、DNS 接管全部按发行版分支
- `scripts/uninstall.sh` 同时支持 `apt`/`dnf`，并撤销 SELinux 端口标签
- README / README.en / SKILL 更新环境要求与平台矩阵

## [1.2.0] - 2026-09-19

### Added

- 性能文档 `docs/performance.md`：实测吞吐 / CPU / DNS 延迟与复现方法
- `--conn-max` 选项；安装脚本默认写入 `rlimit_nofile = 65536`、
  `redsocks_conn_max = 8192`（默认值只有 128，高并发下会丢连接）
- README / README.en 增加性能小节

## [1.1.0] - 2026-09-19

### Added

- 架构示意图：`docs/architecture.png`（中文）/ `docs/architecture.en.png`（English）
- 图表生成脚本 `docs/architecture.py`（生成 SVG，`rsvg-convert` 渲染 PNG）
- README / README.en 中引用示意图

## [1.0.0] - 2026-09-19

### Added

- 透明分流：非中国 IP 的 TCP 流量经 SOCKS5/HTTP 代理，中国 IP 直连
  (`redsocks` + `nftables` nat/OUTPUT，原生 nft set，无需 iptables/ipset)
- DNS 按域名分流：`dnsmasq`(127.0.0.1:53) + `unbound`(TCP 上游)，
  国内域名走国内 DNS 直连，国外域名经代理解析，规避 DNS 污染
- 直连白名单 `direct_dst.txt`
- 参数化安装脚本 `scripts/install.sh`
  (`--proxy/--type/--user/--pass/--direct-dns/--remote-dns/--no-dns-split/...`)
- `--allowlist` 模式：只代理 `not_cn.txt` 中的 IP
- `--gateway` 模式（实验性）：开启 `ip_forward` + `nat/prerouting`，为局域网转发
- IP 段表更新脚本（5 大 RIR）与中国域名表更新脚本（dnsmasq-china-list）
- 顶层 `install.sh`，支持 `curl | bash` 一行安装
- 打包为 Agent Skill（`SKILL.md`）
- `references/troubleshooting.md`：redudp 随机源端口、DNS 污染等踩坑记录

### Notes

- 代理为 clash/mihomo 类时，`redudp` 不可用（SOCKS5 UDP 回复来自随机源端口），
  故 DNS 采用 DNS-over-TCP。
