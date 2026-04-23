#!/bin/sh
# 安装 lwext4_rust 所需的 *-linux-musl-* 交叉链（与 scripts/build.sh 里 /opt/<arch>-linux-musl-cross 约定一致）。
#
# - amd64 宿主镜像：riscv64 + x86_64 的 arceos 预编译包（riscv 包内为 i686 宿主，可在 x86_64 上直接跑）
# - arm64 宿主镜像：同包 + qemu-user-static；riscv 用 qemu-i386；x86_64 用 qemu-x86_64；
#   aarch64 包一般为 AArch64 宿主，在 arm64 容器内原生执行
set -eu
t="${TARGETARCH:-}"
ARCEOS_URL="https://github.com/arceos-org/setup-musl/releases/download/prebuilt"

fetch_tgz() {
    name="$1"
    curl -fL "${ARCEOS_URL}/${name}.tgz" | tar -C /opt -xz
}

# 在 prefix/bin 下用 qemu 包装「非本机 ISA」的可执行文件（把原 bin 挪到 bin.real）
wrap_prefix_with_qemu() {
    qemu="$1"
    prefix="$2"
    glob="$3"
    [ -d "$prefix/bin" ] || return 0
    mv "$prefix/bin" "$prefix/bin.real"
    mkdir "$prefix/bin"
    for src in $glob; do
        [ -f "$src" ] || continue
        [ -x "$src" ] || continue
        base=$(basename "$src")
        printf '%s\n' '#!/bin/sh' "exec $qemu \"$src\" \"\$@\"" >"$prefix/bin/$base"
        chmod +x "$prefix/bin/$base"
    done
}

# riscv 包：i686 宿主；在 arm64 上必须 qemu-i386。包装写到 /usr/local/bin 以便早于 /opt 出现在 PATH。
wrap_riscv_i386_to_local() {
    QEMU_I386=/usr/bin/qemu-i386-static
    MUSL_BIN=/opt/riscv64-linux-musl-cross/bin
    mkdir -p /usr/local/bin
    for src in "$MUSL_BIN"/riscv64-linux-musl-*; do
        [ -f "$src" ] || continue
        [ -x "$src" ] || continue
        base=$(basename "$src")
        printf '%s\n' '#!/bin/sh' "exec $QEMU_I386 \"$src\" \"\$@\"" >"/usr/local/bin/$base"
        chmod +x "/usr/local/bin/$base"
    done
}

case "$t" in
    amd64)
        mkdir -p /opt
        fetch_tgz riscv64-linux-musl-cross
        fetch_tgz x86_64-linux-musl-cross
        ;;
    arm64)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends qemu-user-static
        mkdir -p /opt
        fetch_tgz riscv64-linux-musl-cross
        wrap_riscv_i386_to_local
        fetch_tgz x86_64-linux-musl-cross
        wrap_prefix_with_qemu /usr/bin/qemu-x86_64-static /opt/x86_64-linux-musl-cross \
            "/opt/x86_64-linux-musl-cross/bin.real/x86_64-linux-musl-*"
        # aarch64-linux-musl：arceos 同名包宿主 ISA 因版本而异，未校验前不装入，以免 arm64 镜像构建失败。
        rm -rf /var/lib/apt/lists/*
        ;;
    *)
        echo "install-riscv-musl-cross: unsupported TARGETARCH='$t' (need amd64 or arm64)" >&2
        exit 1
        ;;
esac
