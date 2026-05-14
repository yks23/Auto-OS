#!/usr/bin/env bash
# Build StarryOS kernel ELF for the given ARCH.
#
# 用法：
#   scripts/build.sh ARCH=riscv64                # build kernel ELF (release)
#   scripts/build.sh ARCH=x86_64                 # build kernel ELF (release)
#   scripts/build.sh ARCH=riscv64 TARGET=ci-test # ci-test (需要 rootfs)
#
# 与访客 M6 syscall 面板对照（宿主 Linux，非 Starry 内核）：
#   RECORD_LINUX_SYSCALL_SUMMARY=/work/.guest-runs/linux-strace-starry-build.log \
#     bash scripts/build.sh ARCH=riscv64
#   若 PATH 上有 strace，则整次脚本（含两遍 cargo）在 strace -f -c 下重跑，汇总写入上述文件；
#   成功末尾会向 stdout 打印 ===LINUX_BUILD_SYSCALL_SUMMARY_{BEGIN,END}=== 片段便于采集。
#   注意：与访客 /proc/syscall_stats 的 syscall 号不可逐号对比（ABI/内核不同），仅作「同配置编译 workload」量级对照。
#
# 要点：
# - tgoskits dev 当前 PIN c7e88fb3 的 make/build.mk 有上游 bug：
#   1) 顶层 Makefile A=$(PWD) 时，APP_TYPE 检测会走 c 路径，引入不存在
#      的 build_c.mk
#   2) build.mk:8 计算 rust_package 时去找 $APP/starryos/Cargo.toml，
#      但 APP 应该是 starryos 本身
# - 这里跳过 make 包装，直接走 ax-config-gen + cargo build 两遍构建
#   （第一遍生成 linker_<plat>.lds，第二遍才能链接）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ARCH=""
TARGET="build"
for arg in "$@"; do
    case "$arg" in
        ARCH=*)   ARCH="${arg#ARCH=}" ;;
        TARGET=*) TARGET="${arg#TARGET=}" ;;
        *) die "unknown arg: $arg" ;;
    esac
done
ARCH="${ARCH:-riscv64}"

# 可选：在 Linux 宿主上记录本次「正确 axconfig 下」内核编译触发的系统调用汇总（strace -c），
# 供与 QEMU 内 Starry 的 /proc/syscall_stats 做 workload 级对照（非同一内核语义）。
if [[ -n "${RECORD_LINUX_SYSCALL_SUMMARY:-}" && -z "${__STARRY_BUILD_STRACE_CHILD:-}" ]]; then
    if command -v strace >/dev/null 2>&1; then
        export __STARRY_BUILD_STRACE_CHILD=1
        _sum="${RECORD_LINUX_SYSCALL_SUMMARY}"
        _dir="$(dirname "$_sum")"
        [[ "$_dir" == "." ]] || mkdir -p "$_dir"
        log "RECORD_LINUX_SYSCALL_SUMMARY -> $_sum (re-exec under strace -f -c; slower)"
        exec strace -f -c -o "$_sum" -- bash "${BASH_SOURCE[0]}" "$@"
    else
        log "warning: RECORD_LINUX_SYSCALL_SUMMARY set but strace not in PATH; building without syscall summary"
    fi
fi

[[ -d "$TGOSKITS/os/StarryOS" ]] || die "tgoskits/os/StarryOS not found"

# 准备 musl cross
PATH="/opt/${ARCH}-linux-musl-cross/bin:$PATH"
export PATH
if ! command -v "${ARCH}-linux-musl-gcc" >/dev/null; then
    log "warning: ${ARCH}-linux-musl-gcc not in PATH (kernel build doesn't need it directly)"
fi

case "$ARCH" in
    x86_64)       PLAT_PACKAGE=ax-plat-x86-pc;             RUST_TARGET=x86_64-unknown-none ;;
    aarch64)      PLAT_PACKAGE=ax-plat-aarch64-qemu-virt;  RUST_TARGET=aarch64-unknown-none-softfloat ;;
    riscv64)      PLAT_PACKAGE=ax-plat-riscv64-qemu-virt;  RUST_TARGET=riscv64gc-unknown-none-elf ;;
    loongarch64)  PLAT_PACKAGE=ax-plat-loongarch64-qemu-virt; RUST_TARGET=loongarch64-unknown-none-softfloat ;;
    *) die "unknown ARCH=$ARCH" ;;
esac

case "$TARGET" in
    build) ;;
    ci-test)
        # ci-test 走 starry 自己的 ./scripts/ci-test.py
        cd "$TGOSKITS/os/StarryOS"
        exec ./scripts/ci-test.py "$ARCH"
        ;;
    *) die "unknown TARGET=$TARGET" ;;
esac

log "building ARCH=$ARCH PLAT=$PLAT_PACKAGE TARGET=$RUST_TARGET"
cd "$TGOSKITS/os/StarryOS"

# 1. 生成 .axconfig.toml（合并 defconfig.toml + PLAT_CONFIG）
# cargo axplat 会解析整个 tgoskits workspace：rustup 同步、索引/git 依赖、首次 crate 下载
# 可能持续数分钟；勿丢弃 stderr，否则终端只剩上一行 log，易被误判为「卡住」。
log "resolving PLAT_CONFIG (cargo axplat; 首次或空 CARGO_HOME 会较久，见下方 cargo/rustup 输出)"
PLAT_CONFIG=$(cargo axplat info -C starryos -c "$PLAT_PACKAGE" | tail -1)
if [[ -z "$PLAT_CONFIG" || ! -f "$PLAT_CONFIG" ]]; then
    die "could not resolve PLAT_CONFIG for $PLAT_PACKAGE (got: $PLAT_CONFIG)"
fi
log "PLAT_CONFIG=$PLAT_CONFIG"

PLAT_NAME=$(awk -F'"' '$1 ~ /^platform[[:space:]]*=/ {print $2}' "$PLAT_CONFIG" | head -1)
log "PLAT_NAME=$PLAT_NAME"

# riscv64 QEMU：默认多核 SMP + 更大物理内存（与 scripts/demo-m6-selfbuild.sh 一致）。
# 单核回退：MAX_CPU_NUM=1 bash scripts/build.sh ARCH=riscv64
STARRY_QEMU_FEATURES="starryos/qemu"
AXGEN_EXTRA=()
if [[ "$ARCH" == "riscv64" ]]; then
    MAX_CPU_NUM="${MAX_CPU_NUM:-4}"
    if [[ "${MAX_CPU_NUM:-1}" -gt 1 ]]; then
        STARRY_QEMU_FEATURES="starryos/qemu,smp"
        # 须 ≤ ax-feat「page-alloc-4g」位图容量（约 4GiB 可映射页）；更大需改 kernel 为 page-alloc-64g。
        _phys="${STARRY_PHYS_MEMORY_SIZE:-0x100000000}" # 4 GiB
        AXGEN_EXTRA+=(-w "plat.max-cpu-num=${MAX_CPU_NUM}")
        AXGEN_EXTRA+=(-w "plat.phys-memory-size=${_phys}")
        log "riscv64 SMP: MAX_CPU_NUM=${MAX_CPU_NUM} plat.phys-memory-size=${_phys} features=${STARRY_QEMU_FEATURES}"
    else
        log "riscv64 UP: MAX_CPU_NUM=1 (QEMU -smp 1 / 与旧行为一致)"
    fi
fi

# ax-config-gen SPEC: 优先新路径 (os/arceos/configs/defconfig.toml)，回退旧路径 (make/defconfig.toml)。
_DEFCONFIG=""
for _dc in "$TGOSKITS/os/arceos/configs/defconfig.toml" "$(pwd)/make/defconfig.toml"; do
    [[ -f "$_dc" ]] && { _DEFCONFIG="$_dc"; break; }
done
[[ -n "$_DEFCONFIG" ]] || die "defconfig.toml not found (tried $TGOSKITS/os/arceos/configs/ and make/)"
ax-config-gen \
    "$_DEFCONFIG" "$PLAT_CONFIG" \
    -w "arch=\"$ARCH\"" \
    -w "platform=\"$PLAT_NAME\"" \
    ${AXGEN_EXTRA[@]+"${AXGEN_EXTRA[@]}"} \
    -o .axconfig.toml

# 2. 设置 axplat 需要的 env
export AX_ARCH="$ARCH"
export AX_PLATFORM="$PLAT_NAME"
export AX_MODE=release
export AX_LOG="${AX_LOG:-warn}"
export AX_TARGET="$RUST_TARGET"
export AX_IP=10.0.2.15
export AX_GW=10.0.2.2
export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"

cd "$TGOSKITS"
TARGET_DIR="$TGOSKITS/target"
LD_SCRIPT="$TARGET_DIR/$RUST_TARGET/release/linker_${PLAT_NAME}.lds"

# 3. 第一遍：生成 linker_<plat>.lds（axplat build script 出的）
# 不再丢弃 stderr：在 Docker / 大 workspace 下 pass1 可能失败或极慢，静默会导致「只打一行就卡住」的错觉。
log "[pass 1/2] cargo build (generate linker .lds)"
_pass1_log="${TMPDIR:-/tmp}/starry-pass1.$$.$RANDOM.log"
rm -f "$_pass1_log"
set +o pipefail
set +e
RUSTFLAGS="${RUSTFLAGS:-}" cargo build -p starryos \
    --target "$RUST_TARGET" --release \
    --features "$STARRY_QEMU_FEATURES" 2>&1 | tee "$_pass1_log"
_pass1_ec="${PIPESTATUS[0]}"
set -e
set -o pipefail
if [[ ! -f "$LD_SCRIPT" ]]; then
    log "pass 1/2 未生成 $LD_SCRIPT（cargo exit=$_pass1_ec），日志尾部："
    tail -n 120 "$_pass1_log" >&2 || true
    rm -f "$_pass1_log"
    die "linker script not generated: $LD_SCRIPT"
fi
rm -f "$_pass1_log"
log "LD_SCRIPT=$LD_SCRIPT"

# 4. 第二遍：真正链接
log "[pass 2/2] cargo build (with linker script)"
RUSTFLAGS="-C link-arg=-T$LD_SCRIPT -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
    cargo build -p starryos \
    --target "$RUST_TARGET" --release \
    --features "$STARRY_QEMU_FEATURES"

ELF="$TARGET_DIR/$RUST_TARGET/release/starryos"
if [[ -f "$ELF" ]]; then
    log "✓ build OK: $ELF"
    ls -lh "$ELF"
    cp "$ELF" "$TGOSKITS/os/StarryOS/starryos/starryos_${PLAT_NAME}.elf"
    log "✓ kernel ELF placed at os/StarryOS/starryos/starryos_${PLAT_NAME}.elf"
else
    die "expected $ELF not found"
fi

if [[ -n "${RECORD_LINUX_SYSCALL_SUMMARY:-}" && -f "${RECORD_LINUX_SYSCALL_SUMMARY}" ]]; then
    log "Linux strace syscall summary: ${RECORD_LINUX_SYSCALL_SUMMARY}"
    echo "===LINUX_BUILD_SYSCALL_SUMMARY_BEGIN==="
    echo "# file=${RECORD_LINUX_SYSCALL_SUMMARY}"
    echo "# context=host Linux strace -f -c for scripts/build.sh (compare to guest Starry /proc/syscall_stats blocks)"
    cat "${RECORD_LINUX_SYSCALL_SUMMARY}"
    echo "===LINUX_BUILD_SYSCALL_SUMMARY_END==="
fi
