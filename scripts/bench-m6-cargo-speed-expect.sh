#!/usr/bin/env bash
# Run a guest cargo -jN synthetic workspace through host QEMU without copying
# or mounting the rootfs. The rootfs is used in snapshot mode, so this leaves
# only a small serial log on the host.
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

KERNEL="${M6_KERNEL_BIN:-$ROOT/.guest-runs/riscv64-m6/starry-smp8-current-20260522.bin}"
ROOTFS="${ROOTFS:-$ROOT/.guest-runs/rootfs-selfbuild-riscv64.img}"
LOG="${M6_LOG:-$ROOT/showtime/multi-cpu/logs/cargo-speed-smp8-current-mttcg-j8-$(date +%Y%m%dT%H%M%S).log}"
M6_QEMU_SMP="${M6_QEMU_SMP:-8}"
M6_TCG_THREAD="${M6_TCG_THREAD:-multi}"
M6_QEMU_MEM="${M6_QEMU_MEM:-4G}"
M6_QEMU_TIMEOUT_SEC="${M6_QEMU_TIMEOUT_SEC:-2400}"
M6_CARGO_SPEED_LEAVES="${M6_CARGO_SPEED_LEAVES:-48}"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"
M6_RUSTC_THREADS="${M6_RUSTC_THREADS:-0}"
M6_PANIC_GRACE_MS="${M6_PANIC_GRACE_MS:-5000}"

case "$M6_TCG_THREAD" in
    single|multi) ;;
    *) echo "error: M6_TCG_THREAD must be single or multi" >&2; exit 2 ;;
esac

[[ -f "$KERNEL" ]] || { echo "error: kernel not found: $KERNEL" >&2; exit 2; }
[[ -f "$ROOTFS" ]] || { echo "error: rootfs not found: $ROOTFS" >&2; exit 2; }
mkdir -p "$(dirname "$LOG")"

GUEST_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/m6-cargo-speed.XXXXXX.sh")"
trap 'rm -f "$GUEST_SCRIPT"' EXIT

cat > "$GUEST_SCRIPT" <<'GUEST_SH'
#!/bin/sh
set -u

LEAVES="${M6_CARGO_SPEED_LEAVES:-48}"
JOBS="${CARGO_BUILD_JOBS:-8}"
RUSTC_THREADS="${M6_RUSTC_THREADS:-0}"
WORK=/tmp/m6-cargo-speed
TARGET=/opt/tgoskits/.bench-target-j8
TMP=/opt/tgoskits/.m6-tmp-j8
LOG=/tmp/m6-cargo-speed-j8.log

echo "===CARGO-SPEED-ENV-BEGIN==="
echo "smp=$(cat /proc/cpuinfo 2>/dev/null | grep -c '^processor' || true)"
echo "leaves=$LEAVES"
echo "jobs=$JOBS"
echo "rustc_threads=$RUSTC_THREADS"
echo "work=$WORK"
echo "target=$TARGET"
echo "===CARGO-SPEED-ENV-END==="

export PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/bin:/sbin"
export LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib"
export RUSTC_BOOTSTRAP=1
export CARGO_HOME=/opt/cargo-home
export CARGO_TARGET_DIR="$TARGET"
export CARGO_BUILD_JOBS="$JOBS"
export RAYON_NUM_THREADS="$JOBS"
export CARGO_INCREMENTAL=0
export TMPDIR="$TMP" TMP="$TMP" TEMP="$TMP"
export RUST_MIN_STACK=16777216

mkdir -p /opt/ccwrap "$TMP"
cat > /opt/ccwrap/rustc <<RUSTC_WRAP
#!/bin/sh
exec env RUSTC_BOOTSTRAP=1 /opt/alpine-rust/usr/bin/rustc -Z threads=$RUSTC_THREADS "\$@"
RUSTC_WRAP
chmod +x /opt/ccwrap/rustc

rm -rf "$WORK" "$TARGET" "$TMP"
mkdir -p "$WORK/app/src" "$TARGET" "$TMP"

cat > "$WORK/Cargo.toml" <<'WS_HEAD'
[workspace]
resolver = "3"
members = [
WS_HEAD
i=0
while [ "$i" -lt "$LEAVES" ]; do
    printf '  "leaf%s",\n' "$i" >> "$WORK/Cargo.toml"
    i=$((i + 1))
done
cat >> "$WORK/Cargo.toml" <<'WS_TAIL'
  "app",
]

[profile.release]
codegen-units = 16
WS_TAIL

i=0
while [ "$i" -lt "$LEAVES" ]; do
    mkdir -p "$WORK/leaf$i/src"
    cat > "$WORK/leaf$i/Cargo.toml" <<LEAF_TOML
[package]
name = "leaf$i"
version = "0.1.0"
edition = "2024"

[lib]
path = "src/lib.rs"
LEAF_TOML
    cat > "$WORK/leaf$i/src/lib.rs" <<'LEAF_RS'
#![no_std]

pub fn mix(mut x: u64) -> u64 {
    let mut i = 0;
    while i < 4096 {
        x = x.rotate_left(13) ^ 0x9e3779b97f4a7c15;
        i += 1;
    }
    x
}
LEAF_RS
    i=$((i + 1))
done

cat > "$WORK/app/Cargo.toml" <<'APP_HEAD'
[package]
name = "app"
version = "0.1.0"
edition = "2024"

[lib]
path = "src/lib.rs"

[dependencies]
APP_HEAD
i=0
while [ "$i" -lt "$LEAVES" ]; do
    printf 'leaf%s = { path = "../leaf%s" }\n' "$i" "$i" >> "$WORK/app/Cargo.toml"
    i=$((i + 1))
done
cat > "$WORK/app/src/lib.rs" <<'APP_RS_HEAD'
#![no_std]

pub fn run() -> u64 {
    let mut x = 0;
APP_RS_HEAD
i=0
while [ "$i" -lt "$LEAVES" ]; do
    printf '    x ^= leaf%s::mix(%s);\n' "$i" "$i" >> "$WORK/app/src/lib.rs"
    i=$((i + 1))
done
cat >> "$WORK/app/src/lib.rs" <<'APP_RS_TAIL'
    x
}
APP_RS_TAIL

echo "===CARGO-SPEED-START jobs=$JOBS leaves=$LEAVES==="
cd "$WORK" || exit 1
set +e
cargo build --offline -j"$JOBS" --workspace --release > "$LOG" 2>&1 &
pid=$!
tick=0
while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    tick=$((tick + 30))
    echo "===CARGO-SPEED-HEARTBEAT seconds=$tick jobs=$JOBS==="
    tail -n 6 "$LOG" || true
done
wait "$pid"
rc=$?
set -e
tail -n 30 "$LOG" || true
echo "===CARGO-SPEED-END jobs=$JOBS rc=$rc==="
if [ "$rc" = "0" ]; then
    echo "===CARGO-SPEED-PASS==="
else
    echo "===CARGO-SPEED-FAIL rc=$rc==="
fi
exit "$rc"
GUEST_SH

export QEMU KERNEL ROOTFS LOG M6_QEMU_SMP M6_TCG_THREAD M6_QEMU_MEM
export M6_QEMU_TIMEOUT_SEC M6_CARGO_SPEED_LEAVES CARGO_BUILD_JOBS GUEST_SCRIPT
export M6_RUSTC_THREADS M6_PANIC_GRACE_MS

echo "[host] log=$LOG"
echo "[host] kernel=$KERNEL"
echo "[host] rootfs=$ROOTFS"
echo "[host] qemu=-smp $M6_QEMU_SMP -m $M6_QEMU_MEM -accel tcg,thread=$M6_TCG_THREAD -snapshot"
echo "[host] guest cargo leaves=$M6_CARGO_SPEED_LEAVES jobs=$CARGO_BUILD_JOBS rustc_threads=$M6_RUSTC_THREADS"

expect <<'EXPECT'
set timeout $env(M6_QEMU_TIMEOUT_SEC)
log_file -noappend $env(LOG)

proc shutdown_qemu {} {
    catch {send "\001x"}
    after 1000
    catch {close}
    catch wait
}

spawn $env(QEMU) -nographic -machine virt -bios default -smp $env(M6_QEMU_SMP) -m $env(M6_QEMU_MEM) -accel tcg,thread=$env(M6_TCG_THREAD) -kernel $env(KERNEL) -cpu rv64 -monitor none -serial mon:stdio -snapshot -device virtio-blk-pci,drive=disk0 -drive id=disk0,if=none,format=raw,file=$env(ROOTFS),file.locking=off,snapshot=on -device virtio-net-pci,netdev=net0 -netdev user,id=net0
expect -re {root@starry:[^\r\n]*#}
send -- "cat > /tmp/m6-cargo-speed-j8.sh <<'__M6_CARGO_SPEED__'\r"
set fh [open $env(GUEST_SCRIPT) r]
while {[gets $fh line] >= 0} {
    send -- "$line\r"
}
close $fh
send -- "__M6_CARGO_SPEED__\r"
expect -re {root@starry:[^\r\n]*#}
send -- "M6_CARGO_SPEED_LEAVES=$env(M6_CARGO_SPEED_LEAVES) CARGO_BUILD_JOBS=$env(CARGO_BUILD_JOBS) M6_RUSTC_THREADS=$env(M6_RUSTC_THREADS) /bin/sh /tmp/m6-cargo-speed-j8.sh\r"
set rc 6
expect {
    "===CARGO-SPEED-PASS===" {
        set rc 0
    }
    -re {===CARGO-SPEED-FAIL rc=([0-9]+)===} {
        set rc 2
    }
    "panicked at" {
        set rc 3
        after $env(M6_PANIC_GRACE_MS)
    }
    -re {(fatal|FATAL|trap|Unhandled|Segmentation fault|SIGSEGV|signal: 11)} {
        set rc 4
        after $env(M6_PANIC_GRACE_MS)
    }
    timeout {
        set rc 5
    }
    eof {
        set rc 6
    }
}
shutdown_qemu
exit $rc
EXPECT
