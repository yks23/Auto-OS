#!/usr/bin/env bash
# 在 tgoskits/os/StarryOS 内 build 内核 ELF。
#
# 用法：
#   scripts/build.sh ARCH=riscv64                    # 默认 build target
#   scripts/build.sh ARCH=x86_64                     # x86_64
#   scripts/build.sh ARCH=riscv64 TARGET=ci-test     # ci-test
#   ARCH=x86_64 scripts/build.sh                     # 也可走环境变量
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# 解析 KEY=VAL
for arg in "$@"; do
    case "$arg" in
        ARCH=*)   ARCH="${arg#ARCH=}" ;;
        TARGET=*) TARGET="${arg#TARGET=}" ;;
        *) die "unknown arg: $arg" ;;
    esac
done

ARCH="${ARCH:-riscv64}"
TARGET="${TARGET:-build}"

[[ -d "$TGOSKITS/os/StarryOS" ]] || die "tgoskits/os/StarryOS not found; did patches apply?"

log "building ARCH=$ARCH TARGET=$TARGET"
cd "$TGOSKITS/os/StarryOS"
exec make ARCH="$ARCH" "$TARGET"
