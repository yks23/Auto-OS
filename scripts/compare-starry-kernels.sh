#!/usr/bin/env bash
# 对比多个 starryos ELF：file、体积、sha256、少量 strings。
#
# 用法：
#   bash scripts/compare-starry-kernels.sh
#       # 默认对比 cargo 默认产物（若存在）
#   bash scripts/compare-starry-kernels.sh path/a.elf path/b.elf ...
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULTS=(
    "$ROOT/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
    "$ROOT/tgoskits/target/x86_64-unknown-none/release/starryos"
)

if (($#)); then
    FILES=("$@")
else
    FILES=()
    for f in "${DEFAULTS[@]}"; do
        [[ -f "$f" ]] && FILES+=("$f")
    done
    ((${#FILES[@]})) || { echo "no default ELFs found; pass paths explicitly" >&2; exit 1; }
fi

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

echo "======== StarryOS kernel ELF compare ========"
for f in "${FILES[@]}"; do
    echo
    echo "--- $f ---"
    ls -lh "$f"
    file "$f" || true
    shasum -a 256 "$f"
    echo "strings (sample):"
    strings "$f" 2>/dev/null | grep -E 'Starry|starry|riscv64|x86_64|x86-pc|riscv64-qemu' | head -n 12 || true
done
