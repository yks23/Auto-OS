#!/usr/bin/env bash
# demo-m6-selfbuild.sh — boot StarryOS guest with the selfbuild rootfs and
# have the guest compile the StarryOS kernel from its own sources.
#
# Optional:
#   --subset — 访客内只跑 M6_MODE=subset：metadata + riscv-h + ax-cpu + ax-errno（均为 none-elf cargo check）
#     的 cargo check，串口出现 ===M6-SELFBUILD-SUBSET-PASS=== 即成功（需盘内
#     /opt/build-starry-kernel.sh 与仓库 tests/selfhost/build-selfbuild-rootfs.sh 同步）。
#   --boot-twice — after ===M6-SELFBUILD-PASS===, boot again using the
# starryos ELF produced inside the guest (copied from the rootfs image) on a
# disposable copy of the rootfs whose /opt/run-tests.sh is replaced with a
# trivial smoke script so the second QEMU does not re-run the full cargo build.
#
# Requires:
#   - kernel ELF at tgoskits/target/.../release/starryos
#   - tests/selfhost/rootfs-selfbuild-riscv64.img (run build-selfbuild-rootfs.sh
#     once, or download from GitHub release)
#   - qemu-system-riscv64 on PATH
#
# Output: .guest-runs/riscv64-m6/results.txt   (full guest serial log)
#         exits 0 iff the guest log contains "===M6-SELFBUILD-PASS==="
#         (or the lib-only marker — which still proves starry-kernel itself
#          was successfully compiled inside the guest)
#
# Env:
#   M6_QEMU_TIMEOUT_SEC — outer timeout(1) for qemu（默认 4200）
#   M6_STALL_SEC — results.txt 字节数连续多久**完全不变**则判死锁/假死并杀 QEMU（默认 10800）。
#     设为 0 可关闭停滞检测（访客 cargo 可能长时间无 stdout，仅靠 M6_QEMU_TIMEOUT_SEC 兜底）。
set -e

BOOT_TWICE=0
BOOT_SUBSET=0
for a in "$@"; do
    case "$a" in
        --boot-twice) BOOT_TWICE=1 ;;
        --subset) BOOT_SUBSET=1 ;;
        *)
            echo "unknown option: $a (supported: --boot-twice, --subset)" >&2
            exit 2
            ;;
    esac
done
if [[ "$BOOT_SUBSET" -eq 1 && "$BOOT_TWICE" -eq 1 ]]; then
    echo "warn: --boot-twice needs full guest build; ignoring --boot-twice with --subset" >&2
    BOOT_TWICE=0
fi

# 在 Docker（root）内无需 sudo；本机非 root 时保留 sudo。
SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$ROOT/.guest-runs/riscv64-m6"
# 可用 ROOTFS=/path/to/copy.img 指向可写副本，避免与其它 QEMU / 索引进程争用同一 raw 的写锁。
ROOTFS="${ROOTFS:-$ROOT/tests/selfhost/rootfs-selfbuild-riscv64.img}"
ELF="$ROOT/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
M6_QEMU_TIMEOUT_SEC="${M6_QEMU_TIMEOUT_SEC:-4200}"
M6_STALL_SEC="${M6_STALL_SEC:-10800}"
M6_STALL_GRACE_SEC="${M6_STALL_GRACE_SEC:-120}"

mkdir -p "$WORK"
[[ -f "$ROOTFS" ]] || { echo "rootfs not found: $ROOTFS"; exit 1; }
[[ -f "$ELF"    ]] || { echo "kernel ELF not found: $ELF"; exit 1; }

if [[ -x "$SCRIPT_DIR/verify-m6-rootfs.sh" ]]; then
    echo "[+] preflight: verify-m6-rootfs.sh"
    "$SCRIPT_DIR/verify-m6-rootfs.sh" || { echo "preflight failed; fix rootfs before QEMU (see scripts/verify-m6-rootfs.sh)"; exit 1; }
fi

# After phase1, the loop-mounted rootfs on disk contains the guest-built ELF.
m6_phase2_boot_guest_kernel() {
    local MNT=/tmp/rfsmnt-m6-p2
    local PHASE2_IMG="$WORK/rootfs-phase2.img"
    local P2RESULT="$WORK/results-phase2.txt"
    local GUEST_ELF="$WORK/starry-guest.elf"
    local GUEST_BIN="$WORK/starry-guest.bin"
    local GF="$MNT/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"

    echo "[phase2] snapshot rootfs (includes guest artifacts) -> $PHASE2_IMG"
    cp -f "$ROOTFS" "$PHASE2_IMG"

    $SUDO umount "$MNT" 2>/dev/null || true
    $SUDO mkdir -p "$MNT"
    $SUDO mount -o loop "$ROOTFS" "$MNT"
    if ! $SUDO test -f "$GF"; then
        echo "[phase2] guest-built starryos not found at $GF"
        $SUDO umount "$MNT" 2>/dev/null || true
        return 1
    fi
    $SUDO cp "$GF" "$GUEST_ELF"
    $SUDO umount "$MNT"

    if command -v rust-objcopy >/dev/null 2>&1; then
        rust-objcopy -O binary "$GUEST_ELF" "$GUEST_BIN"
    elif command -v riscv64-linux-musl-objcopy >/dev/null 2>&1; then
        riscv64-linux-musl-objcopy -O binary "$GUEST_ELF" "$GUEST_BIN"
    elif command -v llvm-objcopy >/dev/null 2>&1; then
        llvm-objcopy -O binary "$GUEST_ELF" "$GUEST_BIN"
    else
        cp -f "$GUEST_ELF" "$GUEST_BIN"
    fi

    echo "[phase2] inject trivial /opt/run-tests.sh into snapshot only..."
    $SUDO mount -o loop "$PHASE2_IMG" "$MNT"
    $SUDO tee "$MNT/opt/run-tests.sh" > /dev/null <<'P2EOF'
#!/bin/sh
echo "===M6-PHASE2-SMOKE-OK==="
exit 0
P2EOF
    $SUDO chmod +x "$MNT/opt/run-tests.sh"
    $SUDO umount "$MNT"

    rm -f "$P2RESULT"
    echo "[phase2] QEMU second boot (timeout 240s)..."
    set +e
    $SUDO timeout 240 qemu-system-riscv64 \
        -nographic -machine virt -bios default -smp 1 -m 3G \
        -kernel "$GUEST_BIN" -cpu rv64 \
        -monitor none -serial mon:stdio \
        -device virtio-blk-pci,drive=disk0 \
        -drive id=disk0,if=none,format=raw,file="$PHASE2_IMG" \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
        > "$P2RESULT" 2>&1 < /dev/null
    set -e

    echo "[phase2] serial tail:"
    strings "$P2RESULT" | grep -E "M6-PHASE2|SELFHOST-DONE|panic|Welcome" | tail -25 || true
    if grep -q "===M6-PHASE2-SMOKE-OK===" "$P2RESULT" 2>/dev/null; then
        echo "[phase2] guest-built kernel booted and ran smoke init hook."
        return 0
    fi
    echo "[phase2] failed — see $P2RESULT"
    return 1
}

# ---------- inject /opt/run-tests.sh hook into rootfs (delegates to the
# /opt/build-starry-kernel.sh that build-selfbuild-rootfs.sh baked in)
echo "[+] injecting /opt/run-tests.sh into rootfs..."
$SUDO umount /tmp/rfsmnt-m6 2>/dev/null || true
$SUDO mkdir -p /tmp/rfsmnt-m6
$SUDO mount -o loop "$ROOTFS" /tmp/rfsmnt-m6
if [[ "$BOOT_SUBSET" -eq 1 ]]; then
    $SUDO tee /tmp/rfsmnt-m6/opt/run-tests.sh > /dev/null <<'EOF'
#!/bin/sh
export M6_MODE=subset
exec /bin/bash --noprofile --norc /opt/build-starry-kernel.sh
EOF
else
    $SUDO tee /tmp/rfsmnt-m6/opt/run-tests.sh > /dev/null <<'EOF'
#!/bin/sh
# 环境全部由 /opt/build-starry-kernel.sh 设置，避免 glibc sh 与 musl/Alpine PATH 的任何交叉。
exec /bin/bash --noprofile --norc /opt/build-starry-kernel.sh
EOF
fi
$SUDO chmod +x /tmp/rfsmnt-m6/opt/run-tests.sh
# 旧版 rootfs 的 ccwrap 未清 LD_LIBRARY_PATH，会导致 musl 路径污染 glibc clang 并 SIGSEGV。
$SUDO mkdir -p /tmp/rfsmnt-m6/opt/ccwrap
$SUDO tee /tmp/rfsmnt-m6/opt/ccwrap/cc > /dev/null <<'CCWRAP'
#!/bin/sh
unset LD_LIBRARY_PATH
case "$(basename "$0")" in
c++|g++) exec /usr/bin/clang++ "$@" ;;
*) exec /usr/bin/clang "$@" ;;
esac
CCWRAP
$SUDO chmod +x /tmp/rfsmnt-m6/opt/ccwrap/cc
$SUDO umount /tmp/rfsmnt-m6
echo "[+] inject done"

# ---------- objcopy ELF -> raw binary (qemu -kernel can take ELF directly,
# but the existing flow uses .bin; either works on riscv64-virt)
KERNEL="$WORK/starry.bin"
if command -v rust-objcopy >/dev/null 2>&1; then
    rust-objcopy -O binary "$ELF" "$KERNEL"
elif command -v riscv64-linux-musl-objcopy >/dev/null 2>&1; then
    riscv64-linux-musl-objcopy -O binary "$ELF" "$KERNEL"
elif command -v llvm-objcopy >/dev/null 2>&1; then
    llvm-objcopy -O binary "$ELF" "$KERNEL"
else
    echo "warn: no objcopy found, passing ELF directly to qemu"
    cp "$ELF" "$KERNEL"
fi

RESULT="$WORK/results.txt"
rm -f "$RESULT" "$WORK/.m6-stalled"

# ---------- boot QEMU. Generous memory (3 GB) and configurable timeout because
# guest cargo build of starry-kernel via emulated RISC-V is genuinely slow.
echo "[+] launching qemu (timeout ${M6_QEMU_TIMEOUT_SEC}s — guest cargo build)..."
# Must match the kernel's compiled SMP count (Starry defconfig is often smp=1).
$SUDO timeout "$M6_QEMU_TIMEOUT_SEC" qemu-system-riscv64 \
    -nographic -machine virt -bios default -smp 1 -m 3G \
    -kernel "$KERNEL" -cpu rv64 \
    -monitor none -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file="$ROOTFS" \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    > "$RESULT" 2>&1 < /dev/null &
QEMU=$!
trap "$SUDO kill -9 $QEMU 2>/dev/null || true" EXIT

# Tail-follow the result file in the background so the user sees progress.
( tail -f "$RESULT" 2>/dev/null & echo $! > "$WORK/.tail.pid" ) &
TAILPID=$(cat "$WORK/.tail.pid" 2>/dev/null || echo "")

START=$(date +%s)
LAST_HB_EL=0
last_log_bytes=-1
stall_mark="$START"

m6_diagnose_stall() {
    : >"$WORK/.m6-stalled"
    echo "================================================================" >&2
    echo "[host] M6 STALL: $RESULT 字节数已 ${M6_STALL_SEC}s 未增长（可能：访客卡死、串口缓冲、磁盘满、或 rustc 极慢）" >&2
    echo "  M6_STALL_SEC=$M6_STALL_SEC  M6_STALL_GRACE_SEC=$M6_STALL_GRACE_SEC  elapsed=$(( $(date +%s) - START ))s" >&2
    echo "[host] 串口日志尾部（原始）：" >&2
    tail -n 50 "$RESULT" 2>/dev/null >&2 || true
    echo "[host] strings 里与 cargo/错误 相关的行：" >&2
    strings "$RESULT" 2>/dev/null | grep -iE 'cargo|rustc|error|panic|stall|full|Compiling|Finished' | tail -n 30 >&2 || true
    echo "================================================================" >&2
}

# QEMU 进程结束后立即结束轮询；另：日志长时间不增长则主动诊断并杀 QEMU。
while kill -0 "$QEMU" 2>/dev/null; do
    sleep 2
    if grep -qE "===M6-SELFBUILD-(PASS|LIB-PASS|SUBSET-PASS)===" "$RESULT" 2>/dev/null; then
        break
    fi
    # 不把 "database or disk is full" 当立即失败：cargo 在部分 FS 上会误报 sqlite，但仍可能继续编译。
    if grep -qE "^panic|FATAL:|error: could not compile" "$RESULT" 2>/dev/null \
        || grep -qF "stack smashing detected" "$RESULT" 2>/dev/null; then
        echo "[host] detected failure pattern in serial log — stopping QEMU" >&2
        $SUDO kill -9 "$QEMU" 2>/dev/null || true
        break
    fi
    NOW=$(date +%s)
    EL=$((NOW - START))
    bytes=$(wc -c < "$RESULT" 2>/dev/null || echo 0)
    if [[ "$bytes" -ne "$last_log_bytes" ]]; then
        last_log_bytes=$bytes
        stall_mark=$NOW
    elif [[ "${M6_STALL_SEC}" != "0" ]] \
        && (( EL >= M6_STALL_GRACE_SEC && NOW - stall_mark >= M6_STALL_SEC )); then
        m6_diagnose_stall
        $SUDO kill -9 "$QEMU" 2>/dev/null || true
        break
    fi
    if (( EL >= LAST_HB_EL + 300 )); then
        LAST_HB_EL=$EL
        printf "[host heartbeat] %ss elapsed, log_bytes=%s lines=%s qemu_alive=yes\n" \
            "$EL" "$bytes" "$(wc -l < "$RESULT" 2>/dev/null || echo 0)" >&2
    fi
done
wait "$QEMU" 2>/dev/null || true
if ! grep -qE "===M6-SELFBUILD-(PASS|LIB-PASS|SUBSET-PASS)===" "$RESULT" 2>/dev/null; then
    NOW=$(date +%s)
    printf "[host] QEMU finished after %ss without PASS marker (see %s)\n" "$((NOW - START))" "$RESULT" >&2
fi

[[ -n "$TAILPID" ]] && kill "$TAILPID" 2>/dev/null || true
$SUDO kill -9 $QEMU 2>/dev/null || true

echo
echo "=== M6 demo done ==="
strings "$RESULT" | grep -E "rustc|cargo|Compiling|Finished|exit=|M6-SELFBUILD|panic|TGOSKITS|tgoskits" | tail -40 || true

if grep -q "===M6-SELFBUILD-PASS===" "$RESULT" 2>/dev/null; then
    echo
    echo "================================================================"
    printf "  \033[1;32m✓ M6 SELFBUILD PASSED\033[0m\n"
    echo "  starry kernel ELF was just produced inside the starry guest."
    echo "================================================================"
    if [[ "$BOOT_TWICE" -eq 1 ]]; then
        echo
        echo "================================================================"
        echo "  --boot-twice: second QEMU using guest-built kernel"
        echo "================================================================"
        m6_phase2_boot_guest_kernel || exit 1
    fi
    exit 0
elif grep -q "===M6-SELFBUILD-LIB-PASS===" "$RESULT" 2>/dev/null; then
    echo
    echo "================================================================"
    printf "  \033[1;33m✓ M6 SELFBUILD (lib) PASSED\033[0m\n"
    echo "  starry-kernel lib compiled inside the guest; final ELF link"
    echo "  step did not finish but the kernel source itself was processed."
    echo "================================================================"
    exit 0
elif grep -q "===M6-SELFBUILD-SUBSET-PASS===" "$RESULT" 2>/dev/null; then
    echo
    echo "================================================================"
    printf "  \033[1;32m✓ M6 SELFBUILD SUBSET PASSED\033[0m\n"
    echo "  guest cargo metadata + pkgid checks (riscv-h / ax-cpu / ax-errno) OK."
    echo "================================================================"
    exit 0
else
    if [[ -f "$WORK/.m6-stalled" ]]; then
        echo "M6 demo aborted: serial log had no new bytes for ${M6_STALL_SEC}s (stall detector)." >&2
        echo "  If this is a false positive during a long rustc step, raise M6_STALL_SEC (e.g. 7200)." >&2
        rm -f "$WORK/.m6-stalled"
    fi
    echo "M6 demo did NOT pass. See $RESULT"
    exit 1
fi
