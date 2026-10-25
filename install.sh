#!/usr/bin/env bash
# ovz-tune 安装器
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/ovz-tune/main/install.sh)
#   curl -fsSL https://raw.githubusercontent.com/pingmike2/ovz-tune/main/install.sh | bash -s -- --apply
#
# 下载 ovz-tune.sh 到 /usr/local/bin/ovz-tune，校验语法后安装，再按参数运行。
# 可用环境变量覆盖：REPO、BRANCH、BIN。
#
set -euo pipefail

REPO="${REPO:-pingmike2/ovz-tune}"
BRANCH="${BRANCH:-main}"
BIN="${BIN:-/usr/local/bin/ovz-tune}"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/ovz-tune.sh"

[ "$(id -u)" = 0 ] || { echo "需要 root 执行"; exit 1; }

echo "==> 下载 $URL"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp" "$URL"
else
  echo "需要 curl 或 wget" >&2
  exit 1
fi

grep -q '^#!/usr/bin/env bash' "$tmp" || { echo "下载内容不是脚本，已中止" >&2; exit 1; }
bash -n "$tmp" || { echo "语法检查失败，已中止" >&2; exit 1; }

install -m 0755 "$tmp" "$BIN"
echo "==> 已安装: $BIN"
echo

if [ $# -gt 0 ]; then
  exec "$BIN" "$@"
elif [ -t 0 ]; then
  exec "$BIN"
else
  echo "==> 非交互环境，默认只演练。加参数执行，例如: curl ... | bash -s -- --apply"
  exec "$BIN" --dry-run
fi
