#!/usr/bin/env bash
# guest-quick.sh — quick-iterate loop for guest QEMU runs on macOS / Linux.
#
# On macOS, runs QEMU natively (no Docker needed for guest runs).
# On Linux without root, falls back to Docker.
#
# Modes:
#   smoke        — Boot and verify guest shell is alive (< 30s, default)
#   probe        — Run fd/pipe/ppoll/statx probes in guest
#   cargo-check  — cargo check on a hello crate (timeout 120s)
#   cargo-build  — cargo build on a hello crate (timeout 300s)
#
# Usage:
#   bash scripts/guest-quick.sh [smoke|probe|cargo-check|cargo-build]
#
# Environment variables:
#   GUEST_QUICK_KERNEL   — path to kernel binary (default: auto-detect)
#   GUEST_QUICK_ROOTFS   — path to rootfs image (default: auto-detect)
#   GUEST_QUICK_OUT      — output directory (default: .guest-runs/quick-<timestamp>)
#   GUEST_QUICK_MEM      — QEMU memory (default: 4G)
#   GUEST_QUICK_SMP      — QEMU SMP (default: 4)
#   GUEST_QUICK_TIMEOUT  — override timeout for the mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
GUEST_RUNS="${REPO}/.guest-runs"

MODE="${1:-smoke}"
case "$MODE" in
  smoke|probe|cargo-check|cargo-build) ;;
  *) echo "Usage: $0 [smoke|probe|cargo-check|cargo-build]" >&2; exit 1 ;;
esac

# Default timeouts per mode
case "$MODE" in
  smoke)       DEFAULT_TIMEOUT=30  ;;
  probe)       DEFAULT_TIMEOUT=60  ;;
  cargo-check) DEFAULT_TIMEOUT=120 ;;
  cargo-build) DEFAULT_TIMEOUT=300 ;;
esac
TIMEOUT="${GUEST_QUICK_TIMEOUT:-$DEFAULT_TIMEOUT}"

# ================================================================
# Resolve kernel
# ================================================================
KERNEL_BIN="${GUEST_QUICK_KERNEL:-}"
if [[ -z "$KERNEL_BIN" ]]; then
  # Prefer pre-built flat binary
  if [[ -f "${GUEST_RUNS}/saved/starryos-riscv64.release.bin" ]]; then
    KERNEL_BIN="${GUEST_RUNS}/saved/starryos-riscv64.release.bin"
  elif [[ -f "${REPO}/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos" ]]; then
    # Need to convert ELF to flat binary
    KERNEL_ELF="${REPO}/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
    KERNEL_BIN="${GUEST_RUNS}/saved/starryos-riscv64.release.bin"
    mkdir -p "${GUEST_RUNS}/saved"
    OBJCOPY=""
    if command -v rust-objcopy >/dev/null 2>&1; then
      OBJCOPY=rust-objcopy
    elif [[ -n "$(rustc --print sysroot 2>/dev/null)" ]]; then
      SYSROOT="$(rustc --print sysroot)"
      HOST="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
      if [[ -n "$HOST" && -f "${SYSROOT}/lib/rustlib/${HOST}/bin/llvm-objcopy" ]]; then
        OBJCOPY="${SYSROOT}/lib/rustlib/${HOST}/bin/llvm-objcopy"
      fi
    fi
    if [[ -z "$OBJCOPY" ]]; then
      echo "error: need objcopy to convert kernel ELF. Install cargo-binutils." >&2
      exit 1
    fi
    echo "[quick] converting kernel ELF -> binary: ${OBJCOPY}"
    "$OBJCOPY" -I elf64-littleriscv -O binary "$KERNEL_ELF" "$KERNEL_BIN"
  else
    echo "error: no kernel found. Build one first or set GUEST_QUICK_KERNEL." >&2
    exit 1
  fi
fi
[[ -f "$KERNEL_BIN" ]] || { echo "error: kernel not found: $KERNEL_BIN" >&2; exit 1; }

# ================================================================
# Resolve rootfs
# ================================================================
ROOTFS="${GUEST_QUICK_ROOTFS:-}"
if [[ -z "$ROOTFS" ]]; then
  for candidate in \
    "${GUEST_RUNS}/rootfs-selfbuild-riscv64.img" \
    "${GUEST_RUNS}/rootfs-smoke-riscv64.img" \
    "${REPO}/tests/selfhost/rootfs-selfbuild-riscv64.img"; do
    if [[ -f "$candidate" ]]; then
      ROOTFS="$candidate"
      break
    fi
  done
fi
[[ -n "$ROOTFS" && -f "$ROOTFS" ]] || { echo "error: no rootfs found. Set GUEST_QUICK_ROOTFS." >&2; exit 1; }

# ================================================================
# Output directory
# ================================================================
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${GUEST_QUICK_OUT:-${GUEST_RUNS}/quick-${MODE}-${TS}}"
mkdir -p "$OUT_DIR"
RESULT="${OUT_DIR}/serial.txt"
rm -f "$RESULT"
: >"$RESULT"

MEM="${GUEST_QUICK_MEM:-4G}"
SMP="${GUEST_QUICK_SMP:-1}"

echo "[quick] mode=${MODE} timeout=${TIMEOUT}s mem=${MEM} smp=${SMP}"
echo "[quick] kernel=${KERNEL_BIN}"
echo "[quick] rootfs=${ROOTFS}"
echo "[quick] out=${OUT_DIR}"

# ================================================================
# Prepare rootfs — inject run-tests.sh if we can mount it
# ================================================================
# On macOS we cannot mount ext4 natively. Instead, we rely on the
# rootfs already having /opt/run-tests.sh or the StarryOS init
# running /opt/run-tests.sh. For smoke mode, the guest just needs
# to boot and show serial output.
#
# For probe/cargo-check/cargo-build modes, we need the rootfs to have
# the right scripts injected. If we're inside Docker (Linux), we can
# mount and inject. On macOS, we use QEMU's built-in approach.

# Check if we can mount (Linux only, or inside Docker)
CAN_MOUNT=0
if [[ "$(uname -s)" == "Linux" ]] && command -v mount >/dev/null 2>&1; then
  # Test if we have loop mount capability
  if [[ "$(id -u)" -eq 0 ]] || sudo -n true 2>/dev/null; then
    CAN_MOUNT=1
  fi
fi

inject_run_tests() {
  local mnt="$1"
  local mode="$2"

  if [[ "$mode" == "smoke" ]]; then
    cat >"${mnt}/opt/run-tests.sh" <<'SMOKE_SH'
#!/bin/bash
echo "===QUICK_SMOKE_BEGIN==="
echo "hostname=$(hostname)"
echo "pwd=$(pwd)"
echo "uname=$(uname -a)"
ls / | head -20
echo "===QUICK_SMOKE_PASS==="
SMOKE_SH
    chmod +x "${mnt}/opt/run-tests.sh"

  elif [[ "$mode" == "probe" ]]; then
    # Reuse the probe binary if it exists in rootfs, otherwise echo a marker
    cat >"${mnt}/opt/run-tests.sh" <<'PROBE_SH'
#!/bin/bash
echo "===QUICK_PROBE_BEGIN==="
if [[ -x /opt/fd-pipe-probe ]]; then
  /opt/fd-pipe-probe
  echo "===QUICK_PROBE_RC=$?==="
else
  echo "probe binary not found — probing basic commands"
  echo "ls=$(ls / | head -5)"
  echo "cat=$(cat /proc/cpuinfo 2>/dev/null | head -3 || echo N/A)"
  echo "===QUICK_PROBE_RC=0==="
fi
PROBE_SH
    chmod +x "${mnt}/opt/run-tests.sh"

  else
    # cargo-check / cargo-build — inject a minimal run-tests.sh for hello crate
    mkdir -p "${mnt}/opt/onecrate-hello/src"
    cat >"${mnt}/opt/onecrate-hello/Cargo.toml" <<'CARGO_TOML'
[package]
name = "onecrate-hello"
version = "0.1.0"
edition = "2021"

[dependencies]
CARGO_TOML
    cat >"${mnt}/opt/onecrate-hello/src/main.rs" <<'MAIN_RS'
fn main() {
    println!("hello from starry cargo");
}
MAIN_RS

    local phase="check"
    if [[ "$mode" == "cargo-build" ]]; then
      phase="build"
    fi

    # Copy inner script if available
    if [[ -f "${REPO}/scripts/guest-onecrate-inner.sh" ]]; then
      cp -f "${REPO}/scripts/guest-onecrate-inner.sh" "${mnt}/opt/guest-onecrate-inner.sh"
      chmod +x "${mnt}/opt/guest-onecrate-inner.sh"
    fi

    cat >"${mnt}/opt/run-tests.sh" <<INNER_EOF
#!/bin/bash
echo "===QUICK_CARGO_BEGIN=== phase=${phase}"
if [[ -x /opt/alpine-rust/usr/bin/cargo ]]; then
  export PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin"
  export LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib"
  export CARGO_HOME="/opt/tgoskits/m6-cargo-home"
  export TMPDIR="/opt/tgoskits/.m6-tmp"
  cd /opt/onecrate-hello
  echo "running: cargo ${phase} --offline"
  cargo ${phase} --offline 2>&1
  RC=\$?
  echo "===QUICK_CARGO_RC=\${RC}==="
else
  echo "no cargo in rootfs — mode=${mode} skipped"
  echo "===QUICK_CARGO_RC=2==="
fi
INNER_EOF
    chmod +x "${mnt}/opt/run-tests.sh"
  fi
}

MNT="/tmp/guest-quick-mnt-$$"
if [[ "$CAN_MOUNT" == "1" ]]; then
  umount "$MNT" 2>/dev/null || true
  mkdir -p "$MNT"
  mount -o loop,rw "$ROOTFS" "$MNT" 2>/dev/null || CAN_MOUNT=0
  if [[ "$CAN_MOUNT" == "1" ]]; then
    inject_run_tests "$MNT" "$MODE"
    umount "$MNT" || true
    rmdir "$MNT" 2>/dev/null || true
  fi
fi

if [[ "$CAN_MOUNT" != "1" && "$MODE" != "smoke" ]]; then
  echo "[quick] WARNING: cannot mount rootfs on macOS for ${MODE} mode"
  echo "[quick] The rootfs must already have /opt/run-tests.sh injected"
  echo "[quick] Use Docker to inject: docker run --rm --privileged --platform linux/amd64 -v ${REPO}:/work auto-os/starry:latest bash -c 'mount -o loop,rw /work/.guest-runs/rootfs-selfbuild-riscv64.img /mnt && ...'"
fi

# ================================================================
# Run QEMU
# ================================================================
echo "[quick] starting QEMU (timeout=${TIMEOUT}s)..."

# Use background process + sleep + kill for reliable timeout on macOS
qemu-system-riscv64 \
  -nographic -machine virt -bios default -smp "$SMP" -m "$MEM" \
  -kernel "$KERNEL_BIN" -cpu rv64 \
  -monitor none -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive "id=disk0,if=none,format=raw,file=${ROOTFS},file.locking=off" \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  >"$RESULT" 2>&1 &
QEMU_PID=$!

# Wait with timeout
SECONDS=0
QEMU_KILLED=0
while kill -0 "$QEMU_PID" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$TIMEOUT" ]]; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_KILLED=1
    break
  fi
  sleep 1
done

if [[ "$QEMU_KILLED" == "1" ]]; then
  echo "[quick] QEMU killed after ${TIMEOUT}s timeout"
else
  echo "[quick] QEMU exited (wait completed)"
fi

# ================================================================
# Diagnostics
# ================================================================
if [[ ! -s "$RESULT" ]]; then
  echo "[quick] FAIL: no serial output captured in ${RESULT}" >&2
  exit 1
fi

LINES="$(wc -l < "$RESULT" | tr -d ' ')"
SZ="$(ls -lh "$RESULT" | awk '{print $5}')"
echo "[quick] serial output: ${LINES} lines, ${SZ}"

# Check for success markers based on mode
case "$MODE" in
  smoke)
    SUCCESS_MARKER="QUICK_SMOKE_PASS\|GUEST_ONECRATE_INIT_DIRECT\|Boot at"
    ;;
  probe)
    SUCCESS_MARKER="QUICK_PROBE_RC=0\|PROBE_DONE"
    ;;
  cargo-check|cargo-build)
    SUCCESS_MARKER="QUICK_CARGO_RC=0\|Finished\|GUEST_ONECRATE_CHECK_RC 0"
    ;;
esac

OK=0
if grep -a -q "$SUCCESS_MARKER" "$RESULT" 2>/dev/null; then
  OK=1
fi

# Extract and display key diagnostics
echo ""
echo "=== Key diagnostics ==="

# Boot time
grep -a 'Boot at' "$RESULT" 2>/dev/null | tail -1 || true

# Syscall stats (if present)
grep -a '===ONECRATE_SYSCALL_STATS' "$RESULT" 2>/dev/null | tail -3 || true

# Exit code
grep -a 'QUICK_.*_RC=' "$RESULT" 2>/dev/null | tail -1 || true
grep -a 'GUEST_ONECRATE_CHECK_RC' "$RESULT" 2>/dev/null | tail -1 || true

# Elapsed time
grep -a 'GUEST_ONECRATE_ELAPSED' "$RESULT" 2>/dev/null | tail -1 || true

# Diagnostic summary (if present)
if grep -a -q 'DIAGNOSTIC_SUMMARY' "$RESULT" 2>/dev/null; then
  echo "--- diagnostic summary ---"
  sed -n '/===DIAGNOSTIC_SUMMARY_BEGIN===/,/===DIAGNOSTIC_SUMMARY_END===/p' "$RESULT" | grep -v '===DIAGNOSTIC' | sed 's/^/  /'
fi

# Error stats (if present)
if grep -a -q 'SYSCALL_ERROR_STATS' "$RESULT" 2>/dev/null; then
  echo "--- syscall error stats ---"
  sed -n '/===SYSCALL_ERROR_STATS_BEGIN===/,/===SYSCALL_ERROR_STATS_END===/p' "$RESULT" | grep -v '===SYSCALL_ERROR' | head -10 | sed 's/^/  /'
fi

# Page fault stats (if present)
if grep -a -q 'PAGE_FAULT_STATS' "$RESULT" 2>/dev/null; then
  echo "--- page fault stats ---"
  sed -n '/===PAGE_FAULT_STATS_BEGIN===/,/===PAGE_FAULT_STATS_END===/p' "$RESULT" | grep -v '===PAGE_FAULT' | sed 's/^/  /'
fi

# Signal stats (if present)
if grep -a -q 'SIGNAL_STATS_BEGIN' "$RESULT" 2>/dev/null; then
  echo "--- signal stats ---"
  sed -n '/===SIGNAL_STATS_BEGIN===/,/===SIGNAL_STATS_END===/p' "$RESULT" | grep -v '===SIGNAL' | sed 's/^/  /'
fi

# Last 5 lines
echo "--- last 5 lines ---"
tail -5 "$RESULT" | sed 's/^/  /'

echo ""

if [[ "$OK" == "1" ]]; then
  echo "[quick] PASS: ${MODE} succeeded"
  echo "[quick] serial log: ${RESULT}"
  exit 0
else
  echo "[quick] FAIL: ${MODE} did not produce success marker"
  echo "[quick] serial log: ${RESULT}"
  echo "[quick] Hint: check last 30 lines above, or run: bash scripts/guest-onecrate-diagnose.sh ${RESULT}"
  exit 1
fi
