#!/usr/bin/env bash
set -euo pipefail

case_name="${CASE_NAME:-rustc-buildscript-wave-smp${SMP:-8}-j${JOBS:-8}}"
kernel="${KERNEL:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-hvf-smp8-dir-cookie-rename-hvfopt-20260523.bin}"
img="${IMG:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"
smp="${SMP:-8}"
jobs="${JOBS:-8}"
mem="${MEM:-4096M}"
crate_count="${CRATE_COUNT:-64}"
monitor_interval="${MONITOR_INTERVAL:-10}"
timeout_sec="${TIMEOUT_SEC:-360}"
log_dir="${LOG_DIR:-/Users/txc/code/Auto-OS/showtime-2/logs}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
log="${LOG:-${log_dir}/hvf-aarch64-${case_name}-${stamp}.log}"

mkdir -p "$log_dir" /tmp/auto-os-hvf

guest_auto="/tmp/auto-os-hvf/hvf-rustc-buildscript-wave-${stamp}.sh"
cat >"$guest_auto" <<EOF
#!/bin/sh
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/rust-nightly/bin"
export LD_LIBRARY_PATH="/usr/lib:/opt/rust-nightly/lib:\${LD_LIBRARY_PATH:-}"
export RUSTC="/opt/rustc-nightly-sysroot"
export RUSTC_BOOTSTRAP=1

work=/tmp/rustc-buildscript-wave
out=/tmp/rustc-buildscript-wave-out
count=$crate_count
jobs=$jobs
monitor_interval=$monitor_interval

snapshot_proc() {
  echo "===RUSTC-WAVE-SNAPSHOT t=\$(date +%s)==="
  cat /proc/stat 2>/dev/null || true
  ps -o pid,ppid,stat,etime,args 2>/dev/null || ps w 2>/dev/null || ps
  for d in /proc/[0-9]*; do
    [ -d "\$d" ] || continue
    pid="\${d##*/}"
    comm=\$(cat "/proc/\$pid/comm" 2>/dev/null || true)
    cmdline=\$(tr '\\0' ' ' <"/proc/\$pid/cmdline" 2>/dev/null || true)
    case "\$comm \$cmdline" in
      *rustc*|*build_script_build*|*busybox*)
        echo "---PROC pid=\$pid comm=\$comm cmdline=\$cmdline---"
        echo "stat=\$(cat "/proc/\$pid/stat" 2>/dev/null || true)"
        echo "fd_begin pid=\$pid"
        ls -l "/proc/\$pid/fd" 2>/dev/null || true
        echo "fd_end pid=\$pid"
        echo "status_begin pid=\$pid"
        cat "/proc/\$pid/status" 2>/dev/null || true
        echo "status_end pid=\$pid"
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
  done
  echo "===RUSTC-WAVE-SNAPSHOT-END t=\$(date +%s)==="
}

rm -rf "\$work" "\$out"
mkdir -p "\$work" "\$out/deps" "\$out/build"

i=0
while [ "\$i" -lt "\$count" ]; do
  d="\$work/dep\$i"
  mkdir -p "\$d"
  cat > "\$d/build.rs" <<BUILD
use std::{env, fs, path::PathBuf};
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:warning=build-script-\$i");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap_or_else(|_| "/tmp".into()));
    fs::write(out.join("generated-\$i.rs"), "pub const VALUE: usize = \$i;\\n").unwrap();
}
BUILD
  i=\$((i + 1))
done

echo "===RUSTC-BUILDSCRIPT-WAVE-BEGIN count=\$count jobs=\$jobs==="
echo "cpu_count=\$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
\$RUSTC --version || true

(
  while :; do
    snapshot_proc
    sleep "\$monitor_interval"
  done
) &
monitor_pid="\$!"

start=\$(date +%s)
rc=0
batch=0
while [ "\$batch" -lt "\$count" ]; do
  echo "===RUSTC-WAVE-BATCH-BEGIN start=\$batch t=\$(date +%s)==="
  pids=""
  j=0
  while [ "\$j" -lt "\$jobs" ] && [ \$((batch + j)) -lt "\$count" ]; do
    i=\$((batch + j))
    mkdir -p "\$out/build/dep\$i"
    OUT_DIR="\$out/build/dep\$i" \\
      "\$RUSTC" \\
        --crate-name build_script_build \\
        --edition=2021 "\$work/dep\$i/build.rs" \\
        --error-format=json \\
        --json=diagnostic-rendered-ansi,artifacts,future-incompat \\
        --diagnostic-width=110 \\
        --crate-type bin \\
        --emit=dep-info,link \\
        -C embed-bitcode=no \\
        -C debug-assertions=off \\
        --check-cfg 'cfg(docsrs,test)' \\
        --check-cfg 'cfg(feature, values())' \\
        -C metadata="wave\$i" \\
        -C extra-filename="-wave\$i" \\
        --out-dir "\$out/build/dep\$i" \\
        -C strip=debuginfo \\
        -L "dependency=\$out/deps" \\
        >"\$out/build/dep\$i/stdout.log" 2>"\$out/build/dep\$i/stderr.log" &
    pids="\$pids \$!"
    j=\$((j + 1))
  done
  for pid in \$pids; do
    wait "\$pid" || rc=\$?
  done
  echo "===RUSTC-WAVE-BATCH-END start=\$batch rc=\$rc t=\$(date +%s)==="
  if [ "\$rc" != 0 ]; then
    echo "===RUSTC-WAVE-FAILED-LOGS-BEGIN batch=\$batch==="
    k="\$batch"
    while [ "\$k" -lt \$((batch + jobs)) ] && [ "\$k" -lt "\$count" ]; do
      echo "--- dep\$k stdout ---"
      cat "\$out/build/dep\$k/stdout.log" 2>/dev/null || true
      echo "--- dep\$k stderr ---"
      cat "\$out/build/dep\$k/stderr.log" 2>/dev/null || true
      k=\$((k + 1))
    done
    echo "===RUSTC-WAVE-FAILED-LOGS-END batch=\$batch==="
    break
  fi
  batch=\$((batch + jobs))
done

end=\$(date +%s)
elapsed=\$((end - start))
kill "\$monitor_pid" 2>/dev/null || true
wait "\$monitor_pid" 2>/dev/null || true
snapshot_proc

echo "===RUSTC-BUILDSCRIPT-WAVE-END rc=\$rc elapsed=\$elapsed==="
if [ "\$rc" = 0 ]; then
  echo "===RUSTC-BUILDSCRIPT-WAVE-PASS elapsed=\$elapsed==="
else
  echo "===RUSTC-BUILDSCRIPT-WAVE-FAIL rc=\$rc elapsed=\$elapsed==="
fi
exit "\$rc"
EOF
chmod +x "$guest_auto"

debugfs_cmd="/tmp/auto-os-hvf/debugfs-rustc-buildscript-wave-${stamp}.cmd"
cat >"$debugfs_cmd" <<EOF
rm /opt/hvf-auto.sh
write $guest_auto /opt/hvf-auto.sh
sif /opt/hvf-auto.sh mode 0100755
EOF
/opt/homebrew/opt/e2fsprogs/sbin/debugfs -w -f "$debugfs_cmd" "$img" >/tmp/auto-os-hvf/debugfs-rustc-buildscript-wave.out 2>&1 || {
  cat /tmp/auto-os-hvf/debugfs-rustc-buildscript-wave.out
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
  if grep -qa '===RUSTC-BUILDSCRIPT-WAVE-PASS' "$log"; then
    rc=0
    break
  fi
  if grep -qa '===RUSTC-BUILDSCRIPT-WAVE-FAIL' "$log"; then
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

grep -aE 'smp =|cpu_count=|RUSTC-BUILDSCRIPT-WAVE|RUSTC-WAVE-(BATCH|SNAPSHOT)|panicked at|Kernel panic|Unhandled trap|Segmentation fault|FATAL|PID   PPID|/rustc' "$log" | tail -180 || true
exit "$rc"
