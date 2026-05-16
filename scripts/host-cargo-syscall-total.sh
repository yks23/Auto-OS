#!/usr/bin/env bash
# 在 Linux 宿主上用 strace -c 包裹 cargo，汇总 syscall 调用次数（calls 列之和），并打印标记行供与访客统计对照。
# On Linux host: wrap cargo with strace -c, sum the "calls" column, print markers for host vs guest comparison.
#
# Example: ./scripts/host-cargo-syscall-total.sh -- cargo build -p starryos

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/tgoskits"

if [[ "$(uname -s)" != "Linux" ]]; then
	echo "host-cargo-syscall-total.sh: strace 仅适用于 Linux 宿主；macOS/其他系统不支持 strace -c 本脚本。" >&2
	echo "host-cargo-syscall-total.sh: strace -c is Linux-only; this script exits on non-Linux hosts." >&2
	exit 2
fi

if ! command -v strace >/dev/null 2>&1; then
	echo "host-cargo-syscall-total.sh: 未找到 strace。请安装，例如: sudo apt-get install strace" >&2
	exit 3
fi

ts="$(date -u +%Y%m%dT%H%M%SZ)"
: "${HOST_CARGO_STRACE_OUT:=$ROOT/.guest-runs/host-cargo-strace-${ts}.log}"
out="$HOST_CARGO_STRACE_OUT"
mkdir -p "$(dirname "$out")"

cargo_args=(check -p ax-errno)
while [[ $# -gt 0 ]]; do
	case "$1" in
	--)
		shift
		if [[ $# -gt 0 ]]; then
			cargo_args=("$@")
		fi
		break
		;;
	*)
		echo "host-cargo-syscall-total.sh: 未知参数 \"$1\"。请在 cargo 参数前使用 \"--\"。" >&2
		exit 1
		;;
	esac
done

set +e
strace -f -c -o "$out" -- cargo "${cargo_args[@]}"
cargo_status=$?
set -e

if [[ ! -s "$out" ]] || ! grep -q '^% time' "$out" 2>/dev/null; then
	echo "host-cargo-syscall-total.sh: 警告: \"$out\" 为空或缺少 strace -c 表头（% time）；无法可靠解析 calls。" >&2
fi

total_calls="$(
	awk '
		/^% time/ { hdr = 1; next }
		hdr && /^------/ { body = 1; hdr = 0; next }
		body && $NF == "total" && $4 ~ /^[0-9]+$/ { print $4 + 0; done = 1; exit }
		body && $4 ~ /^[0-9]+$/ && $NF != "total" { sum += $4 }
		END {
			if (!done) print sum + 0
		}
	' "$out" 2>/dev/null || true
)"

echo "===HOST_CARGO_SYSCALL_TOTAL ${total_calls}==="
echo "===HOST_CARGO_STRACE_OUT ${out}==="

exit "$cargo_status"
