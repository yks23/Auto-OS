#!/bin/sh
# 按 BuildKit 的 TARGETARCH 安装 lwext4_rust 所需的 riscv64-linux-musl-* 工具名。
# - amd64：arceos 预编译 musl 交叉（x86_64 宿主），解压到 /opt/riscv64-linux-musl-cross
# - arm64：同包为 **i686 静态** 宿主二进制；在 aarch64 容器内用 qemu-i386-static 包装，
#   避免仅用 Ubuntu 的 riscv64-linux-gnu-gcc（会拉 glibc 头文件，与 lwext4 的 ULIBC 路径冲突）
set -eu
t="${TARGETARCH:-}"
case "$t" in
    amd64)
        mkdir -p /opt
        curl -fL \
            "https://github.com/arceos-org/setup-musl/releases/download/prebuilt/riscv64-linux-musl-cross.tgz" \
            | tar -C /opt -xz
        ;;
    arm64)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends qemu-user-static
        mkdir -p /opt
        curl -fL \
            "https://github.com/arceos-org/setup-musl/releases/download/prebuilt/riscv64-linux-musl-cross.tgz" \
            | tar -C /opt -xz
        mkdir -p /usr/local/bin
        QEMU_I386=/usr/bin/qemu-i386-static
        MUSL_BIN=/opt/riscv64-linux-musl-cross/bin
        for src in "$MUSL_BIN"/riscv64-linux-musl-*; do
            [ -f "$src" ] || continue
            [ -x "$src" ] || continue
            base=$(basename "$src")
            printf '%s\n' '#!/bin/sh' "exec $QEMU_I386 \"$src\" \"\$@\"" >"/usr/local/bin/$base"
            chmod +x "/usr/local/bin/$base"
        done
        rm -rf /var/lib/apt/lists/*
        ;;
    *)
        echo "install-riscv-musl-cross: unsupported TARGETARCH='$t' (need amd64 or arm64)" >&2
        exit 1
        ;;
esac
