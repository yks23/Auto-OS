#!/usr/bin/env bash
# 把 patches/Tn-*/*.patch 顺序 apply 到 tgoskits 子模块。
#
# 用法：
#   scripts/apply-patches.sh                # apply 所有 patches
#   scripts/apply-patches.sh T1 T3          # 只 apply T1 与 T3
#   scripts/apply-patches.sh --reset        # 先 reset 到 pin commit 再 apply
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

DO_RESET=0
SELECTED=()

for arg in "$@"; do
    case "$arg" in
        --reset)  DO_RESET=1 ;;
        --help|-h)
            grep -E '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) SELECTED+=("$arg") ;;
    esac
done

if (( DO_RESET )); then
    reset_to_pin
fi

# 在 tgoskits 内必须是 pin commit（除非用户已经在自己的 worktree）
applied=0
failed=0
skipped=0

for d in $(list_patch_dirs); do
    name="$(basename "$d")"
    if (( ${#SELECTED[@]} )); then
        match=0
        for s in "${SELECTED[@]}"; do
            [[ "$name" == "$s" || "$name" == "$s"-* ]] && match=1 && break
        done
        (( match )) || { ((skipped++)); continue; }
    fi

    patches=()
    while IFS= read -r p; do patches+=("$p"); done < <(list_patches_in "$d")
    if (( ${#patches[@]} == 0 )); then
        log "skip $name: no patches"
        ((skipped++))
        continue
    fi

    log "applying $name (${#patches[@]} patches)..."
    if (cd "$TGOSKITS" && git am --3way --keep-cr "${patches[@]}" >/dev/null 2>&1); then
        ((applied++))
        log "  ✓ $name"
    else
        log "  ✗ $name FAILED, aborting am"
        (cd "$TGOSKITS" && git am --abort 2>/dev/null || true)
        ((failed++))
        if (( ! DO_RESET )); then
            die "patch $name failed; rerun with --reset and inspect $d"
        fi
    fi
done

log "summary: applied=$applied failed=$failed skipped=$skipped"
exit $(( failed > 0 ? 1 : 0 ))
