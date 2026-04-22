#!/bin/sh
# /usr/local/bin/register-binfmt — registers riscv64 binfmt_misc handler.
# Idempotent: does nothing if already registered.
# Requires the container to run with --privileged or to be given write access
# to /proc/sys/fs/binfmt_misc (read-only by default).
set -e
if [ -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]; then
    exit 0
fi
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
if [ -w /proc/sys/fs/binfmt_misc/register ]; then
    /usr/bin/printf ':qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-riscv64-static:OCF\n' \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
fi
