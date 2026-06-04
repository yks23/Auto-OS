#!/usr/bin/env bash
set -euo pipefail

case_name="${CASE_NAME:-rust-sysroot-preflight-smp${SMP:-8}}"
kernel="${KERNEL:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-hvf-smp8-wake-local-20260524.bin}"
img="${IMG:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"
smp="${SMP:-8}"
mem="${MEM:-4096M}"
target="${BUILD_TARGET:-aarch64-unknown-none-softfloat}"
timeout_sec="${TIMEOUT_SEC:-180}"
log_dir="${LOG_DIR:-/Users/txc/code/Auto-OS/showtime-2/logs}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
log="${LOG:-${log_dir}/hvf-aarch64-${case_name}-${stamp}.log}"

mkdir -p "$log_dir" /tmp/auto-os-hvf

guest_auto="/tmp/auto-os-hvf/hvf-rust-sysroot-preflight-${stamp}.sh"
cat >"$guest_auto" <<EOF
#!/bin/sh
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/rust-nightly/bin"
export LD_LIBRARY_PATH="/usr/lib:/opt/rust-nightly/lib:\${LD_LIBRARY_PATH:-}"
export RUSTC="/opt/rustc-nightly-sysroot"
export RUSTDOC="/opt/rustdoc-nightly-sysroot"
export RUSTC_BOOTSTRAP=1
export CARGO_INCREMENTAL=0
export CARGO_NET_OFFLINE=true

target="$target"
work="/tmp/hvf-rust-sysroot-preflight"
target_dir="/tmp/hvf-rust-sysroot-preflight-target"

echo "===HVF-SYSROOT-PREFLIGHT-BEGIN target=\$target t=\$(date +%s)==="
echo "cpu_count=\$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
"\$RUSTC" --version || true
/usr/bin/cargo --version || true

libdir=\$("\$RUSTC" --target "\$target" --print target-libdir 2>&1)
libdir_rc=\$?
echo "target_libdir_rc=\$libdir_rc"
echo "target_libdir=\$libdir"
if [ "\$libdir_rc" != 0 ] || [ ! -d "\$libdir" ]; then
  echo "===HVF-SYSROOT-PREFLIGHT-FAIL reason=target-libdir target=\$target==="
  exit 1
fi

ls -la "\$libdir" 2>/dev/null || true
for pat in 'libcore-*.rlib' 'liballoc-*.rlib' 'libcompiler_builtins-*.rlib'; do
  set +e
  found=\$(find "\$libdir" -name "\$pat" -maxdepth 1 2>/dev/null | head -1)
  set -e
  echo "sysroot_probe pattern=\$pat found=\${found:-}"
  if [ -z "\$found" ]; then
    echo "===HVF-SYSROOT-PREFLIGHT-FAIL reason=missing-\$pat target=\$target==="
    exit 1
  fi
done

rm -rf "\$work" "\$target_dir"
mkdir -p "\$work/src"
cat >"\$work/Cargo.toml" <<'TOML'
[package]
name = "hvf-rust-sysroot-preflight"
version = "0.0.0"
edition = "2024"

[lib]
path = "src/lib.rs"
TOML

cat >"\$work/src/lib.rs" <<'RS'
#![no_std]
extern crate alloc;

pub fn alloc_probe() -> usize {
    alloc::vec::Vec::<u8>::new().len()
}
RS

start=\$(date +%s)
echo "===HVF-SYSROOT-CARGO-START t=\$start==="
set +e
/usr/bin/cargo build --manifest-path "\$work/Cargo.toml" \\
  --target "\$target" \\
  --target-dir "\$target_dir" \\
  --release \\
  --offline
rc=\$?
set -e
end=\$(date +%s)
echo "===HVF-SYSROOT-CARGO-END rc=\$rc elapsed=\$((end - start)) t=\$end==="
if [ "\$rc" = 0 ]; then
  echo "===HVF-SYSROOT-PREFLIGHT-PASS target=\$target elapsed=\$((end - start))==="
else
  echo "===HVF-SYSROOT-PREFLIGHT-FAIL reason=cargo rc=\$rc target=\$target==="
fi
exit "\$rc"
EOF
chmod +x "$guest_auto"

debugfs_cmd="/tmp/auto-os-hvf/debugfs-rust-sysroot-preflight-${stamp}.cmd"
cat >"$debugfs_cmd" <<EOF
rm /opt/hvf-auto.sh
write $guest_auto /opt/hvf-auto.sh
sif /opt/hvf-auto.sh mode 0100755
EOF
/opt/homebrew/opt/e2fsprogs/sbin/debugfs -w -f "$debugfs_cmd" "$img" >/tmp/auto-os-hvf/debugfs-rust-sysroot-preflight.out 2>&1 || {
  cat /tmp/auto-os-hvf/debugfs-rust-sysroot-preflight.out
  exit 1
}

echo "log=$log"
echo "case=$case_name smp=$smp target=$target timeout_sec=$timeout_sec kernel=$kernel"

/opt/homebrew/bin/qemu-system-aarch64 \
  -snapshot \
  -nographic \
  -accel hvf \
  -machine virt,gic-version=3 \
  -cpu host \
  -m "$mem" \
  -smp "$smp" \
  -device virtio-blk-pci,drive=disk0 \
  -drive "id=disk0,if=none,format=raw,file=$img,file.locking=off" \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  -kernel "$kernel" \
  -monitor none \
  -serial mon:stdio \
  >"$log" 2>&1 &

qemu_pid=$!
start_epoch="$(date +%s)"
deadline=$((start_epoch + timeout_sec))
rc=124
while kill -0 "$qemu_pid" 2>/dev/null; do
  if grep -qa '===HVF-SYSROOT-PREFLIGHT-PASS' "$log"; then
    rc=0
    break
  fi
  if grep -qa '===HVF-SYSROOT-PREFLIGHT-FAIL' "$log"; then
    rc=1
    break
  fi
  if grep -qaiE 'panicked at|Kernel panic|Unhandled trap|Segmentation fault|FATAL' "$log"; then
    rc=1
    break
  fi
  now_epoch="$(date +%s)"
  if [ "$now_epoch" -ge "$deadline" ]; then
    rc=124
    break
  fi
  sleep 1
done

if kill -0 "$qemu_pid" 2>/dev/null; then
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
else
  wait "$qemu_pid" || rc=$?
fi

grep -aE 'smp =|cpu_count=|HVF-SYSROOT|target_libdir|sysroot_probe|error:|FATAL|panic|trap' "$log" | tail -160 || true
exit "$rc"
