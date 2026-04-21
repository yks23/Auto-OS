#!/usr/bin/env bash
# setup-env.sh — 一键装齐所有复现依赖（Ubuntu/Debian 可用）
#
# 需要 sudo 权限。幂等：每步前先检测再装。不会影响已有的 rustup toolchain。
#
# 用法：  sudo bash scripts/setup-env.sh
#         或  bash scripts/setup-env.sh   （自己 sudo）

set -euo pipefail

SUDO=""
if [[ $(id -u) -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "error: 需要 root 或 sudo 来装系统包，当前既不是 root 也没有 sudo" >&2
        exit 1
    fi
fi

log() { printf '[setup-env] %s\n' "$*"; }

# ---------------------------------------------------------------- apt packages
if command -v apt-get >/dev/null 2>&1; then
    log "apt-get update"
    $SUDO apt-get update -y

    log "apt-get install: build toolchain, qemu, binfmt-support"
    $SUDO apt-get install -y --no-install-recommends \
        build-essential \
        git curl tar xz-utils sudo ca-certificates \
        e2fsprogs \
        qemu-system-misc qemu-user-static binfmt-support \
        python3 \
        pkg-config
else
    log "WARN: not an apt-based system — please install the equivalents of:"
    log "  build-essential git curl tar xz-utils e2fsprogs qemu-system-misc"
    log "  qemu-user-static binfmt-support python3 pkg-config"
fi

# ------------------------------------------------------------ riscv64 binfmt
# Some distros need this explicitly even if qemu-user-static is installed.
if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]]; then
    if command -v update-binfmts >/dev/null 2>&1; then
        log "registering binfmt_misc handlers via update-binfmts --enable"
        $SUDO update-binfmts --enable qemu-riscv64 || true
    fi
fi
if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]]; then
    log "registering binfmt_misc handler manually"
    $SUDO bash -c '[[ ! -d /proc/sys/fs/binfmt_misc ]] || echo ":qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-riscv64-static:OCF" > /proc/sys/fs/binfmt_misc/register' 2>/dev/null || true
fi

# ----------------------------------------------------- rustup + cross targets
if ! command -v rustup >/dev/null 2>&1; then
    log "installing rustup (default + nightly channel) for the invoking user"
    # curl into a tmp script so we can set -y flags.
    TMP_RUSTUP="$(mktemp)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$TMP_RUSTUP"
    # Run as the invoking user, NOT as root.
    if [[ -n "${SUDO_USER:-}" ]]; then
        TARGET_USER="$SUDO_USER"
        TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
        $SUDO -u "$TARGET_USER" env HOME="$TARGET_HOME" sh "$TMP_RUSTUP" -y \
            --default-toolchain nightly --profile minimal
    else
        sh "$TMP_RUSTUP" -y --default-toolchain nightly --profile minimal
    fi
    rm -f "$TMP_RUSTUP"
fi

# rustup target + components — run as invoking user
RUN_AS_USER() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        $SUDO -u "$SUDO_USER" env HOME="$TARGET_HOME" PATH="$TARGET_HOME/.cargo/bin:$PATH" "$@"
    else
        "$@"
    fi
}

if command -v rustup >/dev/null 2>&1 || RUN_AS_USER true; then
    log "rustup target add riscv64gc-unknown-none-elf"
    RUN_AS_USER rustup target add riscv64gc-unknown-none-elf || true
    log "rustup component add rust-src llvm-tools-preview"
    RUN_AS_USER rustup component add rust-src llvm-tools-preview || true
fi

# ------------------------------------------ musl cross toolchain (arceos prebuilt)
if [[ ! -x /opt/riscv64-linux-musl-cross/bin/riscv64-linux-musl-gcc ]]; then
    log "fetching arceos prebuilt riscv64-linux-musl-cross into /opt"
    $SUDO mkdir -p /opt
    TMP_TGZ="$(mktemp --suffix=.tgz)"
    curl -fL -o "$TMP_TGZ" \
        "https://github.com/arceos-org/setup-musl/releases/download/prebuilt/riscv64-linux-musl-cross.tgz"
    $SUDO tar -C /opt -xzf "$TMP_TGZ"
    rm -f "$TMP_TGZ"
fi

log "done."
log
log "next step — add musl cross to PATH in your shell, then verify:"
log "    export PATH=/opt/riscv64-linux-musl-cross/bin:\$PATH"
log "    bash scripts/check-env.sh"
