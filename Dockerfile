# StarryOS self-host build environment.
#
# This single image contains everything needed to:
#   - cross-build the StarryOS riscv64 kernel ELF
#   - build a self-host rootfs (alpine-based, with rust toolchain in-guest)
#   - run the kernel under qemu-system-riscv64 / qemu-system-x86_64（arm64 镜像需 qemu-system-x86 包）
#   - run guest-side demos (M5: cargo build hello, M6: cargo build starry kernel)
#
# Built on top of Ubuntu 24.04 so the layout matches our existing scripts.
# Pinned rust nightly comes from tgoskits/rust-toolchain.toml — rustup will
# auto-fetch on first cargo invocation.
#
# Usage（--platform 须与宿主策略一致；reproduce-all.sh 会替你选）:
#
#   docker build --platform linux/amd64 -t auto-os/starry -f Dockerfile .
#   docker run --rm --platform linux/amd64 --privileged --network host -v "$PWD:/work" -w /work auto-os/starry bash scripts/reproduce-in-container.sh
#
# 镜像用户态平台（由 docker build --platform 决定 TARGETARCH）：
# - linux/amd64：arceos 预编译 riscv64 + x86_64 musl 交叉（lwext4 / build.sh 多 ARCH）
# - linux/arm64：riscv64 / x86_64 musl 包均为 i386 宿主 gcc，统一用 qemu-i386-static 包装
# Apple Silicon 上默认用 arm64 原生用户态，避免 Desktop 对 linux/amd64 的 QEMU/Rosetta
# 链导致 unpigz/runc exec format error。
#
# --privileged: rootfs 需要 loop + binfmt_misc。--network host: 部分网络环境需要。

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# 1. apt deps: build essentials, qemu (system + user), binfmt-support, e2fsprogs,
#    plus everything required for the rootfs builder (chroot + mkfs.ext4 + xz).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        libclang-dev \
        llvm \
        e2fsprogs \
        gdisk \
        git \
        make \
        pkg-config \
        python3 \
        qemu-system-misc \
        qemu-system-x86 \
        qemu-system-data \
        qemu-user-static \
        binfmt-support \
        ipxe-qemu \
        sudo \
        tar \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Allow git operations on bind-mounted /work even when host UID != container UID
RUN git config --global --add safe.directory '*'

# 2. rustup + nightly (matches tgoskits/rust-toolchain.toml). We also add the
#    cross targets and components we always need.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/rustup/bin:/usr/local/bin:/opt/riscv64-linux-musl-cross/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain nightly-2026-04-01 --profile minimal \
            --component rust-src --component llvm-tools-preview \
            --target riscv64gc-unknown-none-elf

# 3. cargo helper subcommands the StarryOS Makefile / scripts use.
RUN cargo install cargo-axplat ax-config-gen cargo-binutils

# 4. lwext4_rust 需要 riscv64-linux-musl-cc（TARGETARCH 见 docker/install-riscv-musl-cross.sh）
ARG TARGETARCH
COPY docker/install-riscv-musl-cross.sh /tmp/install-riscv-musl-cross.sh
RUN chmod +x /tmp/install-riscv-musl-cross.sh \
    && TARGETARCH="${TARGETARCH}" /tmp/install-riscv-musl-cross.sh \
    && rm -f /tmp/install-riscv-musl-cross.sh

# Symlink ipxe roms into qemu's expected lookup path. qemu searches
# /usr/share/qemu/<rom>; debian/ubuntu's ipxe-qemu lays them out under
# /usr/lib/ipxe/qemu/.
RUN for r in efi-virtio.rom efi-e1000.rom efi-rtl8139.rom efi-vmxnet3.rom \
             pxe-virtio.rom pxe-e1000.rom pxe-rtl8139.rom; do \
        [ -e "/usr/share/qemu/$r" ] && continue; \
        [ -e "/usr/lib/ipxe/qemu/$r" ] && \
            ln -sf "/usr/lib/ipxe/qemu/$r" "/usr/share/qemu/$r" || true; \
    done

# 5. binfmt 注册脚本：由 reproduce-in-container / rootfs 脚本在适当时机调用（勿在
#    容器 PID1 入口最先执行，否则在部分 Docker Desktop 环境下会破坏随后 exec bash）。
COPY docker/register-binfmt.sh /usr/local/bin/register-binfmt
RUN chmod +x /usr/local/bin/register-binfmt

COPY docker/entrypoint-work.sh /usr/local/bin/entrypoint-work
RUN chmod +x /usr/local/bin/entrypoint-work

# 入口仅 exec "$@"；binfmt 见上。
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint-work"]
CMD ["bash"]
