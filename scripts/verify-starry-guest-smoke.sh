#!/usr/bin/env bash
# 在 QEMU 串口上验证 StarryOS 访客已进到 shell，且用户态命令可用（ls /、echo）。
# 依赖：SERIAL_MODE=tcp（默认），宿主机/容器需能连 127.0.0.1:$SERIAL_TCP_PORT（默认 4444；建议 docker --network host）。
#
# 用法（在仓库根目录）：
#   bash scripts/verify-starry-guest-smoke.sh ARCH=x86_64
#   bash scripts/verify-starry-guest-smoke.sh ARCH=riscv64
#   KERNEL=path/to/starryos DISK=path/to.img bash scripts/verify-starry-guest-smoke.sh ARCH=x86_64
#
# 环境变量：
#   QEMU_BOOT_SEC   最长等待 shell 提示符的秒数（默认 900；慢速 TCG 可调大）
#   QEMU_TOTAL_SEC  Python 读串口阶段总超时（默认 1200）
#   SERIAL_TCP_PORT  与 qemu-run-kernel.sh 一致（默认 4444）；端口被占用时改为 4445 等
#   STARRY_SMOKE_STATS_HTTP  设为 1 或 yes：本机起 HTTP 侧车解析串口里的 syscall 统计块（默认关，避免 CI 占端口）
#   STARRY_SMOKE_STATS_BIND    侧车 bind（默认 127.0.0.1；局域网可 0.0.0.0）
#   STARRY_SMOKE_STATS_PORT    侧车端口（默认 1378）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

ARCH=""
KERNEL=""
DISK=""
for arg in "$@"; do
    case "$arg" in
        ARCH=*)   ARCH="${arg#ARCH=}" ;;
        KERNEL=*) KERNEL="${arg#KERNEL=}" ;;
        DISK=*)   DISK="${arg#DISK=}" ;;
        *) echo "unknown arg: $arg (use ARCH= / KERNEL= / DISK=)" >&2; exit 2 ;;
    esac
done
[[ -n "$ARCH" ]] || { echo "ARCH required (x86_64|riscv64)" >&2; exit 2; }

case "$ARCH" in
    x86_64)
        KERNEL="${KERNEL:-$ROOT/tgoskits/target/x86_64-unknown-none/release/starryos}"
        DISK="${DISK:-$ROOT/tgoskits/os/StarryOS/make/disk.img}"
        ;;
    riscv64)
        KERNEL="${KERNEL:-$ROOT/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos}"
        # 默认不用 M5 自托管盘：其 init 会跑 rustc demo，常占满串口且可能 panic，拿不到稳定 shell。
        if [[ -f "$ROOT/tgoskits/os/StarryOS/rootfs-riscv64.img" ]]; then
            DISK="${DISK:-$ROOT/tgoskits/os/StarryOS/rootfs-riscv64.img}"
        else
            DISK="${DISK:-$ROOT/tgoskits/os/StarryOS/make/disk.img}"
        fi
        ;;
    *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

[[ -f "$KERNEL" ]] || { echo "KERNEL not found: $KERNEL" >&2; exit 1; }
[[ -f "$DISK" ]] || { echo "DISK not found: $DISK" >&2; exit 1; }

if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "need python3 for serial automation" >&2
    exit 1
fi

QEMU_BOOT_SEC="${QEMU_BOOT_SEC:-900}"
QEMU_TOTAL_SEC="${QEMU_TOTAL_SEC:-1200}"
SERIAL_TCP_PORT="${SERIAL_TCP_PORT:-4444}"
export SERIAL_TCP_PORT

log() { printf '[verify-starry] %s\n' "$*" >&2; }

META="$(mktemp "${TMPDIR:-/tmp}/starry-smoke-meta.XXXXXX")"
STATS_HTTP_PID=""
cleanup() {
    [[ -n "${STATS_HTTP_PID:-}" ]] && kill "$STATS_HTTP_PID" 2>/dev/null || true
    [[ -n "${STATS_HTTP_PID:-}" ]] && wait "$STATS_HTTP_PID" 2>/dev/null || true
    [[ -n "${QEMU_PID:-}" ]] && kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    rm -f "$META"
}
trap cleanup EXIT

VERIFY_CAPTURE="$(mktemp "${TMPDIR:-/tmp}/starry-smoke-cap.XXXXXX")"
export VERIFY_CAPTURE
touch "$VERIFY_CAPTURE"

# 可选：实时 syscall 统计 HTTP（默认关闭；默认 bind 127.0.0.1:1378）
if [[ "${STARRY_SMOKE_STATS_HTTP:-0}" == "1" || "${STARRY_SMOKE_STATS_HTTP:-}" == "yes" ]]; then
    STARRY_SMOKE_STATS_BIND="${STARRY_SMOKE_STATS_BIND:-127.0.0.1}"
    STARRY_SMOKE_STATS_PORT="${STARRY_SMOKE_STATS_PORT:-1378}"
    export STARRY_SMOKE_LOG="$VERIFY_CAPTURE"
    export STARRY_SMOKE_STATS_BIND STARRY_SMOKE_STATS_PORT
    "$PY" "$ROOT/scripts/starry-smoke-syscall-http.py" &
    STATS_HTTP_PID=$!
    log "STARRY_SMOKE_STATS_HTTP: http://${STARRY_SMOKE_STATS_BIND}:${STARRY_SMOKE_STATS_PORT}/ (serial -> $VERIFY_CAPTURE)"
fi

# 相对路径传给 qemu-run-kernel.sh，便于日志阅读
_k="${KERNEL#$ROOT/}"
_d="${DISK#$ROOT/}"

log "ARCH=$ARCH KERNEL=$_k DISK=$_d"

# QEMU 进程须活到串口脚本结束：总超时 + 余量（TCP 等待、发命令后读回显）
_qemu_timeout=$(( QEMU_TOTAL_SEC + 300 ))
SERIAL_MODE=tcp TIMEOUT="$_qemu_timeout" bash "$ROOT/scripts/qemu-run-kernel.sh" \
    "ARCH=$ARCH" "KERNEL=$_k" "DISK=$_d" 2>"$META" &
QEMU_PID=$!

# 等待 QEMU 在 $SERIAL_TCP_PORT 上 listen（日志里会出现 waiting for connection）
_listen_end=$(( $(date +%s) + 300 ))
while (( $(date +%s) < _listen_end )); do
    if grep -q "QEMU waiting for connection" "$META" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log "QEMU exited before TCP serial was ready. Meta:"
        tail -40 "$META" >&2 || true
        exit 1
    fi
    sleep 0.4
done

export QEMU_BOOT_SEC QEMU_TOTAL_SEC SERIAL_TCP_PORT

"$PY" - <<'PY'
import os, re, socket, select, sys, time

HOST = "127.0.0.1"
PORT = int(os.environ.get("SERIAL_TCP_PORT", "4444"))
boot_sec = int(os.environ.get("QEMU_BOOT_SEC", "900"))
total_sec = int(os.environ.get("QEMU_TOTAL_SEC", "1200"))
out_path = os.environ.get("VERIFY_CAPTURE", "/tmp/starry-smoke-cap.txt")
MARKER = "STARRY_GUEST_SMOKE_MARKER"


def strip_ansi(b: bytes) -> str:
    t = b.decode("utf-8", errors="replace")
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", t)


def has_shell_prompt(t: str) -> bool:
    if "root@starry" not in t:
        return False
    tail = t[-800:] if len(t) > 800 else t
    if "#" not in tail:
        return False
    if re.search(r"root@starry:[^\n]*#\s*", tail):
        return True
    return False


# 连接（QEMU 已 listen）
deadline = time.time() + 180
s = None
while time.time() < deadline:
    try:
        s = socket.create_connection((HOST, PORT), timeout=3)
        break
    except OSError:
        time.sleep(0.3)
if s is None:
    print(f"FAIL: connect 127.0.0.1:{PORT}", file=sys.stderr)
    sys.exit(1)

s.setblocking(False)
buf = b""
t0 = time.time()
boot_deadline = t0 + boot_sec
overall = t0 + total_sec
sent = False
sent_at = 0.0

with open(out_path, "wb") as capf:
    while time.time() < overall:
        r, _, _ = select.select([s], [], [], 1.0)
        if r:
            try:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
                capf.write(chunk)
                capf.flush()
            except BlockingIOError:
                pass
        plain = strip_ansi(buf)
        if not sent:
            if has_shell_prompt(plain) or time.time() >= boot_deadline:
                s.sendall(b"echo " + MARKER.encode() + b"\n")
                time.sleep(0.35)
                s.sendall(b"ls /\n")
                sent = True
                sent_at = time.time()
        else:
            if MARKER in plain and re.search(
                r"(^|\s)(bin|etc|proc|usr|sbin)(\s|$)", plain, re.M
            ):
                print("PASS: shell + echo + ls / (saw root dirs)")
                sys.exit(0)
            if sent_at and time.time() - sent_at > 120:
                break

print("FAIL: expected marker and root dir name in capture", file=sys.stderr)
print("--- serial tail (stripped) ---", file=sys.stderr)
print(strip_ansi(buf)[-4000:], file=sys.stderr)
sys.exit(1)
PY

rc=$?
if [[ "$rc" -eq 0 ]]; then
    log "OK — capture: $VERIFY_CAPTURE"
    exit 0
fi
exit "$rc"
