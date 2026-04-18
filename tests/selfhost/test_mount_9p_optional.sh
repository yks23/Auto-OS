#!/bin/sh
# Test: test_mount_9p_optional
# Phase: 1, Task: T4
#
# Spec: （T18 后）9p 挂载并读写
set -e
TEST_NAME="test_mount_9p_optional"
MNT=/tmp/starry_t4_9p_mnt

# TODO(T4): implement actual checks
# Plan:
#   1. 检测 virtio-9p 设备与 mount 选项是否可用；
#   2. mount 9p 到指定目录；
#   3. 读写探测文件验证数据一致；
#   4. 不可用则 SKIP 或按矩阵约定标记；
#   5. 卸载与清理。

cleanup() {
    umount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
}

cleanup
mkdir -p "$MNT"

if mount -t 9p hostsrc "$MNT" -o trans=virtio,version=9p2000.L 2>/dev/null; then
    echo probe > "$MNT/.starry_t4_9p_probe"
    read -r line < "$MNT/.starry_t4_9p_probe"
    rm -f "$MNT/.starry_t4_9p_probe"
    umount "$MNT"
    cleanup
    if [ "$line" != "probe" ]; then
        echo "[TEST] $TEST_NAME FAIL: read back got '$line'"
        exit 1
    fi
    echo "[TEST] $TEST_NAME PASS"
    exit 0
fi

cleanup
echo "[TEST] $TEST_NAME SKIP: 9p mount not available (kernel skeleton)"
exit 0
