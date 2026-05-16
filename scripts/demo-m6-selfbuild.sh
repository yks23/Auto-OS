#!/usr/bin/env bash
# demo-m6-selfbuild.sh — boot StarryOS guest with the selfbuild rootfs and
# have the guest compile the StarryOS kernel from its own sources.
#
# Lite vs full:
#   Full (default flags): QEMU smp=4 mem=5G timeout 4200s; guest runs full starry kernel selfbuild.
#   Low-resource subset: `bash scripts/demo-m6-lite.sh` → `--subset` + smp=1 mem=3G timeout 3600s
#   (overridable via env). Or manually: same env + `demo-m6-selfbuild.sh --subset`.
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
#         .guest-runs/riscv64-m6/m6-progress.log — 宿主心跳 CSV（另一终端 tail -f）
#         exits 0 iff the guest log contains "===M6-SELFBUILD-PASS==="
#         (or the lib-only marker — which still proves starry-kernel itself
#          was successfully compiled inside the guest)
#
# 长时 / 可恢复（resume）：
#   使用**同一** ROOTFS 镜像多次运行；超时或手动 kill QEMU 后，盘上 /opt/tgoskits/target 可能已有
#   增量产物。设 M6_RESUME=1 再跑 demo：访客脚本会跳过已完成的 cargo 阶段，并维护
#   /opt/tgoskits/.m6-done-{kernel-lib,pass1,pass2}（见 tests/selfhost/build-selfbuild-rootfs.sh GUESTSH）。
#   勿换副本镜像，否则 target/ 丢失需从头编。
#
# Env:
#   M6_QEMU_TIMEOUT_SEC — outer timeout(1) for qemu（默认 4200）
#   M6_STALL_SEC — results.txt 字节数连续多久**完全不变**则判死锁/假死并杀 QEMU。
#     默认 **0**（关闭）：多进程 rustc 下串口可能长时间无新字节，易误杀；需要时再设正数。
#   M6_HOST_HEARTBEAT_SEC — 宿主轮询时向 stderr 打印进度间隔秒数（快速反馈默认 60）
#   M6_GUEST_HEARTBEAT_SEC — 注入访客：cargo 静默阶段串口心跳间隔秒数（快速反馈默认 60；写入 /opt/run-tests.sh）
#   M6_SYSCALL_STATS_INTERVAL_SEC — 访客内 syscall_stats dump 间隔秒数（默认 60；与宿主 m6-selfbuild-progress-http.py 对齐）
#   M6_SKIP_SYNC_GUESTSH=1 — 不从仓库覆盖镜像内 /opt/build-starry-kernel.sh（默认每次 demo 同步 GUESTSH）
#   M6_RESUME=1 — 访客内根据盘上 target/（rlib、linker_*.lds、ELF）与 touch 的
#     /opt/tgoskits/.m6-done-{kernel-lib,pass1,pass2} 跳过已完成阶段（须同一 ROOTFS 可写）
#   M6_PROGRESS_LOG=path — 覆盖默认 .guest-runs/riscv64-m6/m6-progress.log
#   M6_FAST_FEEDBACK=1 — 默认：续跑、少日志、低 debuginfo、较低 syscall dump 频率；设 0 回到详细诊断模式
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
M6_STALL_SEC="${M6_STALL_SEC:-0}"
M6_STALL_GRACE_SEC="${M6_STALL_GRACE_SEC:-120}"
# -smp 1 avoids QEMU TCG LR/SC cross-hart race without needing thread=single serialization.
# The kernel handles runtime CPU detection, so booting with fewer harts is safe.
M6_QEMU_SMP="${M6_QEMU_SMP:-1}"
M6_QEMU_MEM="${M6_QEMU_MEM:-5G}"
M6_FAST_FEEDBACK="${M6_FAST_FEEDBACK:-1}"
if [[ "$M6_FAST_FEEDBACK" == "1" ]]; then
    M6_RESUME="${M6_RESUME:-1}"
    M6_CARGO_VV="${M6_CARGO_VV:-0}"
    M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON:--C debuginfo=0}"
    M6_HOST_HEARTBEAT_SEC="${M6_HOST_HEARTBEAT_SEC:-60}"
    M6_GUEST_HEARTBEAT_SEC="${M6_GUEST_HEARTBEAT_SEC:-60}"
    M6_SYSCALL_STATS_INTERVAL_SEC="${M6_SYSCALL_STATS_INTERVAL_SEC:-60}"
else
    M6_RESUME="${M6_RESUME:-0}"
    M6_CARGO_VV="${M6_CARGO_VV:-1}"
    M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON:--C debuginfo=2}"
    M6_HOST_HEARTBEAT_SEC="${M6_HOST_HEARTBEAT_SEC:-120}"
    M6_GUEST_HEARTBEAT_SEC="${M6_GUEST_HEARTBEAT_SEC:-120}"
    M6_SYSCALL_STATS_INTERVAL_SEC="${M6_SYSCALL_STATS_INTERVAL_SEC:-10}"
fi

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
    # QEMU TCG LR/SC is broken under MTTCG.  Only need thread=single when SMP > 1.
    local _accel=()
    if [[ "$M6_QEMU_SMP" -gt 1 ]]; then
        _accel=(-accel tcg,thread=single)
    fi
    $SUDO timeout 240 qemu-system-riscv64 \
        -nographic -machine virt -bios default -smp "$M6_QEMU_SMP" -m "$M6_QEMU_MEM" \
        "${_accel[@]}" \
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
# Replace guest-onecrate-inner.sh with a delegate to run-tests.sh so kernel
# init.sh takes the direct exec path (instead of interactive shell which panics).
$SUDO tee /tmp/rfsmnt-m6/opt/guest-onecrate-inner.sh > /dev/null <<'GOCDELEGATE'
#!/bin/bash
exec /bin/bash --noprofile --norc /opt/run-tests.sh
GOCDELEGATE
$SUDO chmod +x /tmp/rfsmnt-m6/opt/guest-onecrate-inner.sh
# Clear one-crate env vars that would confuse build-starry-kernel.sh
$SUDO rm -f /tmp/rfsmnt-m6/opt/guest-onecrate-env.sh
# Replace libscudo.so with musl symlink — crashes under QEMU TCG
if [[ -f "/tmp/rfsmnt-m6/opt/alpine-rust/usr/lib/libscudo.so" && ! -L "/tmp/rfsmnt-m6/opt/alpine-rust/usr/lib/libscudo.so" ]]; then
    $SUDO rm -f /tmp/rfsmnt-m6/opt/alpine-rust/usr/lib/libscudo.so
    $SUDO ln -sf /lib/libc.musl-riscv64.so.1 /tmp/rfsmnt-m6/opt/alpine-rust/usr/lib/libscudo.so
fi
# 与镜像 bake 时脚本保持一致：每次 demo 从 build-selfbuild-rootfs.sh 抽出 GUESTSH，避免只改仓库未改盘。
SELFBUILD_SH="$ROOT/tests/selfhost/build-selfbuild-rootfs.sh"
if [[ "${M6_SKIP_SYNC_GUESTSH:-}" != "1" && -f "$SELFBUILD_SH" ]]; then
    echo "[+] sync /opt/build-starry-kernel.sh from repo GUESTSH ($SELFBUILD_SH)"
    _guestsh_tmp=$(mktemp)
    awk "/<<'GUESTSH'/{p=1;next} /^GUESTSH\$/{exit} p" "$SELFBUILD_SH" >"$_guestsh_tmp"
    bash -n "$_guestsh_tmp"
    for needle in 'AX_CONFIG_PATH' 'CARGO_INCREMENTAL=0' 'RUSTC_BOOTSTRAP=1' 'M6-SELFBUILD-PASS'; do
        grep -qF "$needle" "$_guestsh_tmp" || {
            echo "GUESTSH extraction missing expected line: $needle" >&2
            rm -f "$_guestsh_tmp"
            exit 1
        }
    done
    $SUDO cp "$_guestsh_tmp" /tmp/rfsmnt-m6/opt/build-starry-kernel.sh
    rm -f "$_guestsh_tmp"
    $SUDO chmod +x /tmp/rfsmnt-m6/opt/build-starry-kernel.sh
elif [[ "${M6_SKIP_SYNC_GUESTSH:-}" == "1" ]]; then
    echo "[+] M6_SKIP_SYNC_GUESTSH=1 — using existing /opt/build-starry-kernel.sh on disk"
fi
AXCFG=/tmp/rfsmnt-m6/opt/tgoskits/os/StarryOS/.axconfig.toml
if [[ -f "$AXCFG" ]] && ! $SUDO grep -qE '^[[:space:]]*task-stack-size[[:space:]]*=' "$AXCFG"; then
    echo "[+] patch baked .axconfig.toml: add missing task-stack-size"
    _tmpcfg=$(mktemp)
    {
        echo '# Stack size of each task.'
        echo 'task-stack-size = 0x40000 # uint'
        $SUDO cat "$AXCFG"
    } > "$_tmpcfg"
    $SUDO cp "$_tmpcfg" "$AXCFG"
    rm -f "$_tmpcfg"
fi
if [[ "$BOOT_SUBSET" -eq 1 ]]; then
    $SUDO tee /tmp/rfsmnt-m6/opt/run-tests.sh > /dev/null <<EOF
#!/bin/sh
export M6_GUEST_HEARTBEAT_SEC="${M6_GUEST_HEARTBEAT_SEC}"
export M6_SYSCALL_STATS_INTERVAL_SEC="${M6_SYSCALL_STATS_INTERVAL_SEC}"
export M6_CARGO_VV="${M6_CARGO_VV}"
export M6_CARGO_PTY="${M6_CARGO_PTY:-0}"
export M6_RESUME="${M6_RESUME}"
export M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON}"
export CARGO_TERM_PROGRESS="${CARGO_TERM_PROGRESS:-wide}"
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-true}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-}"
export M6_MODE=subset
exec /bin/bash --noprofile --norc /opt/build-starry-kernel.sh
EOF
else
    $SUDO tee /tmp/rfsmnt-m6/opt/run-tests.sh > /dev/null <<EOF
#!/bin/sh
export M6_GUEST_HEARTBEAT_SEC="${M6_GUEST_HEARTBEAT_SEC}"
export M6_SYSCALL_STATS_INTERVAL_SEC="${M6_SYSCALL_STATS_INTERVAL_SEC}"
export M6_CARGO_VV="${M6_CARGO_VV}"
export M6_CARGO_PTY="${M6_CARGO_PTY:-0}"
export M6_RESUME="${M6_RESUME}"
export M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON}"
export CARGO_TERM_PROGRESS="${CARGO_TERM_PROGRESS:-wide}"
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-true}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-}"
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
c++|g++) exec /opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-g++ "$@" ;;
*) exec /opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-gcc "$@" ;;
esac
CCWRAP
$SUDO chmod +x /tmp/rfsmnt-m6/opt/ccwrap/cc
# rustc wrapper: inject -Z threads=0 to prevent vec_cache.rs:201 ICE under QEMU TCG.
# RUSTC_BOOTSTRAP=1 enables -Z on stable rustc. Set M6_NO_SERIAL_RUSTC=1 to disable.
if [[ "${M6_NO_SERIAL_RUSTC:-}" != "1" ]]; then
    $SUDO tee /tmp/rfsmnt-m6/opt/ccwrap/rustc > /dev/null <<'RUSTWRAP'
#!/bin/sh
exec env RUSTC_BOOTSTRAP=1 /opt/alpine-rust/usr/bin/rustc -Z threads=0 "$@"
RUSTWRAP
    $SUDO chmod +x /tmp/rfsmnt-m6/opt/ccwrap/rustc
fi
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
M6_PROGRESS_LOG="${M6_PROGRESS_LOG:-$WORK/m6-progress.log}"
rm -f "$RESULT" "$WORK/.m6-stalled"
# 宿主可读进度（另一终端 tail -f）；长时任务勿删此文件以便对照。
echo "# utc_iso elapsed_s log_bytes log_lines last_signal" >"$M6_PROGRESS_LOG"
echo "[+] progress log: $M6_PROGRESS_LOG  (tail -f in another terminal)"

# ---------- boot QEMU. Generous memory (3 GB) and configurable timeout because
# guest cargo build of starry-kernel via emulated RISC-V is genuinely slow.
echo "[+] launching qemu (timeout ${M6_QEMU_TIMEOUT_SEC}s — guest cargo build)..."
echo "[+] diag: M6_FAST_FEEDBACK=$M6_FAST_FEEDBACK M6_QEMU_SMP=$M6_QEMU_SMP M6_QEMU_MEM=$M6_QEMU_MEM M6_STALL_SEC=$M6_STALL_SEC M6_HOST_HEARTBEAT_SEC=$M6_HOST_HEARTBEAT_SEC M6_GUEST_HEARTBEAT_SEC=$M6_GUEST_HEARTBEAT_SEC M6_SYSCALL_STATS_INTERVAL_SEC=$M6_SYSCALL_STATS_INTERVAL_SEC M6_RESUME=$M6_RESUME M6_CARGO_VV=$M6_CARGO_VV M6_RUSTFLAGS_COMMON='$M6_RUSTFLAGS_COMMON'"
# -smp 须 ≤ 镜像内 .axconfig.toml 的 plat.max-cpu-num（见 tests/selfhost/build-selfbuild-rootfs.sh / scripts/build.sh）。
# QEMU TCG LR/SC is broken under MTTCG: SC uses cmpxchg(value) instead of
# reservation tracking, causing spurious SC success across harts.  With -smp 1
# the race cannot happen, so we only need thread=single when SMP > 1.
_accel=()
if [[ "$M6_QEMU_SMP" -gt 1 ]]; then
    _accel=(-accel tcg,thread=single)
fi
$SUDO timeout "$M6_QEMU_TIMEOUT_SEC" qemu-system-riscv64 \
    -nographic -machine virt -bios default -smp "$M6_QEMU_SMP" -m "$M6_QEMU_MEM" \
    "${_accel[@]}" \
    -kernel "$KERNEL" -cpu rv64 \
    -monitor none -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file="$ROOTFS",file.locking=off \
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
    if (( EL >= LAST_HB_EL + M6_HOST_HEARTBEAT_SEC )); then
        LAST_HB_EL=$EL
        _lines=$(wc -l < "$RESULT" 2>/dev/null || echo 0)
        printf "[host heartbeat] %ss elapsed, log_bytes=%s lines=%s qemu_alive=yes (M6_HOST_HEARTBEAT_SEC=%s)\n" \
            "$EL" "$bytes" "$_lines" "${M6_HOST_HEARTBEAT_SEC}" >&2
        _sig=$(strings "$RESULT" 2>/dev/null | grep -iE '\[M6 |SELFBUILD|^\s*Compiling |^\s*Finished |^error:|panic' | tail -1 | tr '\r\n' '  ' | cut -c1-200 || true)
        if [[ -n "$_sig" ]]; then
            printf '[host heartbeat] last_phase_line: %s\n' "$_sig" >&2
        fi
        printf '%s %s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EL" "$bytes" "$_lines" "$_sig" >>"$M6_PROGRESS_LOG"
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
