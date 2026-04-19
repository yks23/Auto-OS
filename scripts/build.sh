#!/usr/bin/env bash
# Build StarryOS kernel ELF for the given ARCH.
#
# 用法：
#   scripts/build.sh ARCH=riscv64                # build kernel ELF (release)
#   scripts/build.sh ARCH=x86_64                 # build kernel ELF (release)
#   scripts/build.sh ARCH=riscv64 TARGET=ci-test # ci-test (需要 rootfs)
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
PLAT_CONFIG=$(cargo axplat info -C starryos -c "$PLAT_PACKAGE" 2>/dev/null | tail -1)
if [[ -z "$PLAT_CONFIG" || ! -f "$PLAT_CONFIG" ]]; then
    die "could not resolve PLAT_CONFIG for $PLAT_PACKAGE (got: $PLAT_CONFIG)"
fi
log "PLAT_CONFIG=$PLAT_CONFIG"

PLAT_NAME=$(awk -F'"' '$1 ~ /^platform[[:space:]]*=/ {print $2}' "$PLAT_CONFIG" | head -1)
log "PLAT_NAME=$PLAT_NAME"

ax-config-gen \
    "$(pwd)/make/defconfig.toml" "$PLAT_CONFIG" \
    -w "arch=\"$ARCH\"" \
    -w "platform=\"$PLAT_NAME\"" \
    -o .axconfig.toml

# 2. 设置 axplat 需要的 env
export AX_ARCH="$ARCH"
export AX_PLATFORM="$PLAT_NAME"
export AX_MODE=release
export AX_LOG=warn
export AX_TARGET="$RUST_TARGET"
export AX_IP=10.0.2.15
export AX_GW=10.0.2.2
export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"

cd "$TGOSKITS"
TARGET_DIR="$TGOSKITS/target"
LD_SCRIPT="$TARGET_DIR/$RUST_TARGET/release/linker_${PLAT_NAME}.lds"

# 3. 第一遍：生成 linker_<plat>.lds（axplat build script 出的）
log "[pass 1/2] cargo build (generate linker .lds)"
RUSTFLAGS="${RUSTFLAGS:-}" cargo build -p starryos \
    --target "$RUST_TARGET" --release \
    --features starryos/qemu 2>/dev/null || true

if [[ ! -f "$LD_SCRIPT" ]]; then
    die "linker script not generated: $LD_SCRIPT"
fi
log "LD_SCRIPT=$LD_SCRIPT"

# 4. 第二遍：真正链接
log "[pass 2/2] cargo build (with linker script)"
RUSTFLAGS="-C link-arg=-T$LD_SCRIPT -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
    cargo build -p starryos \
    --target "$RUST_TARGET" --release \
    --features starryos/qemu

ELF="$TARGET_DIR/$RUST_TARGET/release/starryos"
if [[ -f "$ELF" ]]; then
    log "✓ build OK: $ELF"
    ls -lh "$ELF"
    cp "$ELF" "$TGOSKITS/os/StarryOS/starryos/starryos_${PLAT_NAME}.elf"
    log "✓ kernel ELF placed at os/StarryOS/starryos/starryos_${PLAT_NAME}.elf"
else
    die "expected $ELF not found"
fi
