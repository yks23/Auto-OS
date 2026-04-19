#!/usr/bin/env bash
# 集成构建：apply T1-T5 的 patches，手工解决已知冲突，build 双架构。
#
# 已知冲突（详见 patches/integration/CONFLICTS.md）：
#   - T1 ↔ T2 在 kernel/src/syscall/task/execve.rs 与 kernel/src/task/ops.rs
#   - T1 ↔ T5 在 kernel/src/syscall/task/execve.rs
#
# 用法：
#   scripts/integration-build.sh                 # 默认双架构
#   scripts/integration-build.sh ARCH=riscv64    # 单架构
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ARCH="${ARCH:-}"
for arg in "$@"; do
    case "$arg" in
        ARCH=*) ARCH="${arg#ARCH=}" ;;
    esac
done

apply_with_resolve() {
    reset_to_pin
    cd "$TGOSKITS"
    log "applying T1..."
    git am --3way --keep-cr /workspace/patches/T1/*.patch >/dev/null 2>&1 || die "T1 apply unexpectedly failed"

    log "applying T2 (will conflict with T1, auto-resolving)..."
    if ! git am --3way --keep-cr /workspace/patches/T2/*.patch >/dev/null 2>&1; then
        # Apply integration resolution
        if [[ -f /workspace/patches/integration/T1-T2-execve.merge ]]; then
            cp /workspace/patches/integration/T1-T2-execve.merge \
               os/StarryOS/kernel/src/syscall/task/execve.rs
        fi
        if [[ -f /workspace/patches/integration/T1-T2-ops.merge ]]; then
            cp /workspace/patches/integration/T1-T2-ops.merge \
               os/StarryOS/kernel/src/task/ops.rs
        fi
        git add -A
        # 完成 am 之后可能还有 fix patch；那个一般会 fail with "no changes" 并要 skip
        git -c user.email=integration@cursor.local -c user.name=Integration \
            am --continue >/dev/null 2>&1 || git am --skip >/dev/null 2>&1 || true
        # 把剩下的 T2 patches（如 build-fix）继续
        for p in /workspace/patches/T2/0002*.patch; do
            [[ -f "$p" ]] && git am --3way --keep-cr "$p" >/dev/null 2>&1 || true
        done
    fi

    log "applying T3..."
    git am --3way --keep-cr /workspace/patches/T3/*.patch >/dev/null 2>&1 || die "T3 apply failed"

    log "applying T4..."
    git am --3way --keep-cr /workspace/patches/T4/*.patch >/dev/null 2>&1 || die "T4 apply failed"

    log "applying T5 (will conflict with T1, auto-resolving)..."
    if ! git am --3way --keep-cr /workspace/patches/T5/*.patch >/dev/null 2>&1; then
        if [[ -f /workspace/patches/integration/T1-T5-execve.merge ]]; then
            cp /workspace/patches/integration/T1-T5-execve.merge \
               os/StarryOS/kernel/src/syscall/task/execve.rs
        fi
        git add -A
        git -c user.email=integration@cursor.local -c user.name=Integration \
            am --continue >/dev/null 2>&1 || git am --skip >/dev/null 2>&1 || true
        for p in /workspace/patches/T5/0004*.patch; do
            [[ -f "$p" ]] && git am --3way --keep-cr "$p" >/dev/null 2>&1 || true
        done
    fi

    cd /workspace
    log "✓ all patches applied (with integration resolutions)"
}

apply_with_resolve

if [[ -z "$ARCH" ]]; then
    for a in riscv64 x86_64; do
        log "=== Build ARCH=$a ==="
        bash "$SCRIPT_DIR/build.sh" ARCH="$a"
    done
else
    bash "$SCRIPT_DIR/build.sh" ARCH="$ARCH"
fi
