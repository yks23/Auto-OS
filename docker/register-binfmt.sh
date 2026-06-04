#!/bin/sh
# 注册 qemu-riscv64 binfmt（供 chroot 进 riscv64 Alpine 等）。幂等。
# 优先使用 Ubuntu/Debian 自带的 update-binfmts（与 qemu-user-static 一致），避免手写
# printf 规则在 aarch64 宿主（含 linux/arm64 容器）上误匹配本机 ELF，导致 /usr/bin/date
# 等出现 “cannot execute binary file: Exec format error”。
#
# 需要：--privileged 或可写 /proc/sys/fs/binfmt_misc/register
set -e
if [ -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]; then
    exit 0
fi
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
if [ ! -w /proc/sys/fs/binfmt_misc/register ]; then
    exit 0
fi

if command -v update-binfmts >/dev/null 2>&1 && [ -f /usr/share/binfmts/qemu-riscv64 ]; then
    update-binfmts --package qemu-user-static --import qemu-riscv64 2>/dev/null && exit 0
    update-binfmts --import qemu-riscv64 2>/dev/null && exit 0
fi

# 仅在 x86_64 上使用历史 printf 回退（aarch64/arm64 勿用，易误伤本机解释执行）
case "$(uname -m)" in
    aarch64 | arm64) exit 0 ;;
esac

/usr/bin/printf ':qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-riscv64-static:OCF\n' \
    >/proc/sys/fs/binfmt_misc/register 2>/dev/null || true
