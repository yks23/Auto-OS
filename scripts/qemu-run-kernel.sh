#!/usr/bin/env bash
# 用 QEMU 启动指定的 starry kernel ELF，串口连到 4444，让外部能 attach。
#
# 用法：
#   scripts/qemu-run-kernel.sh ARCH=riscv64 KERNEL=path/to/elf [DISK=path/to/img] [TIMEOUT=120]
#
# 启动后 QEMU 在前台跑；外部用 `nc localhost $SERIAL_TCP_PORT` 接进 BusyBox shell。
# 串口 TCP 端口默认 4444；若 Address already in use：`SERIAL_TCP_PORT=4445 bash scripts/qemu-run-kernel.sh ...`
#
# virtio-net：默认 **不** 插网卡（与 StarryOS/Makefile 里 NET?=n 一致）。需要 user 网时：
#   QEMU_RUN_NET=1 bash scripts/qemu-run-kernel.sh ARCH=... KERNEL=...
# 否则早期引导可能访问未就绪的 PCI BAR，QEMU guest_errors 出现 Invalid read/write。
#
# SERIAL_MODE=stdio：用 **-display none** + **-serial stdio**（访客 COM1 直连终端）。
# 勿与 **-nographic** 同时用于 stdio：-nographic 也会接管 stdio，叠 `-serial stdio` 后常见「只有
# [qemu-run] 一行、再无访客输出」。tcp 模式仍用 -nographic + 串口重定向到 TCP。
# 勿用 mon:stdio 作为默认：监视器/串口复用，默认停在监视器侧，需 Ctrl+a 再 c 才见串口。
#
# RISC-V：axplat-riscv64-qemu-virt 的 axconfig 仅声明 128MiB 物理内存；若 QEMU -m 过大，
# OpenSBI 会把 DTB 放在高位物理页，内核按 128MiB 模型访问会触发 S 态 page fault。
# 因此 riscv64 固定 -m 128M -smp 1，并把 ELF strip 成与 Starry Makefile 一致的 flat binary
# 再交给 -kernel（QEMU 8.x 下直接 -kernel ELF 在本组合上可能长时间无输出）。
set -euo pipefail

# `sudo bash` 常带 secure_path，root 找不到 rustc/llvm-objcopy；补齐常见安装位置。
for _p in /usr/local/cargo/bin /home/ubuntu/.cargo/bin "${HOME}/.cargo/bin"; do
    [[ -d "$_p" ]] && PATH="$_p:${PATH:-}"
done
for _p in /opt/riscv64-linux-musl-cross/bin /opt/x86_64-linux-musl-cross/bin; do
    [[ -d "$_p" ]] && PATH="$_p:${PATH:-}"
done
if [[ -n "${SUDO_USER:-}" ]]; then
    _uh="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -d "$_uh/.cargo/bin" ]] && PATH="$_uh/.cargo/bin:${PATH:-}"
fi
export PATH

ARCH=""
KERNEL=""
DISK=""
DISK2="${DISK2:-}"
TIMEOUT=120
SERIAL_MODE="${SERIAL_MODE:-tcp}"  # tcp | stdio
SERIAL_TCP_PORT="${SERIAL_TCP_PORT:-4444}"
for arg in "$@"; do
    case "$arg" in
        ARCH=*)   ARCH="${arg#ARCH=}" ;;
        KERNEL=*) KERNEL="${arg#KERNEL=}" ;;
        DISK=*)   DISK="${arg#DISK=}" ;;
        DISK2=*)  DISK2="${arg#DISK2=}" ;;
        TIMEOUT=*) TIMEOUT="${arg#TIMEOUT=}" ;;
        SERIAL_MODE=*) SERIAL_MODE="${arg#SERIAL_MODE=}" ;;
        SERIAL_TCP_PORT=*) SERIAL_TCP_PORT="${arg#SERIAL_TCP_PORT=}" ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

[[ -n "$ARCH" ]] || { echo "ARCH required" >&2; exit 1; }
[[ -n "$KERNEL" && -f "$KERNEL" ]] || { echo "KERNEL not found: $KERNEL" >&2; exit 1; }

# axplat x86-pc / riscv64-qemu-virt：phys-memory-size=0x800_0000, max-cpu-num=1
GUEST_MEM="${GUEST_MEM:-128M}"
GUEST_SMP="${GUEST_SMP:-1}"

KERNEL_FOR_QEMU="$KERNEL"
RV_BIN_TMP=""
cleanup_rv_bin() { [[ -n "$RV_BIN_TMP" && -f "$RV_BIN_TMP" ]] && rm -f "$RV_BIN_TMP"; }
trap cleanup_rv_bin EXIT

if [[ "$ARCH" == "riscv64" ]]; then
    oc=""
    # PATH 里可能有 Docker/Linux 自带的 musl-objcopy，在 macOS 上会「cannot execute binary file」；
    # 只有能实际跑通 --version 的才采用，否则回退到 rustc 自带的 llvm-objcopy。
    if command -v riscv64-linux-musl-objcopy >/dev/null 2>&1 \
        && riscv64-linux-musl-objcopy --version >/dev/null 2>&1; then
        oc=riscv64-linux-musl-objcopy
    fi
    if [[ -z "$oc" ]]; then
        host=$(rustc -vV 2>/dev/null | sed -n 's/^host: //p') || host=""
        if [[ -n "$host" && -f "$(rustc --print sysroot 2>/dev/null)/lib/rustlib/$host/bin/llvm-objcopy" ]]; then
            oc="$(rustc --print sysroot)/lib/rustlib/$host/bin/llvm-objcopy"
        else
            shopt -s nullglob
            _llvm=(/usr/local/rustup/toolchains/*/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-objcopy)
            shopt -u nullglob
            ((${#_llvm[@]})) && oc="${_llvm[0]}"
        fi
        if [[ -z "$oc" ]] && command -v llvm-objcopy >/dev/null; then
            oc=llvm-objcopy
        fi
    fi
    if [[ -z "$oc" ]]; then
        echo "riscv64: need riscv64-linux-musl-objcopy or llvm-objcopy to flatten kernel ELF" >&2
        exit 1
    fi
    RV_BIN_TMP="$(mktemp "${TMPDIR:-/tmp}/starry-rv-kernel.XXXXXX.bin")"
    if [[ "$oc" == riscv64-linux-musl-objcopy ]]; then
        "$oc" -O binary "$KERNEL" "$RV_BIN_TMP"
    else
        "$oc" -I elf64-littleriscv -O binary "$KERNEL" "$RV_BIN_TMP"
    fi
    KERNEL_FOR_QEMU="$RV_BIN_TMP"
fi

case "$ARCH" in
    riscv64)
        QEMU=qemu-system-riscv64
        # qemu-virt riscv64 + opensbi（-nographic 仅 tcp 模式追加，见下方 SERIAL_MODE）
        QEMU_BASE=(
            -machine virt
            -bios default
            -smp "$GUEST_SMP"
            -m "$GUEST_MEM"
            -kernel "$KERNEL_FOR_QEMU"
            -cpu rv64
        )
        ;;
    x86_64)
        QEMU=qemu-system-x86_64
        # 须与 tgoskits/os/StarryOS/make/qemu.mk 一致：ax-plat-x86-pc 使用 q35（默认 pc 会导致 virtio PCI BAR 错位、guest_errors 里 Invalid read/write）
        QEMU_BASE=(
            -machine q35
            -smp "$GUEST_SMP"
            -m "$GUEST_MEM"
            -kernel "$KERNEL"
        )
        ;;
    *) echo "unknown ARCH: $ARCH" >&2; exit 1 ;;
esac

QEMU_ARGS=("${QEMU_BASE[@]}" -monitor none)
case "$SERIAL_MODE" in
    tcp)
        QEMU_ARGS=( -nographic "${QEMU_ARGS[@]}" -serial "tcp::${SERIAL_TCP_PORT},server=on,wait=on" )
        ;;
    stdio)
        # 不用 -nographic，避免与 -serial stdio 争用同一 chardev（Docker/arm64 TCG 下常无输出）
        QEMU_ARGS+=( -display none )
        if [[ "$ARCH" == "x86_64" ]]; then
            QEMU_ARGS+=( -vga none )
        fi
        QEMU_ARGS+=( -serial stdio )
        ;;
    *) echo "bad SERIAL_MODE: $SERIAL_MODE" >&2; exit 1 ;;
esac

if [[ -n "$DISK" && -f "$DISK" ]]; then
    QEMU_ARGS+=(
        -device virtio-blk-pci,drive=disk0
        -drive "id=disk0,if=none,format=raw,file=$DISK"
    )
fi

if [[ -n "${DISK2:-}" && -f "${DISK2}" ]]; then
    QEMU_ARGS+=(
        -device virtio-blk-pci,drive=disk1
        -drive "id=disk1,if=none,format=raw,file=$DISK2"
    )
fi

if [[ "${QEMU_RUN_NET:-0}" == "1" ]]; then
    QEMU_ARGS+=(
        -device virtio-net-pci,netdev=net0
        -netdev user,id=net0
    )
fi

if [[ "$SERIAL_MODE" == "stdio" && ! -t 0 ]]; then
    echo "[qemu-run] warning: stdin 不是终端 (-t 0 失败)，-serial stdio 下 QEMU 常立刻退出且无访客输出。" >&2
    echo "[qemu-run] 请确认: docker run 带 **-it**；或改用 SERIAL_MODE=tcp，宿主机再 nc 127.0.0.1 4444（需 --network host）。" >&2
fi

echo "[qemu-run] starting: $QEMU ${QEMU_ARGS[*]}" >&2
# macOS 通常无 GNU coreutils 的 `timeout`；用 perl alarm 兜底。
if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "$QEMU" "${QEMU_ARGS[@]}"
elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT" "$QEMU" "${QEMU_ARGS[@]}"
else
    perl -e 'alarm shift @ARGV; exec {$ARGV[0]} @ARGV' "$TIMEOUT" "$QEMU" "${QEMU_ARGS[@]}"
fi
rc=$?
echo "[qemu-run] qemu finished exit_code=$rc" >&2
cleanup_rv_bin
trap - EXIT
exit "$rc"
