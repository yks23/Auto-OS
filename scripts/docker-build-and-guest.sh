#!/usr/bin/env bash
# docker-build-and-guest.sh — Fast, incremental workflow for StarryOS kernel + guest.
#
# Supports two modes:
#   1) Docker mode (Linux CI): kernel build + guest QEMU inside Docker
#   2) Native mode (macOS dev): kernel build in Docker, QEMU on host
#
# Usage:
#   bash scripts/docker-build-and-guest.sh                        # build kernel + run guest
#   bash scripts/docker-build-and-guest.sh --smoke                # quick boot test (minimal rootfs)
#   bash scripts/docker-build-and-guest.sh --crate ax-errno       # build kernel + check crate in guest
#   bash scripts/docker-build-and-guest.sh --guest-only --smoke   # skip kernel build, boot guest
#   bash scripts/docker-build-and-guest.sh --rebuild              # force full rebuild
#   bash scripts/docker-build-and-guest.sh --native               # force native macOS mode
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

# ── defaults ──
CRATE=""
PHASE="check"
GUEST_ONLY=0
SMOKE=0
REBUILD=0
SMP=1
MEM="2G"
NATIVE=0
TIMEOUT="${GUEST_TIMEOUT:-120}"

# ── args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --crate)      CRATE="$2"; shift 2 ;;
    --phase)      PHASE="$2"; shift 2 ;;
    --guest-only) GUEST_ONLY=1; shift ;;
    --smoke)      SMOKE=1; shift ;;
    --rebuild)    REBUILD=1; shift ;;
    --smp)        SMP="$2"; shift 2 ;;
    --mem)        MEM="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --native)     NATIVE=1; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# //; s/^#//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── detect mode: native (macOS) vs docker (Linux) ──
if [[ "$NATIVE" -eq 1 ]] || [[ "$(uname -s)" == "Darwin" ]]; then
  MODE="native"
else
  MODE="docker"
fi

KERNEL_ELF="$TGOSKITS/target/riscv64gc-unknown-none-elf/release/starryos"
KERNEL_BIN="/tmp/starry-guest-kernel.bin"

# Select rootfs: smoke (minimal) or selfbuild (with rustc)
if [[ "$SMOKE" -eq 1 ]]; then
  ROOTFS="$ROOT/.guest-runs/rootfs-smoke-riscv64.img"
else
  ROOTFS="$ROOT/.guest-runs/rootfs-selfbuild-riscv64.img"
fi

log "mode=$MODE smoke=$SMOKE crate=${CRATE:-none} phase=$PHASE smp=$SMP mem=$MEM"

# ═══════════════════════════════════════════════════
# Phase 0: Build rootfs if missing
# ═══════════════════════════════════════════════════
if [[ ! -f "$ROOTFS" ]]; then
  if [[ "$SMOKE" -eq 1 ]]; then
    log "minimal rootfs not found, building..."
    bash "$ROOT/scripts/build-minimal-rootfs.sh"
  else
    log "selfbuild rootfs not found, building (5-10 min)..."
    bash "$ROOT/scripts/build-selfbuild-rootfs-docker.sh"
  fi
fi

# ═══════════════════════════════════════════════════
# Phase 1: Build kernel
# ═══════════════════════════════════════════════════
if [[ "$GUEST_ONLY" -eq 0 ]]; then
  NEED_BUILD=0
  if [[ "$REBUILD" -eq 1 ]]; then
    NEED_BUILD=1
  elif [[ ! -f "$KERNEL_ELF" ]]; then
    NEED_BUILD=1
  fi

  if [[ "$NEED_BUILD" -eq 1 ]]; then
    log "building kernel (Docker, ARCH=riscv64)..."
    if ! docker info >/dev/null 2>&1; then
      die "Docker not available. Start Docker Desktop or use --guest-only with an existing kernel."
    fi
    docker run --rm \
      --platform linux/amd64 \
      -v "$ROOT/tgoskits:/workspace" \
      auto-os/starry:latest \
      bash -c '
set -e
cd /workspace/os/StarryOS
PLAT_PACKAGE=ax-plat-riscv64-qemu-virt
RUST_TARGET=riscv64gc-unknown-none-elf
PLAT_CONFIG=$(cargo axplat info -C starryos -c "$PLAT_PACKAGE" | tail -1)
PLAT_NAME=$(grep "^platform" "$PLAT_CONFIG" | head -1 | sed "s/.*=.*\"\(.*\)\".*/\1/")
for _dc in ../arceos/configs/defconfig.toml make/defconfig.toml; do
    [[ -f "$_dc" ]] && { _DEFCONFIG="$_dc"; break; }
done
ax-config-gen "$_DEFCONFIG" "$PLAT_CONFIG" \
    -w "arch=\"riscv64\"" -w "platform=\"$PLAT_NAME\"" \
    -w "plat.max-cpu-num='"'"'4'"'"'" -w "plat.phys-memory-size=0x100000000" \
    -o .axconfig.toml
export AX_ARCH=riscv64 AX_PLATFORM="$PLAT_NAME" AX_MODE=release AX_LOG=warn
export AX_TARGET="$RUST_TARGET" AX_IP=10.0.2.15 AX_GW=10.0.2.2
export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"
cd /workspace
LD_SCRIPT="/workspace/target/$RUST_TARGET/release/linker_${PLAT_NAME}.lds"
cargo build -p starryos --target "$RUST_TARGET" --release --features "starryos/qemu,smp" 2>&1 | tail -3
[[ -f "$LD_SCRIPT" ]] || { echo "FAIL: linker script missing"; exit 1; }
RUSTFLAGS="-C link-arg=-T$LD_SCRIPT -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
    cargo build -p starryos --target "$RUST_TARGET" --release --features "starryos/qemu,smp" 2>&1 | tail -3
ls -lh /workspace/target/riscv64gc-unknown-none-elf/release/starryos
'
    log "kernel build done"
  else
    log "kernel ELF exists, skipping build ($KERNEL_ELF)"
  fi
fi

[[ -f "$KERNEL_ELF" ]] || die "kernel ELF not found: $KERNEL_ELF (run without --guest-only first)"

# ═══════════════════════════════════════════════════
# Phase 2: Flatten kernel + boot QEMU
# ═══════════════════════════════════════════════════
log "flattening kernel ELF -> $KERNEL_BIN"
RUST_SYSROOT="$(rustc --print sysroot 2>/dev/null)"
HOST_TRIPLE="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
OBJCOPY="$RUST_SYSROOT/lib/rustlib/$HOST_TRIPLE/bin/llvm-objcopy"
if [[ ! -x "$OBJCOPY" ]]; then
  die "llvm-objcopy not found at $OBJCOPY"
fi
"$OBJCOPY" -I elf64-littleriscv -O binary "$KERNEL_ELF" "$KERNEL_BIN"

if [[ "$MODE" == "native" ]]; then
  QEMU="qemu-system-riscv64"
  if ! command -v "$QEMU" >/dev/null; then
    die "qemu-system-riscv64 not found (brew install qemu)"
  fi
fi

SERIAL_LOG="/tmp/starry-guest-serial.log"
rm -f "$SERIAL_LOG"

# QEMU TCG LR/SC broken under MTTCG; only need single-threaded TCG when SMP > 1.
_tcg=()
if [[ "$SMP" -gt 1 ]]; then
  _tcg=(-accel tcg,thread=single)
fi
QEMU_ARGS=(
  -machine virt -bios default
  -smp "$SMP" -m "$MEM"
  "${_tcg[@]}"
  -kernel "$KERNEL_BIN" -cpu rv64
  -monitor none -nographic
  -serial "file:$SERIAL_LOG"
  -device virtio-blk-pci,drive=disk0
  -drive "id=disk0,if=none,format=raw,file=$ROOTFS"
)

log "booting QEMU ($QEMU ${QEMU_ARGS[*]})"
"$QEMU" "${QEMU_ARGS[@]}" &
QPID=$!

# Give QEMU time to start and begin writing serial output
sleep 2

# Wait for guest to finish
SEEN=""
for i in $(seq 1 "$TIMEOUT"); do
  # Check serial log first (QEMU may have already exited)
  if [[ -f "$SERIAL_LOG" ]]; then
    if grep -q "SELFHOST-DONE\|GUEST_BUILD_PASS\|GUEST_BUILD_FAIL\|GUEST_RUSTC_PASS\|GUEST_CARGO_PASS" "$SERIAL_LOG" 2>/dev/null; then
      SEEN=$(grep -oE "GUEST_BUILD_[A-Z]+|GUEST_RUSTC_PASS|GUEST_CARGO_PASS|SELFHOST-DONE" "$SERIAL_LOG" | tail -1)
      sleep 2  # let QEMU flush
      break
    fi
    if grep -q "panicked at" "$SERIAL_LOG" 2>/dev/null; then
      SEEN="PANIC"
      break
    fi
  fi
  if ! kill -0 "$QPID" 2>/dev/null; then
    break
  fi
  sleep 1
done

kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

# ═══════════════════════════════════════════════════
# Phase 3: Report results
# ═══════════════════════════════════════════════════
echo ""
echo "=== Guest serial output (last 30 lines) ==="
tail -30 "$SERIAL_LOG"
echo ""

if [[ "$SEEN" == "GUEST_BUILD_PASS" || "$SEEN" == "GUEST_RUSTC_PASS" || "$SEEN" == "GUEST_CARGO_PASS" || "$SEEN" == "SELFHOST-DONE" ]]; then
  log "✓ GUEST PASSED ($SEEN)"
  exit 0
elif [[ "$SEEN" == "PANIC" ]]; then
  log "✗ GUEST PANIC"
  exit 1
elif [[ "$SEEN" == "GUEST_BUILD_FAIL" ]]; then
  log "✗ GUEST BUILD FAILED"
  exit 1
else
  log "? guest did not produce result marker within ${TIMEOUT}s"
  exit 2
fi
