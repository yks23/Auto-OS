#!/usr/bin/env bash
# 批量交叉编译 auto-evolve/tests/ 下的 C 测试文件
# 用法: ./testing/scripts/build-tests.sh [ARCH]
# ARCH 默认 riscv64

set -e
ARCH="${1:-riscv64}"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$DIR/auto-evolve/tests"
OUT="$DIR/testing/build/$ARCH/l1"

GCC="${ARCH}-linux-musl-gcc"
if ! command -v "$GCC" &>/dev/null; then
    echo "错误: 找不到 $GCC（请安装 musl 交叉编译工具链）"
    exit 1
fi

mkdir -p "$OUT"
TOTAL=0
OK=0
FAIL=0

for src in "$SRC"/test_*.c; do
    [ -f "$src" ] || continue
    name=$(basename "$src" .c)
    TOTAL=$((TOTAL + 1))
    if $GCC -static -o "$OUT/$name" "$src" -lpthread 2>/dev/null; then
        OK=$((OK + 1))
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "编译完成: $OK/$TOTAL 成功, $FAIL 失败"
echo "输出目录: $OUT"
