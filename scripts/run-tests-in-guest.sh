#!/usr/bin/env bash
# 在 guest QEMU 内跑 tests/selfhost/ 中所有 test_* 二进制。
#
# 流程：
#   1. (Director 或 caller 已经) bash scripts/integration-build.sh ARCH=$ARCH
#   2. (Director 或 caller 已经) cd tests/selfhost && make ARCH=$ARCH
#   3. 拉 starry rootfs，挂载，把 out-$ARCH/test_* 拷到 /opt/selfhost-tests/
#   4. 在 rootfs 里写一个 /opt/run-tests.sh
#   5. QEMU 启动 kernel + 这个 rootfs
#   6. 串口连进去，等 BusyBox shell prompt，发 `sh /opt/run-tests.sh; exit`
#   7. 收集 [TEST] xxx PASS|FAIL 行，汇总
#
# 用法：scripts/run-tests-in-guest.sh ARCH=riscv64 [TIMEOUT=300]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ARCH=""
TIMEOUT=300
for arg in "$@"; do
    case "$arg" in
        ARCH=*) ARCH="${arg#ARCH=}" ;;
        TIMEOUT=*) TIMEOUT="${arg#TIMEOUT=}" ;;
        *) die "unknown arg: $arg" ;;
    esac
done
ARCH="${ARCH:-riscv64}"

case "$ARCH" in
    riscv64)
        ROOTFS_URL="https://github.com/Starry-OS/rootfs/releases/download/20260214/rootfs-riscv64.img.xz"
        RUST_TARGET=riscv64gc-unknown-none-elf
        PLAT_NAME=riscv64-qemu-virt
        ;;
    x86_64)
        ROOTFS_URL="https://github.com/Starry-OS/rootfs/releases/download/20260214/rootfs-x86_64.img.xz"
        RUST_TARGET=x86_64-unknown-none
        PLAT_NAME=x86-pc
        ;;
    *) die "unsupported ARCH=$ARCH" ;;
esac

KERNEL_ELF="$TGOSKITS/target/$RUST_TARGET/release/starryos"
[[ -f "$KERNEL_ELF" ]] || die "kernel ELF missing: $KERNEL_ELF (run scripts/integration-build.sh first)"

TESTS_OUT="$ROOT/tests/selfhost/out-$ARCH"
[[ -d "$TESTS_OUT" ]] || die "tests not built: $TESTS_OUT (run 'make ARCH=$ARCH' under tests/selfhost first)"

# 1. 准备一个工作目录
WORK="$ROOT/.guest-runs/$ARCH"
mkdir -p "$WORK"
ROOTFS_RAW="$WORK/rootfs.img"
ROOTFS_XZ="$WORK/rootfs.img.xz"

if [[ ! -f "$ROOTFS_RAW" ]]; then
    log "downloading rootfs ($ROOTFS_URL)..."
    curl -fL "$ROOTFS_URL" -o "$ROOTFS_XZ"
    xz -dk "$ROOTFS_XZ" -c > "$ROOTFS_RAW"
fi

# 2. 把 tests + run-tests.sh 注入 rootfs（mount loop）
log "mounting rootfs and injecting tests..."
MNT="$WORK/mnt"
mkdir -p "$MNT"
sudo mount -o loop "$ROOTFS_RAW" "$MNT"
trap 'sudo umount "$MNT" 2>/dev/null; true' EXIT

sudo mkdir -p "$MNT/opt/selfhost-tests"
# 拷 test 二进制
sudo cp "$TESTS_OUT"/test_* "$MNT/opt/selfhost-tests/"
sudo chmod +x "$MNT/opt/selfhost-tests/"*

# 写 run-tests.sh
cat > "$WORK/run-tests.sh" << 'EOF'
#!/bin/sh
# Self-host Phase 1 test runner (runs inside guest BusyBox).
echo "===SELFHOST-TEST-RUN-START==="
TOTAL=0
PASS=0
FAIL=0
SKIP=0
for t in /opt/selfhost-tests/test_*; do
    TOTAL=$((TOTAL+1))
    name="${t##*/}"
    out="$(timeout 30 "$t" 2>&1)"
    rc=$?
    echo "$out" | grep -E '^\[TEST\]' || echo "[TEST] $name FAIL: no [TEST] line (rc=$rc)"
    case "$out" in
        *"PASS (SKIP"*|*"PASS (skipped"*) SKIP=$((SKIP+1)) ;;
        *"PASS"*) PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)) ;;
    esac
done
echo "===SELFHOST-TEST-RUN-END==="
echo "===SELFHOST-SUMMARY total=$TOTAL pass=$PASS fail=$FAIL skip=$SKIP==="
EOF
sudo cp "$WORK/run-tests.sh" "$MNT/opt/run-tests.sh"
sudo chmod +x "$MNT/opt/run-tests.sh"

sudo umount "$MNT"
trap - EXIT

# 3. 启动 QEMU 在后台
LOG="$WORK/qemu.log"
log "starting QEMU (log: $LOG)..."
bash "$SCRIPT_DIR/qemu-run-kernel.sh" \
    ARCH="$ARCH" KERNEL="$KERNEL_ELF" DISK="$ROOTFS_RAW" TIMEOUT="$TIMEOUT" \
    > "$LOG" 2>&1 &
QEMU_PID=$!

cleanup() {
    kill -KILL "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

# 4. 等 4444 端口就绪
log "waiting for QEMU serial..."
for i in $(seq 1 30); do
    sleep 1
    if (echo > /dev/tcp/localhost/4444) 2>/dev/null; then
        log "QEMU serial ready"
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log "QEMU exited early; see $LOG"
        tail -50 "$LOG"
        exit 1
    fi
done

# 5. 用 python 接进去，等 prompt → 发命令 → 收集结果
RESULT="$WORK/results.txt"
python3 << PY > "$RESULT" 2>&1
import socket, re, sys, time
PROMPT = "starry:~#"
TIMEOUT_TOTAL = $TIMEOUT
START = time.monotonic()

s = socket.create_connection(("localhost", 4444), timeout=10)
s.settimeout(5)
buf = ""
sent_run = False
sent_exit = False
seen_summary = False
while True:
    if time.monotonic() - START > TIMEOUT_TOTAL:
        print("===TIMEOUT===")
        break
    try:
        b = s.recv(4096).decode("utf-8", errors="ignore")
    except socket.timeout:
        continue
    except Exception as e:
        print(f"===CONN ERROR: {e}===")
        break
    if not b:
        break
    sys.stdout.write(b); sys.stdout.flush()
    buf += b
    if PROMPT in buf and not sent_run:
        s.sendall(b"sh /opt/run-tests.sh\n")
        sent_run = True
    if "===SELFHOST-SUMMARY" in buf and not seen_summary:
        seen_summary = True
        s.sendall(b"exit\n")
        sent_exit = True
        # 再读一会让 exit 行刷出来
        time.sleep(2)
        break
PY

# 6. 汇总
echo
log "===== SUMMARY ====="
grep -E '^\[TEST\]' "$RESULT" | sort | tail -50 || true
echo
grep "===SELFHOST-SUMMARY" "$RESULT" || echo "WARN: no summary line found"
echo
log "full output: $RESULT"
log "qemu log: $LOG"
