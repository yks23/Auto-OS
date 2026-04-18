#!/usr/bin/env bash
# 公共脚本库
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TGOSKITS="$ROOT/tgoskits"
PATCHES="$ROOT/patches"

PIN_COMMIT="$(grep -E '^commit\s*=' "$ROOT/PIN.toml" | head -1 | cut -d'"' -f2)"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

ensure_submodule() {
    if [[ ! -d "$TGOSKITS/.git" && ! -f "$TGOSKITS/.git" ]]; then
        log "tgoskits submodule not initialized, doing it now..."
        (cd "$ROOT" && git submodule update --init tgoskits)
    fi
    if ! (cd "$TGOSKITS" && git remote | grep -q '^upstream$'); then
        (cd "$TGOSKITS" && git remote add upstream https://github.com/rcore-os/tgoskits.git || true)
    fi
}

reset_to_pin() {
    ensure_submodule
    log "fetching upstream/dev..."
    (cd "$TGOSKITS" && git fetch upstream dev --quiet 2>&1) || true
    log "resetting tgoskits to pin $PIN_COMMIT..."
    (cd "$TGOSKITS" && git reset --hard "$PIN_COMMIT" --quiet)
    (cd "$TGOSKITS" && git clean -fdx --quiet) || true
}

list_patch_dirs() {
    [[ -d "$PATCHES" ]] || return 0
    find "$PATCHES" -mindepth 1 -maxdepth 1 -type d | sort
}

list_patches_in() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 -name '*.patch' -type f | sort
}
