#!/usr/bin/env bash
# infra-smoke.sh — verify guest QEMU infrastructure on this host.
#
# Runs a series of checks and reports PASS/FAIL for each.
# Designed for macOS arm64 + Docker Desktop + Homebrew QEMU.
#
# Usage:
#   bash scripts/infra-smoke.sh
#   bash scripts/infra-smoke.sh --fix   # attempt fixes where possible
#
# Exit code: 0 if all pass, 1 if any fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
GUEST_RUNS="${REPO}/.guest-runs"

DO_FIX=0
if [[ "${1:-}" == "--fix" ]]; then
  DO_FIX=1
fi

PASS=0
FAIL=0
WARN=0

result() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    PASS) PASS=$((PASS + 1)); printf "  PASS  %s" "$name" ;;
    FAIL) FAIL=$((FAIL + 1)); printf "  FAIL  %s" "$name" ;;
    WARN) WARN=$((WARN + 1)); printf "  WARN  %s" "$name" ;;
  esac
  if [[ -n "$detail" ]]; then
    printf "  (%s)" "$detail"
  fi
  echo
}

section() {
  echo ""
  echo "--- $1 ---"
}

# ================================================================
section "1. Docker"
# ================================================================

if docker info >/dev/null 2>&1; then
  DOCKER_VER="$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo unknown)"
  DOCKER_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || echo unknown)"
  result PASS "Docker daemon running" "version=${DOCKER_VER} arch=${DOCKER_ARCH}"
else
  result FAIL "Docker daemon running" "docker info failed — is Docker Desktop running?"
fi

# Check riscv64 emulation via Docker Desktop's built-in QEMU
if docker run --rm --platform linux/riscv64 alpine echo ok 2>/dev/null | grep -q ok; then
  result PASS "Docker riscv64 emulation" "linux/riscv64 containers work"
else
  result WARN "Docker riscv64 emulation" "linux/riscv64 container failed — may need Docker Desktop restart or Clean/Purge data"
fi

# Check linux/amd64 emulation (Rosetta or QEMU)
if docker run --rm --platform linux/amd64 alpine echo ok 2>/dev/null | grep -q ok; then
  result PASS "Docker amd64 emulation" "linux/amd64 containers work (Rosetta/QEMU)"
else
  result WARN "Docker amd64 emulation" "linux/amd64 container test failed (transient network issue?)"
fi

# Check auto-os/starry image
if docker image inspect auto-os/starry:latest >/dev/null 2>&1; then
  IMG_ARCH="$(docker inspect auto-os/starry:latest --format '{{.Architecture}}' 2>/dev/null || echo unknown)"
  IMG_SIZE="$(docker images auto-os/starry:latest --format '{{.Size}}' 2>/dev/null || echo unknown)"
  result PASS "auto-os/starry image exists" "arch=${IMG_ARCH} size=${IMG_SIZE}"
else
  result FAIL "auto-os/starry image exists" "not found — run: docker build --platform linux/amd64 -t auto-os/starry -f Dockerfile ."
fi

# ================================================================
section "2. QEMU system emulator"
# ================================================================

QEMU_SYS=""
if command -v qemu-system-riscv64 >/dev/null 2>&1; then
  QEMU_SYS="$(command -v qemu-system-riscv64)"
  QEMU_VER="$(qemu-system-riscv64 --version 2>/dev/null | head -1 || echo unknown)"
  result PASS "qemu-system-riscv64 available" "path=${QEMU_SYS} version=${QEMU_VER}"
else
  result FAIL "qemu-system-riscv64 available" "not found — run: brew install qemu"
fi

# ================================================================
section "3. Kernel image"
# ================================================================

KERNEL_CANDIDATES=(
  "${GUEST_RUNS}/saved/starryos-riscv64.release.bin"
  "${REPO}/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
)

KERNEL_BIN=""
KERNEL_ELF=""
for c in "${KERNEL_CANDIDATES[@]}"; do
  if [[ -f "$c" ]]; then
    if [[ "$c" == *.bin ]]; then
      KERNEL_BIN="$c"
    else
      KERNEL_ELF="$c"
    fi
  fi
done

if [[ -n "$KERNEL_BIN" ]]; then
  SZ="$(ls -lh "$KERNEL_BIN" | awk '{print $5}')"
  result PASS "Kernel binary (flat)" "path=${KERNEL_BIN} size=${SZ}"
elif [[ -n "$KERNEL_ELF" ]]; then
  SZ="$(ls -lh "$KERNEL_ELF" | awk '{print $5}')"
  result WARN "Kernel ELF exists but no flat binary" "path=${KERNEL_ELF} size=${SZ} — need objcopy"
  # Check if we can do objcopy
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
  if [[ -n "$OBJCOPY" ]]; then
    echo "         Can convert: ${OBJCOPY} -I elf64-littleriscv -O binary ${KERNEL_ELF} ${GUEST_RUNS}/saved/starryos-riscv64.release.bin"
    if [[ "$DO_FIX" == "1" ]]; then
      mkdir -p "${GUEST_RUNS}/saved"
      "$OBJCOPY" -I elf64-littleriscv -O binary "$KERNEL_ELF" "${GUEST_RUNS}/saved/starryos-riscv64.release.bin"
      echo "         Fixed: created ${GUEST_RUNS}/saved/starryos-riscv64.release.bin"
      KERNEL_BIN="${GUEST_RUNS}/saved/starryos-riscv64.release.bin"
    fi
  fi
else
  result FAIL "Kernel image" "no kernel binary or ELF found — run kernel build first"
fi

# ================================================================
section "4. Rootfs images"
# ================================================================

ROOTFS_CANDIDATES=(
  "rootfs-selfbuild-riscv64.img"
  "rootfs-smoke-riscv64.img"
  "rootfs-diag.img"
  "rootfs-vv.img"
)

FOUND_ROOTFS=""
for name in "${ROOTFS_CANDIDATES[@]}"; do
  path="${GUEST_RUNS}/${name}"
  if [[ -f "$path" ]]; then
    SZ="$(ls -lh "$path" | awk '{print $5}')"
    FSTYPE="$(file "$path" 2>/dev/null | sed 's/.*: //' | head -c 60)"
    result PASS "Rootfs ${name}" "size=${SZ} type=${FSTYPE}"
    if [[ -z "$FOUND_ROOTFS" ]]; then
      FOUND_ROOTFS="$path"
    fi
  fi
done

if [[ -z "$FOUND_ROOTFS" ]]; then
  result FAIL "Rootfs images" "no rootfs images found in ${GUEST_RUNS}"
fi

# ================================================================
section "5. QEMU guest boot (5-second smoke)"
# ================================================================

if [[ -z "$KERNEL_BIN" || -z "$FOUND_ROOTFS" ]]; then
  result WARN "QEMU guest boot" "skipped: missing kernel or rootfs"
else
  BOOT_OUT="${GUEST_RUNS}/infra-smoke-boot-$$.txt"
  echo "         Booting QEMU for 5 seconds..."

  # Use a background process + sleep + kill for reliable timeout on macOS.
  # perl's alarm+exec sometimes loses output when stdout is redirected.
  QEMU_RC=0
  qemu-system-riscv64 \
    -nographic -machine virt -bios default -smp 4 -m 4G \
    -kernel "$KERNEL_BIN" -cpu rv64 \
    -monitor none -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive "id=disk0,if=none,format=raw,file=${FOUND_ROOTFS},file.locking=off" \
    >"$BOOT_OUT" 2>&1 &
  QEMU_PID=$!
  sleep 5
  kill "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || QEMU_RC=$?

  if [[ -s "$BOOT_OUT" ]]; then
    LINES="$(wc -l < "$BOOT_OUT")"
    HAS_SBI="$(grep -c 'OpenSBI' "$BOOT_OUT" 2>/dev/null || echo 0)"
    HAS_STARRY="$(grep -c 'd8888' "$BOOT_OUT" 2>/dev/null || echo 0)"
    HAS_BOOT="$(grep -c 'Boot at' "$BOOT_OUT" 2>/dev/null || echo 0)"

    if [[ "$HAS_SBI" -gt 0 && "$HAS_STARRY" -gt 0 ]]; then
      result PASS "QEMU guest boot (5s)" "serial_lines=${LINES} opensbi=${HAS_SBI} starry_banner=${HAS_STARRY} boot_time=${HAS_BOOT}"
    elif [[ "$HAS_SBI" -gt 0 ]]; then
      result WARN "QEMU guest boot (5s)" "OpenSBI started but StarryOS banner not reached — serial_lines=${LINES}"
    else
      result FAIL "QEMU guest boot (5s)" "no OpenSBI output — serial_lines=${LINES}"
    fi

    # Show last 10 lines for diagnostics
    echo "         Last 10 lines of serial output:"
    tail -10 "$BOOT_OUT" | sed 's/^/         | /'
  else
    result FAIL "QEMU guest boot (5s)" "no serial output captured"
  fi
  rm -f "$BOOT_OUT"
fi

# ================================================================
section "6. macOS-specific tools"
# ================================================================

# Check for rust-objcopy (needed to convert kernel ELF to flat binary on macOS)
if command -v rust-objcopy >/dev/null 2>&1; then
  result PASS "rust-objcopy" "path=$(command -v rust-objcopy)"
else
  result WARN "rust-objcopy" "not found — install cargo-binutils: cargo install cargo-binutils"
fi

# Check for llvm-objcopy in rust toolchain
SYSROOT="$(rustc --print sysroot 2>/dev/null || true)"
HOST="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p' || true)"
if [[ -n "$SYSROOT" && -n "$HOST" && -f "${SYSROOT}/lib/rustlib/${HOST}/bin/llvm-objcopy" ]]; then
  result PASS "llvm-objcopy (rust toolchain)" "path=${SYSROOT}/lib/rustlib/${HOST}/bin/llvm-objcopy"
else
  result WARN "llvm-objcopy (rust toolchain)" "not found in rust toolchain"
fi

# ================================================================
# Summary
# ================================================================

echo ""
echo "============================================================"
echo "  infra-smoke summary: PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
