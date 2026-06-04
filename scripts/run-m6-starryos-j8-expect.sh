#!/usr/bin/env bash
# Run the real StarryOS M6 self-build inside a StarryOS guest with cargo -j8.
# This avoids Docker and loop-mount injection: QEMU boots to the guest shell,
# then this script writes a tiny runner over the serial console and executes
# /opt/build-starry-kernel.sh already present in the rootfs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

QEMU="${QEMU:-}"
if [[ -z "$QEMU" ]]; then
    if command -v qemu-system-riscv64 >/dev/null 2>&1; then
        QEMU="$(command -v qemu-system-riscv64)"
    elif [[ -x /opt/homebrew/bin/qemu-system-riscv64 ]]; then
        QEMU=/opt/homebrew/bin/qemu-system-riscv64
    else
        echo "error: qemu-system-riscv64 not found" >&2
        exit 127
    fi
fi

KERNEL="${M6_KERNEL_BIN:-$ROOT/.guest-runs/riscv64-m6/starry-smp8-trackcaller-20260522.bin}"
ROOTFS="${ROOTFS:-$ROOT/.guest-runs/rootfs-selfbuild-riscv64.img}"
LOG="${M6_LOG:-$ROOT/showtime/multi-cpu/logs/m6-full-smp8-mttcg-j8-expect-$(date +%Y%m%dT%H%M%S).log}"
M6_QEMU_SMP="${M6_QEMU_SMP:-8}"
M6_TCG_THREAD="${M6_TCG_THREAD:-multi}"
M6_QEMU_MEM="${M6_QEMU_MEM:-4G}"
M6_QEMU_TIMEOUT_SEC="${M6_QEMU_TIMEOUT_SEC:-28800}"
M6_PANIC_GRACE_MS="${M6_PANIC_GRACE_MS:-8000}"
M6_DRIVE_SNAPSHOT="${M6_DRIVE_SNAPSHOT:-on}"
M6_DRIVE_FORMAT="${M6_DRIVE_FORMAT:-raw}"
M6_STOP_ON_PANIC="${M6_STOP_ON_PANIC:-1}"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"
RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-8}"
M6_GUEST_HEARTBEAT_SEC="${M6_GUEST_HEARTBEAT_SEC:-60}"
M6_PROCESS_HEARTBEAT_SEC="${M6_PROCESS_HEARTBEAT_SEC:-30}"
M6_SYSCALL_STATS_INTERVAL_SEC="${M6_SYSCALL_STATS_INTERVAL_SEC:-120}"
M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON:--C debuginfo=0}"
M6_CARGO_VV="${M6_CARGO_VV:-0}"
M6_RESUME="${M6_RESUME:-1}"
M6_USE_TMPFS_WORK="${M6_USE_TMPFS_WORK:-1}"
M6_COPY_TOOLCHAIN_EXEC="${M6_COPY_TOOLCHAIN_EXEC:-0}"
M6_WORK_TMPFS_SIZE="${M6_WORK_TMPFS_SIZE:-3584m}"

case "$M6_TCG_THREAD" in
    single|multi) ;;
    *) echo "error: M6_TCG_THREAD must be single or multi" >&2; exit 2 ;;
esac
case "$M6_DRIVE_SNAPSHOT" in
    on|off) ;;
    *) echo "error: M6_DRIVE_SNAPSHOT must be on or off" >&2; exit 2 ;;
esac
case "$M6_DRIVE_FORMAT" in
    raw|qcow2) ;;
    *) echo "error: M6_DRIVE_FORMAT must be raw or qcow2" >&2; exit 2 ;;
esac

[[ -f "$KERNEL" ]] || { echo "error: kernel not found: $KERNEL" >&2; exit 2; }
[[ -f "$ROOTFS" ]] || { echo "error: rootfs not found: $ROOTFS" >&2; exit 2; }
mkdir -p "$(dirname "$LOG")"

GUEST_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/m6-full-j8.sh.XXXXXX")"
trap 'rm -f "$GUEST_SCRIPT"' EXIT

cat > "$GUEST_SCRIPT" <<'GUEST_SH'
#!/bin/sh
echo "===M6-FULL-J8-ENV-BEGIN==="
echo "smp=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
echo "jobs=$CARGO_BUILD_JOBS"
echo "rayon=$RAYON_NUM_THREADS"
echo "resume=$M6_RESUME"
echo "tmpfs_work=$M6_USE_TMPFS_WORK"
echo "process_heartbeat=$M6_PROCESS_HEARTBEAT_SEC"
echo "===M6-FULL-J8-ENV-END==="

mkdir -p /opt/ccwrap
cat > /opt/ccwrap/cc <<'CCWRAP'
#!/bin/sh
unset LD_LIBRARY_PATH
case "$(basename "$0")" in
c++|g++)
    if [ -x /opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-g++ ]; then
        exec /opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-g++ "$@"
    fi
    exec /opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-gcc "$@"
    ;;
*) exec /opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-gcc "$@" ;;
esac
CCWRAP
chmod +x /opt/ccwrap/cc
ln -sf /opt/ccwrap/cc /opt/ccwrap/c++

cat > /opt/ccwrap/rustc <<'RUSTWRAP'
#!/bin/sh
exec env RUSTC_BOOTSTRAP=1 "${M6_RUSTC_REAL:-/opt/alpine-rust/usr/bin/rustc}" -Z threads=0 "$@"
RUSTWRAP
chmod +x /opt/ccwrap/rustc

if [ -f /opt/alpine-rust/usr/lib/libscudo.so ] && [ ! -L /opt/alpine-rust/usr/lib/libscudo.so ]; then
    rm -f /opt/alpine-rust/usr/lib/libscudo.so
    ln -sf /lib/libc.musl-riscv64.so.1 /opt/alpine-rust/usr/lib/libscudo.so
fi

AXCFG=/opt/tgoskits/os/StarryOS/.axconfig.toml
if [ -f "$AXCFG" ]; then
    sed -i 's/^[[:space:]]*max-cpu-num[[:space:]]*=.*/max-cpu-num = 8 # uint/' "$AXCFG" 2>/dev/null || true
    sed -i 's/^[[:space:]]*phys-memory-size[[:space:]]*=.*/phys-memory-size = 0x100000000 # uint/' "$AXCFG" 2>/dev/null || true
fi

AXCONFIG_LIB=/opt/tgoskits/os/arceos/modules/axconfig/src/lib.rs
if [ -f "$AXCONFIG_LIB" ] && grep -q 'include_configs!' "$AXCONFIG_LIB" 2>/dev/null; then
    if grep -q '^pub const TASK_STACK_SIZE: usize = 0x20000;' "$AXCONFIG_LIB" 2>/dev/null; then
        echo "[M6] removing stale injected axconfig TASK_STACK_SIZE const"
        sed -i '/^pub const TASK_STACK_SIZE: usize = 0x20000;$/d' "$AXCONFIG_LIB" 2>/dev/null || true
    fi
fi

export M6_GUEST_HEARTBEAT_SEC
export M6_PROCESS_HEARTBEAT_SEC
export M6_SYSCALL_STATS_INTERVAL_SEC
export M6_CARGO_VV
export M6_RESUME
export M6_RUSTFLAGS_COMMON
export M6_USE_TMPFS_WORK
export M6_COPY_TOOLCHAIN_EXEC
export M6_WORK_TMPFS_SIZE
export CARGO_BUILD_JOBS
export RAYON_NUM_THREADS
export CARGO_TERM_PROGRESS=wide
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-false}"
export M6_SERIAL_ARTIFACT=0

if [ -f /opt/build-starry-kernel.sh ] && [ "${M6_CARGO_VV:-0}" != "1" ]; then
    sed -i 's/M6_CARGO_VV="${M6_CARGO_VV:-1}"/M6_CARGO_VV="${M6_CARGO_VV:-0}"/' /opt/build-starry-kernel.sh 2>/dev/null || true
    sed -i 's/if \[ "$M6_CARGO_VV" = "1" \]; then _CARGO_V="-vv"; else _CARGO_V="-v"; fi/if [ "$M6_CARGO_VV" = "1" ]; then _CARGO_V="-vv"; else _CARGO_V=""; fi/' /opt/build-starry-kernel.sh 2>/dev/null || true
fi

echo "===M6-FULL-J8-START==="
process_hb_pid=""
if [ "${M6_PROCESS_HEARTBEAT_SEC:-0}" != "0" ]; then
    (
        while :; do
            now="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
            echo "[M6 $now] process heartbeat (cargo/rustc/build helpers)"
            ps 2>/dev/null | head -30 || true
            ps 2>/dev/null | grep -E 'cargo|rustc|cc|ld|build-starry|m6-full' | grep -v grep | head -20 || true
            sleep "$M6_PROCESS_HEARTBEAT_SEC"
        done
    ) &
    process_hb_pid=$!
fi
/bin/bash --noprofile --norc /opt/build-starry-kernel.sh
rc=$?
[ -n "$process_hb_pid" ] && kill "$process_hb_pid" 2>/dev/null || true
sync 2>/dev/null || true
echo "===M6-FULL-J8-RUN-END rc=$rc==="
exit "$rc"
GUEST_SH

export QEMU KERNEL ROOTFS LOG M6_QEMU_SMP M6_TCG_THREAD M6_QEMU_MEM
export M6_QEMU_TIMEOUT_SEC M6_PANIC_GRACE_MS M6_DRIVE_SNAPSHOT M6_STOP_ON_PANIC GUEST_SCRIPT
export M6_DRIVE_FORMAT
export CARGO_BUILD_JOBS RAYON_NUM_THREADS M6_GUEST_HEARTBEAT_SEC
export M6_PROCESS_HEARTBEAT_SEC
export M6_SYSCALL_STATS_INTERVAL_SEC M6_RUSTFLAGS_COMMON M6_CARGO_VV
export M6_RESUME M6_USE_TMPFS_WORK M6_COPY_TOOLCHAIN_EXEC M6_WORK_TMPFS_SIZE

echo "[host] log=$LOG"
echo "[host] kernel=$KERNEL"
echo "[host] rootfs=$ROOTFS"
echo "[host] qemu=-smp $M6_QEMU_SMP -m $M6_QEMU_MEM -accel tcg,thread=$M6_TCG_THREAD drive.format=$M6_DRIVE_FORMAT drive.snapshot=$M6_DRIVE_SNAPSHOT"
echo "[host] guest cargo jobs=$CARGO_BUILD_JOBS rayon=$RAYON_NUM_THREADS stop_on_panic=$M6_STOP_ON_PANIC process_heartbeat=$M6_PROCESS_HEARTBEAT_SEC"

set +e
expect <<'EXPECT'
set timeout $env(M6_QEMU_TIMEOUT_SEC)
log_file -noappend $env(LOG)
spawn $env(QEMU) -nographic -machine virt -bios default -smp $env(M6_QEMU_SMP) -m $env(M6_QEMU_MEM) -accel tcg,thread=$env(M6_TCG_THREAD) -kernel $env(KERNEL) -cpu rv64 -monitor none -serial mon:stdio -device virtio-blk-pci,drive=disk0 -drive id=disk0,if=none,format=$env(M6_DRIVE_FORMAT),file=$env(ROOTFS),file.locking=off,snapshot=$env(M6_DRIVE_SNAPSHOT) -device virtio-net-pci,netdev=net0 -netdev user,id=net0
expect -re {root@starry:[^\r\n]*#}
send -- "cat > /tmp/m6-full-j8.sh <<'__M6_FULL_J8__'\r"
set fh [open $env(GUEST_SCRIPT) r]
while {[gets $fh line] >= 0} {
    send -- "$line\r"
}
close $fh
send -- "__M6_FULL_J8__\r"
expect -re {root@starry:[^\r\n]*#}
send -- "M6_GUEST_HEARTBEAT_SEC=$env(M6_GUEST_HEARTBEAT_SEC) M6_PROCESS_HEARTBEAT_SEC=$env(M6_PROCESS_HEARTBEAT_SEC) M6_SYSCALL_STATS_INTERVAL_SEC=$env(M6_SYSCALL_STATS_INTERVAL_SEC) M6_CARGO_VV=$env(M6_CARGO_VV) M6_RESUME=$env(M6_RESUME) M6_RUSTFLAGS_COMMON='$env(M6_RUSTFLAGS_COMMON)' M6_USE_TMPFS_WORK=$env(M6_USE_TMPFS_WORK) M6_COPY_TOOLCHAIN_EXEC=$env(M6_COPY_TOOLCHAIN_EXEC) M6_WORK_TMPFS_SIZE=$env(M6_WORK_TMPFS_SIZE) CARGO_BUILD_JOBS=$env(CARGO_BUILD_JOBS) RAYON_NUM_THREADS=$env(RAYON_NUM_THREADS) /bin/sh /tmp/m6-full-j8.sh\r"
set rc 6
expect {
    "===M6-FULL-J8-RUN-END rc=0===" {
        set rc 0
    }
    -re {===M6-FULL-J8-RUN-END rc=([1-9][0-9]*)===} {
        set rc 2
    }
    "panicked at" {
        if {$env(M6_STOP_ON_PANIC) == "1"} {
            set rc 3
            after $env(M6_PANIC_GRACE_MS)
        } else {
            exp_continue
        }
    }
    -re {(fatal|FATAL|trap|Unhandled|Segmentation fault|SIGSEGV|signal: 11|stack smashing detected)} {
        set rc 4
        after $env(M6_PANIC_GRACE_MS)
    }
    timeout {
        puts "===M6-FULL-J8-HOST-TIMEOUT==="
        set rc 5
    }
    eof {
        puts "===M6-FULL-J8-HOST-EOF==="
        set rc 6
    }
}
send "\001x"
catch wait
exit $rc
EXPECT
rc=$?
set -e
echo "[host] expect_rc=$rc" | tee -a "$LOG"
exit "$rc"
