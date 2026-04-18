#!/bin/sh
# Test: test_qemu_smp
# Phase: 1, Task: T5
#
# Spec: `nproc` >= 4
TEST_NAME="test_qemu_smp"

# TODO(T5): implement actual checks

set -e

n=$(nproc 2>/dev/null || echo 0)
if ! [ "${n:-0}" -ge 4 ] 2>/dev/null; then
    echo "[TEST] $TEST_NAME FAIL: nproc=$n < 4"
    exit 1
fi

echo "[TEST] $TEST_NAME PASS"
exit 0
