#!/usr/bin/env bash
set -euo pipefail

case_name="${CASE_NAME:-cargo-buildscript-wave-smp${SMP:-8}-j${JOBS:-8}}"
kernel="${KERNEL:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-hvf-smp8-dir-cookie-rename-hvfopt-20260523.bin}"
img="${IMG:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"
smp="${SMP:-8}"
jobs="${JOBS:-8}"
mem="${MEM:-4096M}"
crate_count="${CRATE_COUNT:-64}"
monitor_interval="${MONITOR_INTERVAL:-15}"
timeout_sec="${TIMEOUT_SEC:-720}"
log_dir="${LOG_DIR:-/Users/txc/code/Auto-OS/过程记录/最终材料/logs}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
log="${LOG:-${log_dir}/hvf-aarch64-${case_name}-${stamp}.log}"

mkdir -p "$log_dir" /tmp/auto-os-hvf

guest_auto="/tmp/auto-os-hvf/hvf-cargo-buildscript-wave-${stamp}.sh"
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
export CARGO_BUILD_JOBS=$jobs
export RAYON_NUM_THREADS=$jobs
export CARGO_TARGET_DIR=/tmp/cargo-buildscript-wave-target

work=/tmp/cargo-buildscript-wave
count=$crate_count
monitor_interval=$monitor_interval

emit_proc_detail() {
  pid="\$1"
  [ -d "/proc/\$pid" ] || return 0
  comm=\$(cat "/proc/\$pid/comm" 2>/dev/null || true)
  cmdline=\$(tr '\\0' ' ' <"/proc/\$pid/cmdline" 2>/dev/null || true)
  case "\$comm \$cmdline" in
    *cargo*|*rustc*|*build-script*|*dep[0-9]*|*cc*|*ld*)
      echo "---PROC-DETAIL pid=\$pid comm=\$comm---"
      echo "cmdline=\$cmdline"
      echo "status_begin pid=\$pid"
      cat "/proc/\$pid/status" 2>/dev/null || true
      echo "status_end pid=\$pid"
      echo "stat=\$(cat "/proc/\$pid/stat" 2>/dev/null || true)"
      echo "fd_begin pid=\$pid"
      ls -l "/proc/\$pid/fd" 2>/dev/null || true
      echo "fd_end pid=\$pid"
      echo "children=\$(cat "/proc/\$pid/task/\$pid/children" 2>/dev/null || true)"
      echo "task_begin pid=\$pid"
      for td in "/proc/\$pid/task/"*; do
        [ -d "\$td" ] || continue
        tid="\${td##*/}"
        echo "---TASK pid=\$pid tid=\$tid---"
        echo "task_stat=\$(cat "\$td/stat" 2>/dev/null || true)"
        echo "task_wchan=\$(cat "\$td/wchan" 2>/dev/null || true)"
        echo "task_children=\$(cat "\$td/children" 2>/dev/null || true)"
        cat "\$td/status" 2>/dev/null | sed 's/^/task_status: /' || true
      done
      echo "task_end pid=\$pid"
      ;;
  esac
}

snapshot_proc() {
  echo "===CARGO-WAVE-SNAPSHOT t=\$(date +%s)==="
  echo "proc_stat_begin"
  cat /proc/stat 2>/dev/null || true
  echo "proc_stat_end"
  echo "ps_begin"
  ps -o pid,ppid,stat,etime,args 2>/dev/null || ps w 2>/dev/null || ps
  echo "ps_end"
  for d in /proc/[0-9]*; do
    [ -d "\$d" ] || continue
    emit_proc_detail "\${d##*/}"
  done
  echo "===CARGO-WAVE-SNAPSHOT-END t=\$(date +%s)==="
}

rm -rf "\$work" "\$CARGO_TARGET_DIR"
mkdir -p "\$work/src"
cd "\$work" || exit 1

{
  echo '[package]'
  echo 'name = "cargo-buildscript-wave-root"'
  echo 'version = "0.1.0"'
  echo 'edition = "2021"'
  echo
  echo '[dependencies]'
  i=0
  while [ "\$i" -lt "\$count" ]; do
    echo "dep\$i = { path = \"dep\$i\" }"
    i=\$((i + 1))
  done
} > Cargo.toml

{
  echo 'fn main() {'
  echo '    let mut sum: usize = 0;'
  i=0
  while [ "\$i" -lt "\$count" ]; do
    echo "    sum += dep\$i::value();"
    i=\$((i + 1))
  done
  echo '    println!("sum={}", sum);'
  echo '}'
} > src/main.rs

i=0
while [ "\$i" -lt "\$count" ]; do
  d="dep\$i"
  mkdir -p "\$d/src"
  cat > "\$d/Cargo.toml" <<CRATE
[package]
name = "\$d"
version = "0.1.0"
edition = "2021"
build = "build.rs"
CRATE
  cat > "\$d/build.rs" <<BUILD
use std::{env, fs, path::PathBuf};
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:warning=build-script-\$i");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    fs::write(out.join("generated.rs"), "pub const VALUE: usize = \$i;\\n").unwrap();
}
BUILD
  cat > "\$d/src/lib.rs" <<'LIB'
include!(concat!(env!("OUT_DIR"), "/generated.rs"));
pub fn value() -> usize { VALUE }
LIB
  i=\$((i + 1))
done

echo "===CARGO-BUILDSCRIPT-WAVE-BEGIN count=\$count jobs=\$CARGO_BUILD_JOBS monitor_interval=\$monitor_interval==="
echo "cpu_count=\$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
/usr/bin/cargo --version || true
\$RUSTC --version || true

(
  while :; do
    snapshot_proc
    sleep "\$monitor_interval"
  done
) &
monitor_pid="\$!"

start=\$(date +%s)
set +e
/usr/bin/cargo build --release -j"$jobs" --offline
rc=\$?
set -e
end=\$(date +%s)
elapsed=\$((end - start))

kill "\$monitor_pid" 2>/dev/null || true
wait "\$monitor_pid" 2>/dev/null || true
snapshot_proc

echo "===CARGO-BUILDSCRIPT-WAVE-END rc=\$rc elapsed=\$elapsed==="
if [ "\$rc" = 0 ]; then
  "\$CARGO_TARGET_DIR/release/cargo-buildscript-wave-root" || rc=\$?
fi
if [ "\$rc" = 0 ]; then
  echo "===CARGO-BUILDSCRIPT-WAVE-PASS elapsed=\$elapsed==="
else
  echo "===CARGO-BUILDSCRIPT-WAVE-FAIL rc=\$rc elapsed=\$elapsed==="
fi
exit "\$rc"
EOF
chmod +x "$guest_auto"

debugfs_cmd="/tmp/auto-os-hvf/debugfs-cargo-buildscript-wave-${stamp}.cmd"
cat >"$debugfs_cmd" <<EOF
rm /opt/hvf-auto.sh
write $guest_auto /opt/hvf-auto.sh
sif /opt/hvf-auto.sh mode 0100755
EOF
/opt/homebrew/opt/e2fsprogs/sbin/debugfs -w -f "$debugfs_cmd" "$img" >/tmp/auto-os-hvf/debugfs-cargo-buildscript-wave.out 2>&1 || {
  cat /tmp/auto-os-hvf/debugfs-cargo-buildscript-wave.out
  exit 1
}

echo "log=$log"
echo "case=$case_name smp=$smp jobs=$jobs count=$crate_count timeout_sec=$timeout_sec kernel=$kernel"

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
  if grep -qa '===CARGO-BUILDSCRIPT-WAVE-PASS' "$log"; then
    rc=0
    break
  fi
  if grep -qa '===CARGO-BUILDSCRIPT-WAVE-FAIL' "$log"; then
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
  sleep 2
done

if kill -0 "$qemu_pid" 2>/dev/null; then
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
else
  wait "$qemu_pid" || rc=$?
fi

grep -aE 'smp =|cpu_count=|CARGO-BUILDSCRIPT-WAVE|CARGO-WAVE-SNAPSHOT|Building \[|Finished |sum=|error:|panicked at|Kernel panic|Unhandled trap|Segmentation fault|FATAL|PID   PPID|/usr/bin/cargo|/rustc' "$log" | tail -220 || true
exit "$rc"
