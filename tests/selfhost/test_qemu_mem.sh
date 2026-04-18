#!/bin/sh
# Test: test_qemu_mem
# Phase: 1, Task: T5
#
# Spec: `cat /proc/meminfo`，MemTotal ≥ 3.5 GiB（默认 4G 减开销）
TEST_NAME="test_qemu_mem"

# TODO(T5): implement actual checks
# Plan:
#   1. 读取 /proc/meminfo 的 MemTotal 行；
#   2. 解析 kB 数值；
#   3. 与 3.5GiB 下限比较；

set -e

kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)
if [ -z "$kb" ]; then
    echo "[TEST] $TEST_NAME FAIL: MemTotal not found"
    exit 1
fi

min_kb=$((7 * 512 * 1024))
if ! [ "$kb" -ge "$min_kb" ] 2>/dev/null; then
    echo "[TEST] $TEST_NAME FAIL: MemTotal=${kb}kB < 3.5GiB (${min_kb}kB)"
    exit 1
fi

echo "[TEST] $TEST_NAME PASS"
exit 0
