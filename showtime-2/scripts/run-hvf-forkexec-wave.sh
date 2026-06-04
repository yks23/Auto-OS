#!/usr/bin/env bash
set -euo pipefail

case_name="${CASE_NAME:-forkexec-wave-smp${SMP:-8}-j${JOBS:-8}}"
kernel="${KERNEL:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-hvf-smp8-hvfopt-wake-local-20260524.bin}"
img="${IMG:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"
smp="${SMP:-8}"
jobs="${JOBS:-8}"
mem="${MEM:-4096M}"
task_count="${TASK_COUNT:-240}"
timeout_sec="${TIMEOUT_SEC:-120}"
log_dir="${LOG_DIR:-/Users/txc/code/Auto-OS/showtime-2/logs}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
log="${LOG:-${log_dir}/hvf-aarch64-${case_name}-${stamp}.log}"

mkdir -p "$log_dir" /tmp/auto-os-hvf

guest_auto="/tmp/auto-os-hvf/hvf-forkexec-wave-${stamp}.sh"
cat >"$guest_auto" <<EOF
#!/bin/sh
set -u

count=$task_count
jobs=$jobs

echo "===FORKEXEC-WAVE-BEGIN count=\$count jobs=\$jobs==="
echo "cpu_count=\$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
start=\$(date +%s)
rc=0
batch=0
while [ "\$batch" -lt "\$count" ]; do
  echo "===FORKEXEC-WAVE-BATCH-BEGIN start=\$batch t=\$(date +%s)==="
  pids=""
  j=0
  while [ "\$j" -lt "\$jobs" ] && [ \$((batch + j)) -lt "\$count" ]; do
    /bin/true &
    pids="\$pids \$!"
    j=\$((j + 1))
  done
  for pid in \$pids; do
    wait "\$pid" || rc=\$?
  done
  echo "===FORKEXEC-WAVE-BATCH-END start=\$batch rc=\$rc t=\$(date +%s)==="
  if [ "\$rc" != 0 ]; then
    break
  fi
  batch=\$((batch + jobs))
done
end=\$(date +%s)
elapsed=\$((end - start))
echo "===FORKEXEC-WAVE-END rc=\$rc elapsed=\$elapsed==="
if [ "\$rc" = 0 ]; then
  echo "===FORKEXEC-WAVE-PASS elapsed=\$elapsed==="
else
  echo "===FORKEXEC-WAVE-FAIL rc=\$rc elapsed=\$elapsed==="
fi
exit "\$rc"
EOF
chmod +x "$guest_auto"

debugfs_cmd="/tmp/auto-os-hvf/debugfs-forkexec-wave-${stamp}.cmd"
cat >"$debugfs_cmd" <<EOF
rm /opt/hvf-auto.sh
write $guest_auto /opt/hvf-auto.sh
sif /opt/hvf-auto.sh mode 0100755
EOF
/opt/homebrew/opt/e2fsprogs/sbin/debugfs -w -f "$debugfs_cmd" "$img" >/tmp/auto-os-hvf/debugfs-forkexec-wave.out 2>&1 || {
  cat /tmp/auto-os-hvf/debugfs-forkexec-wave.out
  exit 1
}

echo "log=$log"
echo "case=$case_name smp=$smp jobs=$jobs count=$task_count timeout_sec=$timeout_sec kernel=$kernel"

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
  if grep -qa '===FORKEXEC-WAVE-PASS' "$log"; then
    rc=0
    break
  fi
  if grep -qa '===FORKEXEC-WAVE-FAIL' "$log"; then
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

grep -aE 'smp =|cpu_count=|FORKEXEC-WAVE|panicked at|Kernel panic|Unhandled trap|Segmentation fault|FATAL' "$log" | tail -120 || true
exit "$rc"
