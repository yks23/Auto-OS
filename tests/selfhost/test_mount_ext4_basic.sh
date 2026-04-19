#!/bin/sh
# Test: test_mount_ext4_basic
# Phase: 1, Task: T4
#
# Spec: `mkfs.ext4 /dev/vdb` 后 `mount -t ext4 /dev/vdb /mnt`，`echo hi > /mnt/x`，umount，重 mount，`/mnt/x` == "hi"
set -e
TEST_NAME="test_mount_ext4_basic"
MNT=/mnt

# TODO(T4): implement actual checks
# Plan:
#   1. 在 guest 上对 /dev/vdb mkfs.ext4；
#   2. mount -t ext4 到 /mnt 并写入 /mnt/x；
#   3. umount 后再次 mount；
#   4. cat /mnt/x 校验内容为 hi；
#   5. 失败则输出 FAIL 并非 0 退出。

cleanup() {
    umount "$MNT" 2>/dev/null || true
}

cleanup
if ! command -v mkfs.ext4 >/dev/null 2>&1; then
    echo "[TEST] $TEST_NAME FAIL: mkfs.ext4 not found in PATH"
    exit 1
fi
if [ ! -b /dev/vdb ]; then
    echo "[TEST] $TEST_NAME FAIL: /dev/vdb is not a block device"
    exit 1
fi

mkdir -p "$MNT"
mkfs.ext4 -F /dev/vdb
mount -t ext4 /dev/vdb "$MNT"
echo hi > "$MNT/x"
umount "$MNT"
mount -t ext4 /dev/vdb "$MNT"
read -r content < "$MNT/x"
umount "$MNT"
cleanup

if [ "$content" != "hi" ]; then
    echo "[TEST] $TEST_NAME FAIL: expected hi, got '$content'"
    exit 1
fi

echo "[TEST] $TEST_NAME PASS"
exit 0
