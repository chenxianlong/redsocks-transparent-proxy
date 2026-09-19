# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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
