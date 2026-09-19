#!/bin/bash
# 顶层安装入口 —— 方便一行安装
#
# 方式一（已 clone）:
#   sudo bash install.sh --proxy HOST:PORT
#
# 方式二（一行，无需 clone）:
#   curl -fsSL https://raw.githubusercontent.com/chenxianlong/redsocks-transparent-proxy/main/install.sh \
#     | sudo bash -s -- --proxy HOST:PORT
set -euo pipefail

REPO=${REPO:-https://github.com/chenxianlong/redsocks-transparent-proxy}
BRANCH=${BRANCH:-main}

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "${SELF_DIR:-}" ] && [ -f "$SELF_DIR/scripts/install.sh" ] && [ -f "$SELF_DIR/assets/redsocks-nft.service" ]; then
    exec bash "$SELF_DIR/scripts/install.sh" "$@"
fi

echo "==> 下载 $REPO ($BRANCH)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if ! curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$TMP"; then
    echo "下载失败。国内网络可先设置代理，例如:" >&2
    echo "  export https_proxy=socks5h://HOST:PORT" >&2
    exit 1
fi
DIR=$(find "$TMP" -maxdepth 1 -type d -name 'redsocks-transparent-proxy-*' | head -1)
exec bash "$DIR/scripts/install.sh" "$@"
