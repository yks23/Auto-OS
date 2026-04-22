#!/usr/bin/env bash
# reproduce-in-container.sh — runs INSIDE the auto-os/starry docker image.
#
# Steps:
#   1. ensure submodule is at the pinned commit (already cloned by host)
#   2. build StarryOS kernel ELF
#   3. fetch / build the M5 demo rootfs (alpine + rust 1.95) and run M5 demo
#      (rustc + cargo build hello world inside the starry guest)
#   4. (--m6) fetch / build the M6 demo rootfs (debian + rust nightly +
#      tgoskits sources) and run M6 demo (in-guest cargo metadata + cargo
#      check on the starry kernel sources)
#
# This script assumes it's running with --privileged and --network host.

set -euo pipefail
cd /work

WITH_M6=0
for a in "$@"; do
    case "$a" in
        --m6) WITH_M6=1 ;;
    esac
done

log() { printf '\n\033[1;35m[in-container %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fatal() { printf '\033[1;31mFATAL (container):\033[0m %s\n' "$*" >&2; exit 1; }

# binfmt for cross chroot when building rootfs (no-op if already registered)
register-binfmt 2>/dev/null || true

# ---------------------------------------------- step 1: submodule
log "[1/4] tgoskits @ pinned commit"
SUBMOD_SHA_WANT="$(git ls-tree HEAD tgoskits | awk '{print $3}')"
( cd tgoskits && git reset --hard "$SUBMOD_SHA_WANT" >/dev/null && git clean -fd >/dev/null 2>&1 || true )
log "tgoskits @ $(cd tgoskits && git rev-parse --short HEAD)"

# ---------------------------------------------- step 2: kernel
log "[2/4] build StarryOS kernel"
bash scripts/build.sh ARCH=riscv64
KERNEL_ELF="tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
[[ -f "$KERNEL_ELF" ]] || fatal "kernel ELF missing"
log "kernel ELF: $(ls -lh "$KERNEL_ELF" | awk '{print $5}')"

# ---------------------------------------------- step 3: M5 demo rootfs + run
M5_ROOTFS="tests/selfhost/rootfs-selfhost-rust-riscv64.img"
log "[3/4] M5 demo rootfs (alpine + rust 1.95) and demo run"
if [[ ! -f "$M5_ROOTFS" ]]; then
    log "  rootfs missing, building (~3-5 min)..."
    bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64 PROFILE=rust
fi
log "  rootfs: $(ls -lh "$M5_ROOTFS" | awk '{print $5}')"
log "  running M5 demo..."
bash scripts/demo-m5-rust.sh

M5_RESULT=".guest-runs/riscv64-m5/results.txt"
if [[ -f "$M5_RESULT" ]] && grep -q "===M5-DEMO-PASS===" "$M5_RESULT"; then
    log "  ✓ M5 PASS"
else
    fatal "M5 demo did NOT pass; see $M5_RESULT"
fi

# ---------------------------------------------- step 4: optional M6
if (( WITH_M6 )); then
    M6_ROOTFS="tests/selfhost/rootfs-selfbuild-riscv64.img"
    log "[4/4] M6 selfbuild rootfs + run (this is heavy: ~15 min build, ~1.3 GiB xz)"
    if [[ ! -f "$M6_ROOTFS" ]]; then
        log "  rootfs missing, building..."
        bash tests/selfhost/build-selfbuild-rootfs.sh
    fi
    log "  rootfs: $(ls -lh "$M6_ROOTFS" | awk '{print $5}')"
    bash scripts/demo-m6-selfbuild.sh || log "  (M6 demo did not reach PASS marker — partial success expected; see log)"
else
    log "[4/4] M6 selfbuild — skipped (pass --m6 to enable)"
fi

log "all done."
