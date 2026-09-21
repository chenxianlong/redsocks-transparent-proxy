#!/bin/bash
# 在没有 redsocks 软件包的发行版（RHEL / CentOS / Rocky / Alma 等）上，
# 从源码编译 redsocks 0.5，并应用 http-connect CRLF 解析修复补丁。
#
# 用法: sudo scripts/redsocks-build.sh [--proxy http://HOST:PORT | socks5h://HOST:PORT]
#
# --proxy 仅用于下载源码（源码直连失败时回退）。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PATCH_FILE="$ROOT/scripts/patches/redsocks-0.5-evbuffer-readline.patch"
VERSION=0.5
SRC_URL="https://github.com/darkk/redsocks/archive/refs/tags/release-${VERSION}.tar.gz"
BINDIR=/usr/sbin

PROXY_URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --proxy) PROXY_URL=${2:-}; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行" >&2; exit 1; }
[ -r "$PATCH_FILE" ] || { echo "缺少补丁文件: $PATCH_FILE" >&2; exit 1; }

fetch() { # fetch <url> <out>
    local url=$1 out=$2
    if curl -fsSL --max-time 180 "$url" -o "$out" 2>/dev/null; then
        return 0
    fi
    if [ -n "$PROXY_URL" ]; then
        echo "    直连失败，改用代理下载 ..."
        curl -fsSL --max-time 180 -x "$PROXY_URL" "$url" -o "$out"
    else
        return 1
    fi
}

echo "==> 安装编译依赖"
if command -v dnf >/dev/null 2>&1; then
    dnf install -y -q gcc make libevent-devel tar gzip patch
elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq gcc make libevent-dev tar gzip patch
else
    echo "未找到 dnf/apt-get，请手动安装: gcc make libevent-devel patch" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载 redsocks $VERSION 源码"
fetch "$SRC_URL" "$TMP/redsocks.tar.gz"
tar xzf "$TMP/redsocks.tar.gz" -C "$TMP"
SRCDIR=$(find "$TMP" -maxdepth 1 -type d -name 'redsocks-*' | head -1)
[ -n "$SRCDIR" ] || { echo "源码解压失败" >&2; exit 1; }

echo "==> 应用补丁 $(basename "$PATCH_FILE")"
( cd "$SRCDIR" && patch -p1 < "$PATCH_FILE" )

echo "==> 编译"
( cd "$SRCDIR" && make -j"$(nproc)" )

echo "==> 安装到 $BINDIR/redsocks"
install -m 0755 "$SRCDIR/redsocks" "$BINDIR/redsocks"

echo "==> 创建 redsocks 系统用户"
getent group redsocks >/dev/null 2>&1 || groupadd -r redsocks
getent passwd redsocks >/dev/null 2>&1 || useradd -r -g redsocks -s /sbin/nologin -d /nonexistent redsocks

echo "==> 完成: $("$BINDIR/redsocks" -v 2>/dev/null | head -1 || echo redsocks)"
