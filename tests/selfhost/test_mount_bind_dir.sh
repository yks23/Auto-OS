#!/bin/sh
# Test: test_mount_bind_dir
# Phase: 1, Task: T4
#
# Spec: `mkdir /tmp/{a,b}; touch /tmp/a/x; mount --bind /tmp/a /tmp/b; ls /tmp/b/x 存在`
set -e
TEST_NAME="test_mount_bind_dir"
A=/tmp/starry_t4_bind_a
B=/tmp/starry_t4_bind_b

# TODO(T4): implement actual checks
# Plan:
#   1. 创建 /tmp/a /tmp/b 与 /tmp/a/x；
#   2. mount --bind /tmp/a /tmp/b；
#   3. test -e /tmp/b/x；
#   4. umount /tmp/b 并清理目录。

cleanup() {
    umount "$B" 2>/dev/null || true
    rm -f "$A/x"
    rmdir "$A" "$B" 2>/dev/null || true
}

cleanup
mkdir -p "$A" "$B"
touch "$A/x"
mount --bind "$A" "$B"
if [ ! -e "$B/x" ]; then
    cleanup
    echo "[TEST] $TEST_NAME FAIL: $B/x missing after bind mount"
    exit 1
fi
umount "$B"
cleanup

echo "[TEST] $TEST_NAME PASS"
exit 0
