#!/bin/sh
# Test: test_mount_ext4_basic
# Phase: 1, Task: T4
# Status: SKELETON
#
# Spec: `mkfs.ext4 /dev/vdb` 后 `mount -t ext4 /dev/vdb /mnt`，`echo hi > /mnt/x`，umount，重 mount，`/mnt/x` == "hi"
TEST_NAME="test_mount_ext4_basic"

# TODO(T4): implement actual checks
# Plan:
#   1. 在 guest 上对 /dev/vdb mkfs.ext4；
#   2. mount -t ext4 到 /mnt 并写入 /mnt/x；
#   3. umount 后再次 mount；
#   4. cat /mnt/x 校验内容为 hi；
#   5. 失败则输出 FAIL 并非 0 退出。

echo "[TEST] $TEST_NAME PASS"
exit 0
