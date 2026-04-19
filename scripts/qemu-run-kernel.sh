#!/usr/bin/env bash
# 用 QEMU 启动指定的 starry kernel ELF，串口连到 4444，让外部能 attach。
#
# 用法：
#   scripts/qemu-run-kernel.sh ARCH=riscv64 KERNEL=path/to/elf [DISK=path/to/img] [TIMEOUT=120]
#
# 启动后 QEMU 在前台跑；外部用 `nc localhost 4444` 接进 BusyBox shell。
set -euo pipefail

ARCH=""
KERNEL=""
DISK=""
TIMEOUT=120
for arg in "$@"; do
    case "$arg" in
        ARCH=*)   ARCH="${arg#ARCH=}" ;;
        KERNEL=*) KERNEL="${arg#KERNEL=}" ;;
        DISK=*)   DISK="${arg#DISK=}" ;;
        TIMEOUT=*) TIMEOUT="${arg#TIMEOUT=}" ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

[[ -n "$ARCH" ]] || { echo "ARCH required" >&2; exit 1; }
[[ -n "$KERNEL" && -f "$KERNEL" ]] || { echo "KERNEL not found: $KERNEL" >&2; exit 1; }

case "$ARCH" in
    riscv64)
        QEMU=qemu-system-riscv64
        # qemu-virt riscv64 + opensbi
        QEMU_BASE=(
            -nographic
            -machine virt
            -bios default
            -smp 4
            -m 4G
            -kernel "$KERNEL"
            -cpu rv64
        )
        ;;
    x86_64)
        QEMU=qemu-system-x86_64
        QEMU_BASE=(
            -nographic
            -smp 4
            -m 4G
            -kernel "$KERNEL"
        )
        ;;
    *) echo "unknown ARCH: $ARCH" >&2; exit 1 ;;
esac

QEMU_ARGS=(
    "${QEMU_BASE[@]}"
    -monitor none
    -serial tcp::4444,server=on,wait=on
)

if [[ -n "$DISK" && -f "$DISK" ]]; then
    QEMU_ARGS+=(
        -device virtio-blk-pci,drive=disk0
        -drive "id=disk0,if=none,format=raw,file=$DISK"
    )
fi

QEMU_ARGS+=(
    -device virtio-net-pci,netdev=net0
    -netdev user,id=net0
)

echo "[qemu-run] starting: $QEMU ${QEMU_ARGS[*]}" >&2
exec timeout "$TIMEOUT" "$QEMU" "${QEMU_ARGS[@]}"
