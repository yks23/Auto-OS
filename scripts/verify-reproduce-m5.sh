#!/usr/bin/env bash
# 验证本机是否已经完成 M5 复现（guest 内 rustc + cargo 成功）。
#
# 用法（在 Auto-OS 仓库根目录）：
#   bash scripts/verify-reproduce-m5.sh
#
# 成功条件：.guest-runs/riscv64-m5/results.txt 存在且含 ===M5-DEMO-PASS===
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT="$ROOT/.guest-runs/riscv64-m5/results.txt"

if [[ ! -f "$RESULT" ]]; then
    echo "FAIL: 未找到 $RESULT"
    echo "请先在本机（推荐 Linux x86_64）执行:  bash scripts/reproduce-all.sh"
    exit 1
fi

if ! grep -q '===M5-DEMO-PASS===' "$RESULT"; then
    echo "FAIL: 日志中无 ===M5-DEMO-PASS=== ，请检查 QEMU 串口输出: $RESULT"
    exit 1
fi

echo "PASS: M5 复现已确认（$RESULT 含 ===M5-DEMO-PASS===）"
exit 0
