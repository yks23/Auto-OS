#!/usr/bin/env bash
# docker-inner-build-guest.sh — runs inside the Docker container.
# Called by scripts/docker-build-and-guest.sh.
#
# Phase 1: Build StarryOS kernel (incremental — reuses target/ cache)
# Phase 2: Boot QEMU guest and compile a crate (if --crate given)
# Phase 2a: Smoke test (if --smoke)
set -euo pipefail

WS="${WORKSPACE:-/workspace}"
TG="$WS/tgoskits"
LOG_PREFIX="[inner]"

log() { printf '%s %s %s\n' "$(date +%H:%M:%S)" "$LOG_PREFIX" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

CRATE="${BUILD_GUEST_CRATE:-}"
PHASE="${BUILD_GUEST_PHASE:-check}"
GUEST_ONLY="${BUILD_GUEST_ONLY:-0}"
SMOKE="${BUILD_GUEST_SMOKE:-0}"
REBUILD="${BUILD_GUEST_REBUILD:-0}"
SMP="${BUILD_GUEST_SMP:-1}"
MEM="${BUILD_GUEST_MEM:-4G}"

[[ -f "$TG/Cargo.toml" ]] || die "$TG/Cargo.toml not found (submodule initialized?)"

# ── Phase 1: Build kernel ──────────────────────────────────────────
KERNEL_ELF="$TG/target/riscv64gc-unknown-none-elf/release/starryos"

if [[ "$GUEST_ONLY" == "1" ]]; then
  log "guest-only: skipping kernel build"
  [[ -f "$KERNEL_ELF" ]] || die "guest-only but kernel ELF missing: $KERNEL_ELF"
elif [[ "$REBUILD" == "1" ]]; then
  log "rebuild: cleaning target/ ..."
  rm -rf "$TG/target/riscv64gc-unknown-none-elf"
fi

if [[ "$GUEST_ONLY" != "1" ]]; then
  if [[ -f "$KERNEL_ELF" ]] && [[ "$REBUILD" != "1" ]]; then
    log "kernel ELF exists, skipping build: $KERNEL_ELF"
    ls -lh "$KERNEL_ELF"
  else
    log "building StarryOS kernel (ARCH=riscv64)..."
    cd "$WS"
    bash "$WS/scripts/build.sh" ARCH=riscv64
    [[ -f "$KERNEL_ELF" ]] || die "kernel build finished but ELF not found: $KERNEL_ELF"
    log "kernel build OK"
  fi
fi

# If only building kernel (no crate, no smoke), done.
if [[ -z "$CRATE" ]] && [[ "$SMOKE" != "1" ]]; then
  log "kernel only — done"
  echo "===BUILD_GUEST_PASS==="
  exit 0
fi

# ── Phase 2: Prepare + boot QEMU guest ─────────────────────────────
export PATH="/opt/riscv64-linux-musl-cross/bin:${PATH:-}"

SAVE_DIR="$WS/.guest-runs/saved"
KERNEL_SAVE="$SAVE_DIR/starryos-riscv64.release"
KERNEL_BIN="$SAVE_DIR/starryos-riscv64.release.bin"
MNT="/tmp/docker-guest-mnt"
mkdir -p "$SAVE_DIR"

# objcopy kernel to flat binary
cp -f "$KERNEL_ELF" "$KERNEL_SAVE"
riscv64-linux-musl-objcopy -O binary "$KERNEL_SAVE" "$KERNEL_BIN"
log "kernel binary: $KERNEL_BIN ($(du -h "$KERNEL_BIN" | cut -f1))"

# Resolve rootfs
ROOTFS=""
for candidate in \
  "$WS/.guest-runs/riscv64-m6/rootfs-run.img" \
  "$WS/tests/selfhost/rootfs-selfbuild-riscv64.img" \
  "$WS/.guest-runs/rootfs-selfbuild-riscv64.img"; do
  if [[ -f "$candidate" ]]; then
    ROOTFS="$candidate"
    break
  fi
done

if [[ -z "$ROOTFS" ]]; then
  log "no rootfs image found; attempting to build one..."
  # Try the selfbuild rootfs script
  if [[ -f "$WS/tests/selfhost/build-selfbuild-rootfs.sh" ]]; then
    bash "$WS/tests/selfhost/build-selfbuild-rootfs.sh"
    if [[ -f "$WS/tests/selfhost/rootfs-selfbuild-riscv64.img" ]]; then
      ROOTFS="$WS/tests/selfhost/rootfs-selfbuild-riscv64.img"
    fi
  fi
  [[ -n "$ROOTFS" ]] || die "no rootfs image found and build failed"
fi
log "rootfs: $ROOTFS ($(du -h "$ROOTFS" | cut -f1))"

# Mount rootfs and inject scripts
umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
mount -o loop,rw "$ROOTFS" "$MNT"

if [[ "$SMOKE" == "1" ]]; then
  # ── Phase 2a: Smoke test ──
  cat >"$MNT/opt/run-tests.sh" <<'SMOKE_SH'
#!/bin/bash
echo "===SMOKE_TEST_BEGIN==="
echo "hostname=$(hostname)"
ls / | head -20
echo "===SMOKE_LS_DONE==="
# Test basic commands
echo "uname=$(uname -a)"
echo "pwd=$(pwd)"
echo "===SMOKE_TEST_PASS==="
SMOKE_SH
  chmod +x "$MNT/opt/run-tests.sh"
else
  # ── Phase 2b: Crate compilation in guest ──
  # Pre-create cargo cache sentinels (workaround Starry O_CREAT|O_NOFOLLOW bug)
  mkdir -p "$MNT/opt/tgoskits/.m6-tmp" "$MNT/opt/tgoskits/m6-cargo-home/registry"
  cat >"$MNT/opt/tgoskits/m6-cargo-home/config.toml" <<'CARGO_CFG'
[cache]
auto-clean-frequency = "never"
CARGO_CFG
  : >"$MNT/opt/tgoskits/m6-cargo-home/.package-cache"
  : >"$MNT/opt/tgoskits/m6-cargo-home/.package-cache-journal"
  : >"$MNT/opt/tgoskits/m6-cargo-home/.global-cache"
  : >"$MNT/opt/tgoskits/m6-cargo-home/.global-cache-journal"

  # Copy inner script
  cp -f "$WS/scripts/guest-onecrate-inner.sh" "$MNT/opt/guest-onecrate-inner.sh"
  chmod +x "$MNT/opt/guest-onecrate-inner.sh"

  # Create run-tests.sh that invokes guest-onecrate-inner.sh with our env
  tee "$MNT/opt/run-tests.sh" >/dev/null <<INNER_EOF
#!/bin/bash
echo "===BUILD_GUEST_RUN_BEGIN==="
export GUEST_ONECRATE_CRATE="${CRATE}"
export GUEST_ONECRATE_TARGET="riscv64gc-unknown-none-elf"
export GUEST_ONECRATE_MODE="cargo"
export GUEST_ONECRATE_CARGO_PHASE="${PHASE}"
export GUEST_ONECRATE_ALLOW_FETCH="0"
export GUEST_ONECRATE_SAMPLE_SLEEP="0.5"
export GUEST_ONECRATE_PROGRESS_SEC="120"
export GUEST_ONECRATE_SYSCALL_STATS_SEC="0"
export GUEST_ONECRATE_SYSCALL_TRACE="0"
export GUEST_ONECRATE_TRACE_SNAPSHOT_SEC="0"
export GUEST_ONECRATE_DEEP_TRACE_SEC="0"
export GUEST_ONECRATE_WAIT_ONLY="0"
export GUEST_ONECRATE_DEVLOG_SEC="0"
export GUEST_ONECRATE_CARGO_TAIL_SEC="15"
export GUEST_ONECRATE_CARGO_TRACE="0"
export GUEST_ONECRATE_CARGO_VERBOSE="0"
export GUEST_ONECRATE_RUSTFLAGS="-C debuginfo=0"
export RUST_MIN_STACK=16777216
export CARGO_BUILD_JOBS="1"
export RAYON_NUM_THREADS="1"
export TMPDIR="/opt/tgoskits/.m6-tmp"
export CARGO_TARGET_DIR="/opt/tgoskits/target"
echo "===GUEST_ONECRATE_EXEC_BASH==="
exec /bin/bash --noprofile --norc /opt/guest-onecrate-inner.sh
INNER_EOF
  chmod +x "$MNT/opt/run-tests.sh"
fi

umount "$MNT" || die "umount failed"

# ── Boot QEMU ───────────────────────────────────────────────────────
OUT_DIR="$WS/.guest-runs/docker-build-guest"
mkdir -p "$OUT_DIR"
RESULT="$OUT_DIR/results.txt"
rm -f "$RESULT"
: >"$RESULT"

TIMEOUT=1800
if [[ -n "$CRATE" ]]; then
  # Crate compilation can take a while under emulation
  TIMEOUT=3600
fi

log "booting QEMU: smp=$SMP mem=$MEM timeout=${TIMEOUT}s"
log "serial log: $RESULT"

set +e
timeout "$TIMEOUT" qemu-system-riscv64 \
  -nographic -machine virt -bios default \
  -smp "$SMP" -m "$MEM" \
  -kernel "$KERNEL_BIN" -cpu rv64 \
  -monitor none -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file="$ROOTFS",file.locking=off \
  >"$RESULT" 2>&1 </dev/null
Q_RC=$?
set -e

log "QEMU exited: rc=$Q_RC"

# ── Check results ───────────────────────────────────────────────────
if [[ "$SMOKE" == "1" ]]; then
  if grep -a -q '===SMOKE_TEST_PASS===' "$RESULT"; then
    log "SMOKE PASS"
    echo "===BUILD_GUEST_PASS==="
    exit 0
  else
    log "SMOKE FAIL — last 40 lines:"
    tail -40 "$RESULT" >&2 || true
    exit 1
  fi
fi

# Crate compilation check
if grep -a -q '===GUEST_ONECRATE_CHECK_RC 0===' "$RESULT"; then
  log "GUEST CRATE PASS: $CRATE ($PHASE)"
  echo "===BUILD_GUEST_PASS==="
  exit 0
else
  log "GUEST CRATE FAIL — last 40 lines:"
  tail -40 "$RESULT" >&2 || true
  # Run diagnosis if available
  if [[ -f "$WS/scripts/guest-onecrate-diagnose.sh" ]]; then
    bash "$WS/scripts/guest-onecrate-diagnose.sh" "$RESULT" || true
  fi
  exit 1
fi
