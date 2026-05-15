#!/bin/bash
# /opt/build-starry-kernel.sh — runs inside the StarryOS guest.
# 使用镜像内 **Alpine musl** rustc/cargo（/opt/alpine-rust）；避免 Debian+glibc 官方 cargo 在 Starry 下栈崩溃。
# 不用 pipefail：部分 bash+glibc 在 Starry 下与 set -o 组合曾触发异常退出链上的栈保护误报。
set -e
# 串口诊断：阶段 + UTC 时间戳；长步骤间可设 M6_GUEST_HEARTBEAT_SEC（默认 120）周期性心跳。
m6_ts() { echo "[M6 $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
# 串口输出 /proc/syscall_stats 供宿主 m6-selfbuild-progress-http.py 解析增量。
# 此为 **Starry 访客内核内** 的真实计数；不得以宿主 strace 或假日志冒烟代替。
# 旧内核无该文件时静默跳过。默认整文件 cat；若 >200KiB 则只取前 300 行以免串口洪泛。
# M6_SYSCALL_STATS_INTERVAL_SEC — 长 cargo 阶段后台周期性 dump 的间隔秒数（默认 10）；无效值回落 10；最小 1。
m6_dump_syscall_stats() {
    if [ -r /proc/syscall_stats ]; then
        echo "===SYSCALL_STATS_BEGIN==="
        _sz=$(wc -c </proc/syscall_stats 2>/dev/null | tr -d '[:space:]' || echo 0)
        case ${_sz:-0} in
        '' | *[!0-9]*) _sz=0 ;;
        esac
        if [ "${_sz:-0}" -gt 204800 ]; then
            echo "m6_dump_syscall_stats: truncating to first 300 lines (size ${_sz} bytes > 200KiB)"
            head -n 300 /proc/syscall_stats
        else
            cat /proc/syscall_stats
        fi
        echo "===SYSCALL_STATS_END==="
    fi
    if [ -r /proc/diagnostic_summary ]; then
        cat /proc/diagnostic_summary
    fi
}
# 与 m6_hb_* 类似：在 starry-kernel / pass1 / pass2 等长 cargo 阶段周期性调用 m6_dump_syscall_stats。
m6_syscall_stats_watch_start() {
    rm -f /tmp/m6-syscall-watch.pid
    (
        _iv="${M6_SYSCALL_STATS_INTERVAL_SEC:-10}"
        case ${_iv} in
        '' | *[!0-9]*) _iv=10 ;;
        esac
        if [ "${_iv}" -lt 1 ]; then _iv=1; fi
        while sleep "${_iv}"; do
            m6_dump_syscall_stats
        done
    ) &
    echo $! >/tmp/m6-syscall-watch.pid
}
m6_syscall_stats_watch_stop() {
    if [ -f /tmp/m6-syscall-watch.pid ]; then
        kill "$(cat /tmp/m6-syscall-watch.pid)" 2>/dev/null || true
        rm -f /tmp/m6-syscall-watch.pid
    fi
}
m6_hb_start() {
    rm -f /tmp/m6-hb.pid
    (
        while sleep "${M6_GUEST_HEARTBEAT_SEC:-120}"; do
            m6_ts "heartbeat phase=${M6_PHASE:-?} (rustc/cargo may print nothing for a long time)"
        done
    ) &
    echo $! >/tmp/m6-hb.pid
}
m6_hb_stop() {
    if [ -f /tmp/m6-hb.pid ]; then
        kill "$(cat /tmp/m6-hb.pid)" 2>/dev/null || true
        rm -f /tmp/m6-hb.pid
    fi
}
# glibc 的 bash/tee/find 等不要从 /opt/alpine-rust/usr/bin 解析；musl cargo 仅由 _run_cargo 注入 PATH+LD_LIBRARY_PATH。
export PATH="/opt/ccwrap:/usr/bin:/usr/sbin:/bin:/sbin:${PATH:-}"
# 全局不要 export Alpine LD_LIBRARY_PATH：本脚本由 glibc bash 解释，混用 musl 库会崩溃。
# 预填 crate 源在 /opt/cargo-home；把 CARGO_HOME 指到 /opt/tgoskits 下新目录并只 symlink 大目录，
# 让 cargo 的 sqlite（.global-cache）落在与 tgoskits 相同的 ext4 子树，避免在部分 lwext4 路径上 SQLITE_FULL。
ORIG_CARGO=/opt/cargo-home
CARGO_HOME_GUEST=/opt/tgoskits/m6-cargo-home
/bin/mkdir -p "$CARGO_HOME_GUEST/registry"
for name in index cache src; do
    if [ -e "$ORIG_CARGO/registry/$name" ] && [ ! -e "$CARGO_HOME_GUEST/registry/$name" ]; then
        ln -sfn "$ORIG_CARGO/registry/$name" "$CARGO_HOME_GUEST/registry/$name"
    fi
done
if [ -d "$ORIG_CARGO/git" ] && [ ! -e "$CARGO_HOME_GUEST/git" ]; then
    ln -sfn "$ORIG_CARGO/git" "$CARGO_HOME_GUEST/git"
fi
export CARGO_HOME="$CARGO_HOME_GUEST"
rm -f "$CARGO_HOME/.global-cache" "$CARGO_HOME/.package-cache" 2>/dev/null || true
# Starry 上 /tmp 常为极小 tmpfs；cargo/sqlite 与 rustc 临时文件必须落在 virtio 盘上。
/bin/mkdir -p /opt/tgoskits/.m6-tmp
export TMPDIR=/opt/tgoskits/.m6-tmp
export TMP=/opt/tgoskits/.m6-tmp
export TEMP=/opt/tgoskits/.m6-tmp
# rustc 常硬编码调用 /usr/bin/cc，绕开 PATH 里的 ccwrap；显式指定 musl 主机链接器为 /opt/ccwrap/cc（清 LD_LIBRARY_PATH）。
export CC="${CC:-/opt/ccwrap/cc}"
export CXX="${CXX:-/opt/ccwrap/c++}"
export CC_riscv64_alpine_linux_musl="${CC_riscv64_alpine_linux_musl:-/opt/ccwrap/cc}"
export CXX_riscv64_alpine_linux_musl="${CXX_riscv64_alpine_linux_musl:-/opt/ccwrap/c++}"
# 主机 musl：collect2 在访客里易 ICE，用 lld；不影响 riscv64gc-unknown-none-elf（另套 target）。
export CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_LINKER=/opt/ccwrap/cc
export CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_RUSTFLAGS="-Clink-arg=-fuse-ld=lld"
# 降低 rustc 默认栈过小导致 __stack_chk_fail 的风险；并行度默认随访客 CPU 数（QEMU -smp）。
export RUST_MIN_STACK="${RUST_MIN_STACK:-16777216}"
_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)"
if [[ "${_NPROC}" -lt 1 ]]; then _NPROC=1; fi
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-$_NPROC}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_NPROC}"
# 详细编译信号（宿主可通过 demo 注入覆盖）：
#   M6_RUSTFLAGS_COMMON — 默认带 DWARF（等价 gcc -g），便于 rustc 卡住时 objdump/llvm-objcopy 仍可符号化；
#   M6_CARGO_VV=1 — cargo -vv（每道 rustc 命令行全量打印）；=0 则仅用 -v 缩短日志。
#   CARGO_TERM_PROGRESS — wide 在串口上更易看出「仍在跑」。
export CARGO_TERM_PROGRESS="${CARGO_TERM_PROGRESS:-wide}"
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-true}"
export CARGO_INCREMENTAL=0
M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON:--C debuginfo=2}"
M6_CARGO_VV="${M6_CARGO_VV:-1}"
if [ "$M6_CARGO_VV" = "1" ]; then _CARGO_V="-vv"; else _CARGO_V="-v"; fi
RUSTC=/opt/alpine-rust/usr/bin/rustc
CARGO=/opt/alpine-rust/usr/bin/cargo
# Strip rust-src workspace for -Z build-std (remove std/test members to avoid crates.io deps)
_strip_buildstd_ws() {
  [[ -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]] || return 0
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
default = ["panic-unwind"]
backtrace = []
panic-unwind = []
panic-abort = []
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
}
# ── Ensure rust-src is available for -Z build-std (bare-metal target) ──
_SYSROOT="$("$RUSTC" --print sysroot 2>/dev/null || echo "/opt/alpine-rust/usr")"
_RUSTLIB_SRC="${_SYSROOT}/lib/rustlib/src/rust"
if [[ ! -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]]; then
  echo "[M6] rust-src missing; extracting..."
  rm -rf "${_RUSTLIB_SRC}" 2>/dev/null || true
  mkdir -p "$(dirname "${_RUSTLIB_SRC}")" 2>/dev/null || true
  if [[ -f "/opt/rust-src-for-rootfs.tar.gz" ]]; then
    (cd "$(dirname "${_RUSTLIB_SRC}")" && tar xzf /opt/rust-src-for-rootfs.tar.gz)
    if [[ -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]]; then
      echo "[M6] rust-src extracted OK"
      _strip_buildstd_ws
    else
      echo "[M6] warn: rust-src extraction failed"
    fi
  else
    echo "[M6] warn: /opt/rust-src-for-rootfs.tar.gz not found; -Z build-std may fail"
  fi
elif [[ -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]]; then
  _strip_buildstd_ws
fi
_BS_FLAG="-Z build-std=core,alloc,compiler_builtins"
# 不用 stdbuf：其在 glibc 下依赖 LD_PRELOAD(libstdbuf)，在 Starry 访客里会异常退出/被报成 not found。
# 用 tee 把 cargo 输出打到串口 + /tmp，便于宿主侧看 results.txt 体积增长。
# **cargo 对匿名 pipe 常全缓冲**：可选 `M6_CARGO_PTY=1` 用 script(1) 分配伪终端以刷日志。
# 默认 **关闭**：在 Starry 访客 + musl cargo 下曾触发 axtask「atomic context sleep」panic（见 wait_queue.rs）。
# **断点续编**：`M6_RESUME=1` 时若 virtio 盘上已有阶段产物或 `.m6-done-*` 标记，则跳过已完成阶段（见下方）。
# 仅对 musl cargo 进程注入 LD_LIBRARY_PATH（勿污染当前 glibc bash）。
_run_cargo() {
    if [ "${M6_CARGO_PTY:-0}" = "1" ] && command -v script >/dev/null 2>&1; then
        _M6_CARGO_Q=$(printf ' %q' "$@")
        script -qefc "/usr/bin/env PATH=\"/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin\" LD_LIBRARY_PATH=\"/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib\" SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp TMPDIR=/opt/tgoskits/.m6-tmp /opt/alpine-rust/usr/bin/cargo${_M6_CARGO_Q}" /dev/null
    else
        env PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin" \
            LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib" \
            SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp \
            TMPDIR=/opt/tgoskits/.m6-tmp \
            "$CARGO" "$@"
    fi
}

# 快速子集：验证 guest 内 cargo 离线解析/索引可用与关键包可定位，不编整棵 starry-kernel。
# 由宿主 demo 注入 M6_MODE=subset（见 scripts/demo-m6-selfbuild.sh --subset）。
if [ "${M6_MODE:-full}" = "subset" ]; then
    echo "================================================================"
    echo "  StarryOS M6 — guest cargo SUBSET (quick smoke)"
    echo "================================================================"
    echo
    m6_ts "subset begin"
    cd /opt/tgoskits
    m6_ts "[subset-0] start cargo metadata --offline --no-deps"
    echo "[subset-0] cargo metadata --offline --no-deps (workspace 根解析)"
    _run_cargo metadata --offline --format-version 1 --no-deps > /tmp/m6-subset-meta.json
    RC0=$?
    m6_ts "metadata exit=$RC0"
    echo "metadata exit=$RC0"
    [ "$RC0" -eq 0 ] || exit "$RC0"
    m6_ts "[subset-1] start cargo pkgid -p riscv-h"
    echo "[subset-1] cargo pkgid -p riscv-h (关键包离线定位)"
    set -o pipefail
    _run_cargo pkgid --offline -p riscv-h 2>&1 | tee /tmp/m6-subset-riscv-h.log
    RC1=${PIPESTATUS[0]}
    set +o pipefail
    m6_ts "riscv-h pkgid exit=$RC1"
    echo "riscv-h pkgid exit=$RC1"
    [ "$RC1" -eq 0 ] || exit "$RC1"
    m6_ts "[subset-2] start cargo pkgid -p ax-cpu"
    echo "[subset-2] cargo pkgid -p ax-cpu (关键包离线定位)"
    set -o pipefail
    _run_cargo pkgid --offline -p ax-cpu 2>&1 | tee /tmp/m6-subset-ax-cpu.log
    RC2=${PIPESTATUS[0]}
    set +o pipefail
    m6_ts "ax-cpu pkgid exit=$RC2"
    echo "ax-cpu pkgid exit=$RC2"
    [ "$RC2" -eq 0 ] || exit "$RC2"
    m6_ts "[subset-3] start cargo pkgid -p ax-errno"
    echo "[subset-3] cargo pkgid -p ax-errno"
    set -o pipefail
    _run_cargo pkgid --offline -p ax-errno 2>&1 | tee /tmp/m6-subset-axerrno.log
    RC3=${PIPESTATUS[0]}
    set +o pipefail
    m6_ts "ax-errno pkgid exit=$RC3"
    echo "ax-errno pkgid exit=$RC3"
    [ "$RC3" -eq 0 ] || exit "$RC3"
    m6_ts "subset all steps OK"
    echo
    echo "================================================================"
    echo "===M6-SELFBUILD-SUBSET-PASS==="
    echo "  guest cargo metadata/pkgid offline checks OK"
    echo "================================================================"
    exit 0
fi

echo "================================================================"
echo "  StarryOS Self-Build Demo M6 — guest cargo build starry-kernel"
echo "================================================================"
echo
m6_ts "full M6 selfbuild: toolchain + cargo phases (heartbeats every ${M6_GUEST_HEARTBEAT_SEC:-120}s during compile)"
echo "[0] toolchain sanity:"
# rustc --version 在部分 Starry+QEMU 组合下会在进程收尾阶段触发 __stack_chk_fail；直接进入构建。
echo "rustc binary: $RUSTC (skip --version)"
echo
cd /opt/tgoskits
m6_ts "[1] inspect tgoskits tree"
echo "[1] tgoskits source (HEAD):"
if [ -d /opt/tgoskits/.git ]; then
    /usr/bin/git -C /opt/tgoskits log -1 --oneline 2>/dev/null || echo "(no git log)"
else
    echo "(no .git in image — workspace tarball copy)"
fi
echo

# axplat：平台 toml 在树内；合并后的 .axconfig.toml 由 rootfs 构建阶段在**宿主**生成并拷入镜像。
cd /opt/tgoskits/os/StarryOS
PLAT_CONFIG="/opt/tgoskits/components/axplat_crates/platforms/axplat-riscv64-qemu-virt/axconfig.toml"
if [ ! -f "$PLAT_CONFIG" ]; then
    echo "FATAL: missing $PLAT_CONFIG"
    exit 1
fi
if [ ! -f .axconfig.toml ]; then
    echo "FATAL: missing baked .axconfig.toml under os/StarryOS (re-run tests/selfhost/build-selfbuild-rootfs.sh)"
    exit 1
fi
PLAT_NAME=$(awk -F'"' '$1 ~ /^platform[[:space:]]*=/ {print $2}' "$PLAT_CONFIG" | head -1)
if [ -z "$PLAT_NAME" ]; then
    PLAT_NAME="riscv64-qemu-virt"
fi
echo "PLAT_CONFIG=$PLAT_CONFIG PLAT_NAME=$PLAT_NAME (baked .axconfig.toml)"

export AX_ARCH=riscv64
export AX_PLATFORM="$PLAT_NAME"
export AX_MODE=release
export AX_LOG=warn
export AX_TARGET=riscv64gc-unknown-none-elf
export AX_IP=10.0.2.15
export AX_GW=10.0.2.2
export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"
m6_ts "AX_* exported AX_TARGET=$AX_TARGET AX_PLATFORM=$AX_PLATFORM"

cd /opt/tgoskits

m6_ts "parallelism: CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS RAYON_NUM_THREADS=$RAYON_NUM_THREADS (override via env)"

# ---------- M6_RESUME：同一 rootfs 镜像上多次 QEMU，利用 cargo incremental ----------
# 宿主 demo 注入 M6_RESUME=1（默认 0）；若盘上已有产物则跳过已完成阶段（需上次运行已把 target/ 写入 virtio 盘）。
# 成功阶段结束时会 touch /opt/tgoskits/.m6-done-kernel-lib | .m6-done-pass1 | .m6-done-pass2；续跑时亦认产物（rlib / linker_*.lds）。
M6_RESUME="${M6_RESUME:-0}"
M6_DONE_K="/opt/tgoskits/.m6-done-kernel-lib"
M6_DONE_P1="/opt/tgoskits/.m6-done-pass1"
M6_DONE_P2="/opt/tgoskits/.m6-done-pass2"
LD="target/riscv64gc-unknown-none-elf/release/linker_${PLAT_NAME}.lds"
ELF="target/riscv64gc-unknown-none-elf/release/starryos"
RESUME_SKIP_KERNEL=0
RESUME_SKIP_PASS1=0
if [ "$M6_RESUME" = "1" ]; then
    m6_ts "M6_RESUME=1: scan target/ + .m6-done-* under /opt/tgoskits"
    if [ -f "$ELF" ]; then
        touch "$M6_DONE_P2" 2>/dev/null || true
        m6_ts "found $ELF — build already complete"
        ls -lh "$ELF" 2>&1 | head -2
        file "$ELF" 2>/dev/null | head -1 || true
        echo "================================================================"
        echo "===M6-SELFBUILD-PASS==="
        echo "  (resume: ELF already on virtio disk)"
        echo "================================================================"
        exit 0
    fi
    if [ -f "$LD" ]; then
        m6_ts "found $LD — skip [2][3], run [4] pass2 only"
        RESUME_SKIP_KERNEL=1
        RESUME_SKIP_PASS1=1
    elif [ -f "$M6_DONE_P1" ]; then
        m6_ts "resume: $M6_DONE_P1 without $LD — stale marker, will re-run from [3]"
    fi
    if [ "$RESUME_SKIP_KERNEL" != "1" ]; then
        LIB0=$(find target/riscv64gc-unknown-none-elf/release -maxdepth 3 -name "libstarry_kernel*.rlib" 2>/dev/null | head -1 || true)
        if [ -n "$LIB0" ] && [ -f "$LIB0" ]; then
            m6_ts "found kernel rlib — skip [2], run [3][4]"
            RESUME_SKIP_KERNEL=1
        elif [ -f "$M6_DONE_K" ]; then
            LIB0=$(find target/riscv64gc-unknown-none-elf/release -maxdepth 3 -name "libstarry_kernel*.rlib" 2>/dev/null | head -1 || true)
            if [ -n "$LIB0" ] && [ -f "$LIB0" ]; then
                m6_ts "resume: $M6_DONE_K + rlib — skip [2]"
                RESUME_SKIP_KERNEL=1
            else
                m6_ts "resume: $M6_DONE_K but no libstarry_kernel*.rlib — re-run [2]"
            fi
        fi
    fi
fi

m6_dump_syscall_stats

# 与宿主 scripts/build.sh 对齐：仅当树内 starry-kernel 声明了 smp feature 时才传 --features smp（旧 rootfs tarball 无此行时会失败）。
SK_KERNEL_FEAT=""
if grep -qE '^[[:space:]]*smp[[:space:]]*=' /opt/tgoskits/os/StarryOS/kernel/Cargo.toml 2>/dev/null; then
    SK_KERNEL_FEAT="--features smp"
    echo "[2] starry-kernel: enabling workspace feature smp (matches baked axconfig SMP)"
else
    echo "[2] starry-kernel: no 'smp' feature in Cargo.toml — building without --features smp (legacy rootfs)"
fi

RC=0
RC1=0
if [ "$RESUME_SKIP_KERNEL" != "1" ]; then
    m6_ts "[2] start cargo build -p starry-kernel (lib) — may run for a long time with no crate output"
    echo "[2] cargo build $_CARGO_V --offline -p starry-kernel (lib) $SK_KERNEL_FEAT RUSTFLAGS+=$M6_RUSTFLAGS_COMMON"
    export M6_PHASE=starry-kernel-lib
    export RUSTFLAGS="$M6_RUSTFLAGS_COMMON ${RUSTFLAGS:-}"
    m6_hb_start
    m6_syscall_stats_watch_start
    set -o pipefail
    _run_cargo build $_CARGO_V --offline -p starry-kernel \
        $SK_KERNEL_FEAT \
        --target riscv64gc-unknown-none-elf --release ${_BS_FLAG} 2>&1 | tee /tmp/m6-cargo-kernel.log
    RC=${PIPESTATUS[0]}
    set +o pipefail
    m6_syscall_stats_watch_stop
    m6_hb_stop
    m6_ts "[2] starry-kernel lib finished rc=$RC"
    echo "starry-kernel-build exit=$RC"
    if [ "$RC" -ne 0 ]; then
        exit "$RC"
    fi
    touch "$M6_DONE_K"
else
    m6_ts "[2] skipped (M6_RESUME: kernel stage already done or linker-only resume)"
    touch "$M6_DONE_K" 2>/dev/null || true
fi

LIB=$(find target/riscv64gc-unknown-none-elf/release -maxdepth 3 -name "libstarry_kernel*.rlib" 2>/dev/null | head -1 || true)
if [ -n "$LIB" ] && [ -f "$LIB" ]; then
    echo "produced rlib: $(ls -lh "$LIB" 2>&1 | head -1)"
else
    echo "produced rlib: (none — linker-only resume or clean tree)"
fi
echo

m6_dump_syscall_stats

if [ "$RESUME_SKIP_PASS1" != "1" ]; then
    m6_ts "[3] start pass1 starryos (generate linker_${PLAT_NAME}.lds)"
    echo "[3] pass1 starryos $_CARGO_V RUSTFLAGS+=$M6_RUSTFLAGS_COMMON"
    export M6_PHASE=starryos-pass1
    export RUSTFLAGS="$M6_RUSTFLAGS_COMMON ${RUSTFLAGS:-}"
    m6_hb_start
    m6_syscall_stats_watch_start
    set -o pipefail
    _run_cargo build $_CARGO_V --offline -p starryos \
        --target riscv64gc-unknown-none-elf --release \
        --features starryos/qemu,smp ${_BS_FLAG} 2>&1 | tee /tmp/m6-cargo-pass1.log
    RC1=${PIPESTATUS[0]}
    set +o pipefail
    m6_syscall_stats_watch_stop
    m6_hb_stop
    m6_ts "[3] starryos pass1 finished rc=$RC1"
    echo "starryos pass1 exit=$RC1"
    if [ "$RC1" -ne 0 ]; then
        exit "$RC1"
    fi
    if [ ! -f "$LD" ]; then
        echo "pass1 did not create $LD — reporting lib-only progress"
        echo "===M6-SELFBUILD-LIB-PASS==="
        exit 0
    fi
    touch "$M6_DONE_P1"
else
    m6_ts "[3] skipped (M6_RESUME: linker script already on disk)"
    if [ ! -f "$LD" ]; then
        echo "FATAL: resume expected $LD but missing"
        exit 2
    fi
    touch "$M6_DONE_P1" 2>/dev/null || true
fi

m6_dump_syscall_stats

m6_ts "[4] start pass2 starryos (final ELF link)"
echo "[4] pass2 starryos $_CARGO_V (RUSTFLAGS: debuginfo + linker script)"
export M6_PHASE=starryos-pass2
m6_hb_start
m6_syscall_stats_watch_start
set -o pipefail
export RUSTFLAGS="$M6_RUSTFLAGS_COMMON -C link-arg=-T$(pwd)/$LD -C link-arg=-no-pie -C link-arg=-znostart-stop-gc"
_run_cargo build $_CARGO_V --offline -p starryos \
    --target riscv64gc-unknown-none-elf --release \
    --features starryos/qemu,smp ${_BS_FLAG} 2>&1 | tee /tmp/m6-cargo-pass2.log
RC2=${PIPESTATUS[0]}
set +o pipefail
m6_syscall_stats_watch_stop
m6_hb_stop
m6_ts "[4] starryos pass2 finished rc=$RC2"
echo "starryos pass2 exit=$RC2"
if [ -f "$ELF" ]; then
    touch "$M6_DONE_P2"
    ls -lh "$ELF"
    file "$ELF" | head -1
    echo
    m6_dump_syscall_stats
    echo "================================================================"
    echo "===M6-SELFBUILD-PASS==="
    echo "  starry kernel ELF was just produced INSIDE the starry guest!"
    echo "================================================================"
elif [ "$RC2" -eq 0 ]; then
    echo "===M6-SELFBUILD-LIB-PASS==="
else
    exit "$RC2"
fi
GUESTSH
