#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/Users/txc/code/Auto-OS}"
SRC_REPO="${SRC_REPO:-$ROOT/tgoskits}"
STAMP="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
LOG_DIR="${LOG_DIR:-$ROOT/showtime-2/logs}"
JOBS="${JOBS:-8}"
SMP="${SMP:-8}"

mkdir -p "$LOG_DIR"

SRC_COPY="${SRC_COPY:-/private/tmp/host-starryos-aligned-j${JOBS}-src-${STAMP}}"
TARGET_DIR="${TARGET_DIR:-/private/tmp/host-starryos-aligned-j${JOBS}-target-${STAMP}}"
LOG="${LOG:-$LOG_DIR/host-starryos-aligned-aarch64-smp8-j${JOBS}-${STAMP}.log}"

rm -rf "$SRC_COPY" "$TARGET_DIR"
mkdir -p "$SRC_COPY" "$TARGET_DIR"

rsync -a --delete \
  --exclude .git \
  --exclude target \
  --exclude .m6-work \
  "$SRC_REPO"/ "$SRC_COPY"/

axalloc_toml="$SRC_COPY/os/arceos/modules/axalloc/Cargo.toml"
if [ -f "$axalloc_toml" ]; then
  perl -0pi -e 's#default = \["tlsf", "ax-allocator/page-alloc-4g"\]#default = ["slab", "ax-allocator/page-alloc-4g"]#g; s/^\s*"tlsf",\s*\n//mg' "$axalloc_toml"
fi

starryos_toml="$SRC_COPY/os/StarryOS/starryos/Cargo.toml"
if [ -f "$starryos_toml" ]; then
  perl -0pi -e 's#starry-kernel = \{ workspace = true, features = \["dev-log", "ext4"\] \}#starry-kernel = { version = "0.5.12", path = "../kernel", default-features = false, features = ["dev-log", "ext4"] }#g' "$starryos_toml"
fi

DEFCONFIG="$SRC_COPY/os/arceos/configs/defconfig.toml"
PLAT_CONFIG="$SRC_COPY/components/axplat_crates/platforms/axplat-aarch64-qemu-virt/axconfig.toml"
AX_CONFIG="$SRC_COPY/os/StarryOS/.axconfig.host-aligned-aarch64.toml"
ax-config-gen \
  "$DEFCONFIG" "$PLAT_CONFIG" \
  -w "arch=\"aarch64\"" \
  -w "platform=\"aarch64-qemu-virt\"" \
  -w "plat.max-cpu-num=${SMP}" \
  -w "devices.timer-irq=27" \
  -o "$AX_CONFIG"

{
  echo "===HOST-ALIGNED-STARRYOS-BEGIN stamp=$STAMP src=$SRC_COPY target=$TARGET_DIR==="
  echo "settings: host=$(uname -s) $(uname -m) jobs=$JOBS smp=$SMP"
  echo "settings: command=cargo build -p starryos --bin starryos --target aarch64-unknown-none-softfloat -Z build-std=core,alloc,compiler_builtins --features qemu,gic-v3,cntv-timer,smp --release"
  echo "settings: AX_CONFIG_PATH=$AX_CONFIG"
  echo "settings: CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_OPT_LEVEL=0 CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256"
  echo "settings: FAST_ALLOC_SLAB_ONLY=1 FAST_SELFBUILD_NO_DYNAMIC_DEBUG=1"
  echo "settings: note=aligned-to-guest-profile; no StarryOS guest, no QEMU/HVF, no guest FS/syscall/scheduler"
  cd "$SRC_COPY"
  export RUSTC_BOOTSTRAP=1
  export CARGO_INCREMENTAL=0
  export CARGO_NET_OFFLINE=true
  export CARGO_BUILD_JOBS="$JOBS"
  export RAYON_NUM_THREADS="$JOBS"
  export CARGO_PROFILE_RELEASE_LTO=false
  export CARGO_PROFILE_RELEASE_OPT_LEVEL=0
  export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256
  export AX_ARCH=aarch64
  export AX_PLATFORM=aarch64-qemu-virt
  export AX_MODE=release
  export AX_CONFIG_PATH="$AX_CONFIG"
  export RUSTFLAGS="-Clink-arg=-Tlinker.x -Clink-arg=-no-pie -Clink-arg=-znostart-stop-gc"
  rustc --version
  cargo --version
  start="$(date +%s)"
  set +e
  cargo build \
    -p starryos \
    --bin starryos \
    --target aarch64-unknown-none-softfloat \
    -Z build-std=core,alloc,compiler_builtins \
    --target-dir "$TARGET_DIR" \
    --features qemu,gic-v3,cntv-timer,smp \
    --release
  rc="$?"
  set -e
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "===HOST-ALIGNED-STARRYOS-END jobs=$JOBS rc=$rc elapsed=$elapsed==="
  if [ "$rc" = "0" ]; then
    ls -lh "$TARGET_DIR/aarch64-unknown-none-softfloat/release/starryos" || true
    echo "===HOST-ALIGNED-STARRYOS-PASS jobs=$JOBS elapsed=$elapsed==="
  else
    echo "===HOST-ALIGNED-STARRYOS-FAIL jobs=$JOBS rc=$rc elapsed=$elapsed==="
  fi
  exit "$rc"
} 2>&1 | tee "$LOG"
