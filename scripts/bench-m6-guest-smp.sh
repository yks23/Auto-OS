#!/usr/bin/env bash
# bench-m6-guest-smp.sh — 在 QEMU+Starry 访客内对比不同 -smp 的墙钟时间（证明多核有加速）。
#
# 访客内两段计时（均打印 ===BENCH-*=== 便于 grep）：
#   1) SHA256：总工作量固定（默认 64MiB）。默认两档均在 QEMU **同一 -smp** 下对比：
#        - sha_jobs=1：强制 N=1 单条 dd|sha256sum 管道（总字节不变）
#        - sha_jobs=nproc：N=访客 CPU 数，总字节均分并行（测多核/多任务加速）
#      说明：当前 SMP 内核（max-cpu-num>1）在 QEMU **-smp 1** 下可能无法完成引导；
#      若要真对比「QEMU 1 vCPU vs 4 vCPU」，需另编 MAX_CPU_NUM=1 的 UP 内核再设 M6_BENCH_QEMU_SMP_LEVELS。
#   2) cargo：冷目录 CARGO_TARGET_DIR，offline 并行编若干小 crate（-j nproc，包名见 M6_BENCH_CARGO_PKGS）。
#
# 依赖：与 demo-m6-selfbuild 相同（rootfs、starryos ELF、qemu-system-riscv64、loop 挂载权限）。
#
# 环境变量：
#   M6_QEMU_SMP — QEMU CPU 数，默认 4（须与内核 max-cpu-num 一致）
#   M6_BENCH_SHA_JOBS — 空格分隔的正整数：并行 dd|sha256sum 管道条数（总 MiB 均分），默认 "1 4"
#   M6_QEMU_MEM — 默认 5G
#   M6_QEMU_TIMEOUT_SEC — 单次 QEMU 超时，默认 1800
#   M6_BENCH_SHA256_TOTAL_MB — SHA256 总 MiB，默认 64（TCG 下可调大）
#   M6_BENCH_CARGO_PKGS — 空格分隔包名，默认 "ax-errno riscv-h"
#   M6_BENCH_SKIP_VERIFY=1 — 跳过 verify-m6-rootfs.sh
#   M6_BENCH_SKIP_CARGO=1 — 只跑 SHA256（TCG 下 cargo 很慢时用）
#   M6_BENCH_SHARE_ROOTFS=1 — 不复制镜像（与其它 QEMU 争用写锁，易失败）
#   M6_BENCH_SKIP_ROOTFS_COPY=1 — 若 $WORK/rootfs-bench-run.img 已存在则跳过 cp（重跑计时用）
#   ROOTFS — 同 demo-m6-selfbuild（作为复制源；实际 QEMU 默认用独占副本）
#
# 用法（仓库根）：
#   bash scripts/bench-m6-guest-smp.sh
set -euo pipefail

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$ROOT/.guest-runs/riscv64-m6-bench"
ROOTFS_MASTER="${ROOTFS:-$ROOT/tests/selfhost/rootfs-selfbuild-riscv64.img}"
ELF="$ROOT/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
M6_QEMU_SMP="${M6_QEMU_SMP:-4}"
M6_BENCH_SHA_JOBS="${M6_BENCH_SHA_JOBS:-1 4}"
M6_QEMU_MEM="${M6_QEMU_MEM:-5G}"
M6_QEMU_TIMEOUT_SEC="${M6_QEMU_TIMEOUT_SEC:-1800}"
M6_BENCH_SHA256_TOTAL_MB="${M6_BENCH_SHA256_TOTAL_MB:-64}"
# 空格分隔的 -p 列表（默认两个小 crate，TCG 下可接受；加大可设 M6_BENCH_CARGO_PKGS）
M6_BENCH_CARGO_PKGS="${M6_BENCH_CARGO_PKGS:-ax-errno riscv-h}"

mkdir -p "$WORK"
[[ -f "$ROOTFS_MASTER" ]] || { echo "rootfs not found: $ROOTFS_MASTER" >&2; exit 1; }
[[ -f "$ELF"    ]] || { echo "kernel ELF not found: $ELF" >&2; exit 1; }

if [[ "${M6_BENCH_SHARE_ROOTFS:-}" == "1" ]]; then
    ROOTFS="$ROOTFS_MASTER"
elif [[ "${M6_BENCH_SKIP_ROOTFS_COPY:-}" == "1" && -f "$WORK/rootfs-bench-run.img" ]]; then
    ROOTFS="$WORK/rootfs-bench-run.img"
    echo "[+] reuse rootfs image $ROOTFS (M6_BENCH_SKIP_ROOTFS_COPY=1)"
else
    ROOTFS="$WORK/rootfs-bench-run.img"
    echo "[+] rootfs exclusive copy -> $ROOTFS (slow on large img; set M6_BENCH_SKIP_ROOTFS_COPY=1 after first copy)"
    cp -f "$ROOTFS_MASTER" "$ROOTFS"
fi

if [[ "${M6_BENCH_SKIP_VERIFY:-}" != "1" && -x "$SCRIPT_DIR/verify-m6-rootfs.sh" ]]; then
    ROOTFS="$ROOTFS_MASTER" "$SCRIPT_DIR/verify-m6-rootfs.sh"
fi

MNT=/tmp/rfsmnt-m6-bench
inject_bench_runner() {
    local total_mb="$1"
    local cargo_pkgs="$2"
    local skip_cargo="${3:-0}"
    local sha_jobs="${4:-nproc}"
    $SUDO umount "$MNT" 2>/dev/null || true
    $SUDO mkdir -p "$MNT"
    $SUDO mount -o loop "$ROOTFS" "$MNT"
    $SUDO mkdir -p "$MNT/opt/ccwrap"
    $SUDO tee "$MNT/opt/ccwrap/cc" > /dev/null <<'CCWRAP'
#!/bin/sh
unset LD_LIBRARY_PATH
case "$(basename "$0")" in
c++|g++) exec /usr/bin/clang++ "$@" ;;
*) exec /usr/bin/clang "$@" ;;
esac
CCWRAP
    $SUDO chmod +x "$MNT/opt/ccwrap/cc"

    $SUDO tee "$MNT/opt/run-tests.sh" > /dev/null <<EOF
#!/bin/sh
# 勿 set -e：管道/后台与 Starry 下 glibc 组合曾触发异常退出链上的栈保护误报。
export PATH="/opt/ccwrap:/usr/bin:/bin:/sbin"
N=${sha_jobs}
[ "\$N" -ge 1 ] 2>/dev/null || N=1
echo "===BENCH-REPORT parallel_pipelines=\${N} total_mb_sha256=${total_mb}==="
# 固定总字节数：N=1 时单管道 total_mb；N>1 时 N 条管道各 total/N MiB。纯 dd→/dev/null。
T0=\$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)
echo "===BENCH-T0 \$T0==="
if [ "\$N" -le 1 ]; then
  dd if=/dev/zero of=/dev/null bs=1M count=${total_mb} 2>/dev/null
else
  EACH=\$(( ${total_mb} / \$N ))
  i=0
  while [ \$i -lt \$N ]; do
    ( dd if=/dev/zero of=/dev/null bs=1M count=\$EACH 2>/dev/null ) &
    i=\$((i+1))
  done
  wait
fi
T1=\$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)
echo "===BENCH-T1 \$T1==="
echo "===BENCH-SHA-PHASE-DONE==="

export PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/bin"
export CC=/opt/ccwrap/cc CXX=/opt/ccwrap/c++
export CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_LINKER=/opt/ccwrap/cc
export CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_RUSTFLAGS="-Clink-arg=-fuse-ld=lld"
export RUST_MIN_STACK=16777216
export CARGO_HOME=/opt/cargo-home
export CARGO_BUILD_JOBS="\$N"
export RAYON_NUM_THREADS="\$N"
/bin/rm -rf /opt/tgoskits/.bench-target /opt/tgoskits/.m6-tmp
/bin/mkdir -p /opt/tgoskits/.bench-target /opt/tgoskits/.m6-tmp
# ── Ensure rust-src is available for -Z build-std ──
_RUSTC_BIN="/opt/alpine-rust/usr/bin/rustc"
_SYSROOT="$("$_RUSTC_BIN" --print sysroot 2>/dev/null || echo "/opt/alpine-rust/usr")"
_RUSTLIB_SRC="${_SYSROOT}/lib/rustlib/src/rust"
if [ ! -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]; then
  if [ -f "/opt/rust-src-for-rootfs.tar.gz" ]; then
    echo "[bench-smp] extracting rust-src..."
    rm -rf "${_RUSTLIB_SRC}" 2>/dev/null || true
    mkdir -p "$(dirname "${_RUSTLIB_SRC}")" 2>/dev/null || true
    (cd "$(dirname "${_RUSTLIB_SRC}")" && tar xzf /opt/rust-src-for-rootfs.tar.gz)
  fi
fi
# Strip workspace for -Z build-std (remove std from workspace, no crates.io deps)
if [ -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]; then
  cp -f "${_RUSTLIB_SRC}/library/Cargo.toml" "${_RUSTLIB_SRC}/library/Cargo.toml.orig" 2>/dev/null || true
  cat > "${_RUSTLIB_SRC}/library/Cargo.toml" << 'MINI_WS'
cargo-features = ["profile-rustflags"]
[workspace]
resolver = "1"
members = ["sysroot"]
exclude = ["stdarch", "windows_link"]
[profile.release.package.compiler_builtins]
codegen-units = 10000
MINI_WS
  cp -f "${_RUSTLIB_SRC}/library/sysroot/Cargo.toml" "${_RUSTLIB_SRC}/library/sysroot/Cargo.toml.orig" 2>/dev/null || true
  cat > "${_RUSTLIB_SRC}/library/sysroot/Cargo.toml" << 'MINI_SYSROOT'
cargo-features = ["public-dependency"]
[package]
name = "sysroot"
version = "0.0.0"
edition = "2024"
[lib]
test = false
bench = false
doc = false
[dependencies]
core = { path = "../core", public = true }
alloc = { path = "../alloc", public = true }
compiler_builtins = { path = "../compiler-builtins/compiler-builtins" }
[features]
default = []
compiler-builtins-c = []
compiler-builtins-mem = []
MINI_SYSROOT
  cat > "${_RUSTLIB_SRC}/library/Cargo.lock" << 'BUILDSTD_LOCK'
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 3

[[package]]
name = "alloc"
version = "0.0.0"
dependencies = ["compiler_builtins", "core"]

[[package]]
name = "compiler_builtins"
version = "0.1.160"
dependencies = ["core"]

[[package]]
name = "core"
version = "0.0.0"

[[package]]
name = "sysroot"
version = "0.0.0"
dependencies = ["alloc", "compiler_builtins", "core"]
BUILDSTD_LOCK
fi
if [ "${skip_cargo}" != "1" ]; then
export CARGO_TARGET_DIR=/opt/tgoskits/.bench-target
export TMPDIR=/opt/tgoskits/.m6-tmp TMP=/opt/tgoskits/.m6-tmp TEMP=/opt/tgoskits/.m6-tmp
cd /opt/tgoskits
C0=\$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)
set +e
env LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib" SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp /opt/alpine-rust/usr/bin/cargo build --offline -j"\$N" ${cargo_pkgs} --target riscv64gc-unknown-none-elf --release -Z build-std=core,alloc,compiler_builtins > /tmp/bench-cargo.log 2>&1
RC=\$?
set -e
C1=\$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)
tail -n 6 /tmp/bench-cargo.log || true
echo "===BENCH-CARGO t0=\$C0 t1=\$C1 exit=\$RC jobs=\$N==="
fi
echo "===BENCH-DONE==="
EOF
    $SUDO chmod +x "$MNT/opt/run-tests.sh"
    # rustc wrapper: prevent vec_cache.rs:201 ICE under QEMU TCG
    $SUDO mkdir -p "$MNT/opt/ccwrap"
    $SUDO tee "$MNT/opt/ccwrap/rustc" > /dev/null <<'RUSTWRAP'
#!/bin/sh
exec env RUSTC_BOOTSTRAP=1 /opt/alpine-rust/usr/bin/rustc -Z threads=0 "$@"
RUSTWRAP
    $SUDO chmod +x "$MNT/opt/ccwrap/rustc"
    $SUDO umount "$MNT"
}

KERNEL="$WORK/starry-bench.bin"
if command -v rust-objcopy >/dev/null 2>&1; then
    rust-objcopy -O binary "$ELF" "$KERNEL"
elif command -v riscv64-linux-musl-objcopy >/dev/null 2>&1; then
    riscv64-linux-musl-objcopy -O binary "$ELF" "$KERNEL"
elif command -v llvm-objcopy >/dev/null 2>&1; then
    llvm-objcopy -O binary "$ELF" "$KERNEL"
else
    cp -f "$ELF" "$KERNEL"
fi

_cargo_p=""
for _p in $M6_BENCH_CARGO_PKGS; do
    _cargo_p+=" -p $_p"
done
_sc="${M6_BENCH_SKIP_CARGO:-0}"

echo "================================================================"
echo "  M6 guest SMP benchmark (kernel ELF + rootfs 与 demo 相同)"
echo "  固定 MiB dd→/dev/null 总工作量 ${M6_BENCH_SHA256_TOTAL_MB} MiB; QEMU -smp ${M6_QEMU_SMP}; 并行管道数档位: ${M6_BENCH_SHA_JOBS}"
echo "  cargo pkgs: ${M6_BENCH_CARGO_PKGS}"
echo "================================================================"

SUMMARY="$WORK/summary.txt"
: >"$SUMMARY"

for sj in $M6_BENCH_SHA_JOBS; do
    inject_bench_runner "$M6_BENCH_SHA256_TOTAL_MB" "$_cargo_p" "$_sc" "$sj"
    OUT="$WORK/bench-sha-${sj}.txt"
    rm -f "$OUT"
    echo ""
    echo "---------- SHA 档位 sha_jobs=$sj (QEMU -smp $M6_QEMU_SMP -m $M6_QEMU_MEM) ----------"
    _t0=$(date +%s)
    set +e
    # 用 -serial file 避免 mon:stdio 经 shell 重定向时的块缓冲，便于长计时仍能看到串口增长。
    # QEMU TCG LR/SC broken under MTTCG; force single-threaded TCG when SMP>1.
    _accel=()
    if [[ "$M6_QEMU_SMP" -gt 1 ]]; then
        _accel=(-accel tcg,thread=single)
    fi
    $SUDO timeout "$M6_QEMU_TIMEOUT_SEC" qemu-system-riscv64 \
        -display none -machine virt -bios default -smp "$M6_QEMU_SMP" -m "$M6_QEMU_MEM" \
        "${_accel[@]}" \
        -kernel "$KERNEL" -cpu rv64 \
        -monitor none -serial "file:$OUT" \
        -device virtio-blk-pci,drive=disk0 \
        -drive id=disk0,if=none,format=raw,file="$ROOTFS",file.locking=off \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
        </dev/null
    EC=$?
    set -e
    _t1=$(date +%s)
    echo "host_qemu_wall_seconds=$((_t1 - _t0)) qemu_exit=$EC" | tee -a "$SUMMARY"
    strings "$OUT" 2>/dev/null | grep -E '^===BENCH-' || true
    strings "$OUT" 2>/dev/null | grep -E '^===BENCH-' >>"$SUMMARY" || true
    if ! strings "$OUT" 2>/dev/null | grep -q "===BENCH-T1"; then
        echo "warn: missing BENCH completion marker for sha_jobs=$sj (timeout=$M6_QEMU_TIMEOUT_SEC ?) tail:" >&2
        tail -n 25 "$OUT" >&2 || true
    fi
done

echo ""
echo "================================================================"
echo "  汇总（见 $SUMMARY）"
echo "================================================================"
cat "$SUMMARY"

# 若有两档 SHA 并行度，打印加速比（仅 SHA256 行；访客墙钟秒数）
# 由访客 ===BENCH-T0/T1=== 的 /proc/uptime 浮点秒差（主机 awk，避免访客 awk 崩溃）
parse_work_from_log() {
    local f="$1"
    local t0 t1
    t0=$(strings "$f" 2>/dev/null | sed -n 's/.*===BENCH-T0 \([0-9.]*\)===.*/\1/p' | head -1)
    t1=$(strings "$f" 2>/dev/null | sed -n 's/.*===BENCH-T1 \([0-9.]*\)===.*/\1/p' | head -1)
    awk -v a="$t0" -v b="$t1" 'BEGIN { if (a + 0 > 0 && b + 0 >= a + 0) printf "%.2f", b - a; else print "" }'
}
parse_cargo_from_log() {
    local f="$1"
    local line t0 t1
    line=$(strings "$f" 2>/dev/null | grep '===BENCH-CARGO t0=' | head -1)
    t0=$(echo "$line" | sed -n 's/.*t0=\([0-9.]*\) t1=.*/\1/p')
    t1=$(echo "$line" | sed -n 's/.*t1=\([0-9.]*\) exit=.*/\1/p')
    awk -v a="$t0" -v b="$t1" 'BEGIN { if (a + 0 > 0 && b + 0 >= a + 0) printf "%.2f", b - a; else print "" }'
}
arr=($M6_BENCH_SHA_JOBS)
if [[ ${#arr[@]} -ge 2 ]]; then
    j0="${arr[0]}"
    j1="${arr[1]}"
    t0=$(parse_work_from_log "$WORK/bench-sha-${j0}.txt")
    t1=$(parse_work_from_log "$WORK/bench-sha-${j1}.txt")
    if [[ -n "$t0" && -n "$t1" ]] && awk -v b="$t1" 'BEGIN { exit !(b+0 > 0) }'; then
        fac=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", a / b }')
        echo "访客 dd 阶段: 管道数=${j0} 耗时 ${t0}s  vs  管道数=${j1} 耗时 ${t1}s  => 约 ${fac}× 加速（慢/快；理想接近 ${j1}/${j0}）"
    fi
    c0=$(parse_cargo_from_log "$WORK/bench-sha-${j0}.txt")
    c1=$(parse_cargo_from_log "$WORK/bench-sha-${j1}.txt")
    if [[ -n "$c0" && -n "$c1" ]] && awk -v b="$c1" 'BEGIN { exit !(b+0 > 0) }'; then
        cf=$(awk -v a="$c0" -v b="$c1" 'BEGIN { printf "%.2f", a / b }')
        echo "CARGO: ${j0} 档 ${c0}s vs ${j1} 档 ${c1}s => 约 ${cf}×（受依赖图限制）"
    fi
fi
