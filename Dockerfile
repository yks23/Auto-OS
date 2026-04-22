# StarryOS self-host build environment.
#
# This single image contains everything needed to:
#   - cross-build the StarryOS riscv64 kernel ELF
#   - build a self-host rootfs (alpine-based, with rust toolchain in-guest)
#   - run the kernel under qemu-system-riscv64
#   - run guest-side demos (M5: cargo build hello, M6: cargo build starry kernel)
#
# Built on top of Ubuntu 24.04 so the layout matches our existing scripts.
# Pinned rust nightly comes from tgoskits/rust-toolchain.toml — rustup will
# auto-fetch on first cargo invocation.
#
# Usage from the user side (host needs only docker):
#
#   docker build -t auto-os/starry -f Dockerfile .
#   docker run --rm --privileged --network host \
#       -v "$PWD:/work" -w /work \
#       auto-os/starry bash scripts/reproduce-in-container.sh
#
# --privileged is needed because the rootfs builder mounts loop devices and
# uses binfmt_misc for cross-architecture chroot. --network host because the
# default docker bridge is often blocked in nested / CI environments.

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
    PATH=/usr/local/cargo/bin:/usr/local/rustup/bin:/opt/riscv64-linux-musl-cross/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain nightly-2026-04-01 --profile minimal \
            --component rust-src --component llvm-tools-preview \
            --target riscv64gc-unknown-none-elf

# 3. cargo helper subcommands the StarryOS Makefile / scripts use.
RUN cargo install cargo-axplat ax-config-gen cargo-binutils

# 4. arceos prebuilt riscv64-linux-musl-cross (lwext4_rust build script
#    invokes riscv64-linux-musl-gcc).
RUN curl -fL https://github.com/arceos-org/setup-musl/releases/download/prebuilt/riscv64-linux-musl-cross.tgz \
        | tar -C /opt -xz

# Symlink ipxe roms into qemu's expected lookup path. qemu searches
# /usr/share/qemu/<rom>; debian/ubuntu's ipxe-qemu lays them out under
# /usr/lib/ipxe/qemu/.
RUN for r in efi-virtio.rom efi-e1000.rom efi-rtl8139.rom efi-vmxnet3.rom \
             pxe-virtio.rom pxe-e1000.rom pxe-rtl8139.rom; do \
        [ -e "/usr/share/qemu/$r" ] && continue; \
        [ -e "/usr/lib/ipxe/qemu/$r" ] && \
            ln -sf "/usr/lib/ipxe/qemu/$r" "/usr/share/qemu/$r" || true; \
    done

# 5. Helper: register binfmt at container start (binfmt_misc lives in the host
#    kernel; --privileged is required for write access). Wrapper script does
#    nothing if it's already registered.
COPY docker/register-binfmt.sh /usr/local/bin/register-binfmt
RUN chmod +x /usr/local/bin/register-binfmt

# Default: run /usr/local/bin/register-binfmt then drop into bash.
WORKDIR /work
ENTRYPOINT ["/bin/bash", "-lc", "register-binfmt; exec \"$@\"", "--"]
CMD ["bash"]
