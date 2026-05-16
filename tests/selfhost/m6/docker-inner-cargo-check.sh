#!/usr/bin/env bash
# 在容器内执行：生成 .axconfig.toml + 两遍 starryos 构建链中的「第二遍」用 cargo check 代替链接。
#
# 设计说明：
# - lwext4_rust 的 build.rs 需要 PATH 中有 riscv64-linux-musl-cc（与 scripts/setup-env.sh 一致）。
# - 真机 riscv64 + musl（如 Alpine guest）上 rustup 官方安装器当前不可用；因此默认镜像使用
#   **linux/amd64 + Ubuntu**，在容器内解压 arceos 的 **riscv64-linux-musl-cross** 预编译包。
# - 这样在 Docker 里即可稳定复现「与 Linux host 接近」的 starryos 构建依赖；与「QEMU 里同一
#   CPU 上跑 rustc」仍不同，但能验证 **cargo check -p starryos（riscv64gc-unknown-none-elf）** 可用。
set -euo pipefail

: "${WORKSPACE:=/workspace}"
TG="$WORKSPACE/tgoskits"

if [[ ! -f "$TG/Cargo.toml" ]]; then
    echo "FAIL: $TG/Cargo.toml 不存在（确认 submodule tgoskits 已初始化）" >&2
    exit 1
fi

bootstrap_ubuntu_amd64() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates git build-essential pkg-config \
        libssl-dev cmake python3 xz-utils clang libclang1-18 libclang-18-dev llvm-18-dev

    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "x86_64" ]]; then
        echo "FAIL: 当前 M6 容器为 $arch，仅内置了 x86_64 主机的 riscv64-linux-musl-cross 预编译包。" >&2
        echo "请在 scripts/m6-docker-riscvlinux-cargo-check.sh 中使用 docker --platform linux/amd64。" >&2
        exit 1
    fi

    if [[ ! -x /opt/riscv64-linux-musl-cross/bin/riscv64-linux-musl-gcc ]]; then
        echo "[m6-inner] 安装 /opt/riscv64-linux-musl-cross（arceos 预编译）…"
        mkdir -p /opt
        curl -fL \
            "https://github.com/arceos-org/setup-musl/releases/download/prebuilt/riscv64-linux-musl-cross.tgz" \
            | tar -C /opt -xz
    fi
    export PATH="/opt/riscv64-linux-musl-cross/bin:$PATH"
    command -v riscv64-linux-musl-cc >/dev/null 2>&1 || {
        echo "FAIL: riscv64-linux-musl-cc 不在 PATH" >&2
        exit 1
    }

    # bindgen（依赖链）需要 libclang（Ubuntu 24.04 常见路径）
    if [[ -d /usr/lib/llvm-18/lib ]]; then
        export LIBCLANG_PATH=/usr/lib/llvm-18/lib
    elif [[ -d /usr/lib/llvm-17/lib ]]; then
        export LIBCLANG_PATH=/usr/lib/llvm-17/lib
    else
        local _clang_so
        _clang_so="$(find /usr/lib -name 'libclang.so.*' -type f 2>/dev/null | sort -V | tail -1)"
        if [[ -n "$_clang_so" ]]; then
            export LIBCLANG_PATH="$(dirname "$_clang_so")"
        fi
    fi
    if [[ -z "${LIBCLANG_PATH:-}" || ! -d "$LIBCLANG_PATH" ]]; then
        echo "FAIL: 无法设置 LIBCLANG_PATH（已装 libclang1-18？）" >&2
        exit 1
    fi
    echo "[m6-inner] LIBCLANG_PATH=$LIBCLANG_PATH"
}

bootstrap_ubuntu_amd64

if ! command -v rustc >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi
# shellcheck source=/dev/null
source "$HOME/.cargo/env"

rustup target add riscv64gc-unknown-none-elf
rustup component add rust-src llvm-tools-preview 2>/dev/null || true

export PATH="$HOME/.cargo/bin:$PATH"
if [[ ! -x "$HOME/.cargo/bin/ax-config-gen" ]] || [[ ! -x "$HOME/.cargo/bin/cargo-axplat" ]]; then
    cargo install ax-config-gen cargo-axplat
fi

export CARGO_NET_GIT_FETCH_WITH_CLI=true
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

ARCH=riscv64
PLAT_PACKAGE=ax-plat-riscv64-qemu-virt
RUST_TARGET=riscv64gc-unknown-none-elf

cd "$TG/os/StarryOS"
PLAT_CONFIG="$(cargo axplat info -C starryos -c "$PLAT_PACKAGE" 2>/dev/null | tail -1)"
[[ -n "$PLAT_CONFIG" && -f "$PLAT_CONFIG" ]] || {
    echo "FAIL: 无法解析 PLAT_CONFIG（cargo axplat）: $PLAT_CONFIG" >&2
    exit 1
}
PLAT_NAME="$(awk -F'"' '$1 ~ /^platform[[:space:]]*=/ {print $2}' "$PLAT_CONFIG" | head -1)"
[[ -n "$PLAT_NAME" ]] || {
    echo "FAIL: 无法从 $PLAT_CONFIG 读取 platform" >&2
    exit 1
}

ax-config-gen \
    "$(pwd)/make/defconfig.toml" "$PLAT_CONFIG" \
    -w "arch=\"$ARCH\"" \
    -w "platform=\"$PLAT_NAME\"" \
    -o .axconfig.toml

export AX_ARCH="$ARCH"
export AX_PLATFORM="$PLAT_NAME"
export AX_MODE=release
export AX_LOG="${AX_LOG:-warn}"
export AX_TARGET="$RUST_TARGET"
export AX_IP=10.0.2.15
export AX_GW=10.0.2.2
export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"

cd "$TG"
TARGET_DIR="$TG/target"
LD_SCRIPT="$TARGET_DIR/$RUST_TARGET/release/linker_${PLAT_NAME}.lds"

echo "[m6-inner] pass 1/2: 生成 linker_${PLAT_NAME}.lds"
RUSTFLAGS="${RUSTFLAGS:-}" cargo build -p starryos \
    --target "$RUST_TARGET" --release \
    --features starryos/qemu 2>/dev/null || true

[[ -f "$LD_SCRIPT" ]] || {
    echo "FAIL: 未生成链接脚本: $LD_SCRIPT" >&2
    exit 1
}

echo "[m6-inner] pass 2/2: cargo check（不产出最终 ELF，但走同一 RUSTFLAGS / 依赖解析）"
RUSTFLAGS="-C link-arg=-T$LD_SCRIPT -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
    cargo check -p starryos \
    --target "$RUST_TARGET" --release \
    --features starryos/qemu

echo "===M6-DOCKER-CARGO-CHECK-PASS==="
