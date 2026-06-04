#!/usr/bin/env bash
set -euo pipefail

case_name="${CASE_NAME:?set CASE_NAME, e.g. smp8-fs-exec-probe}"
kernel="${KERNEL:?set KERNEL path}"
img="${IMG:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"
smp="${SMP:-8}"
mem="${MEM:-4096M}"
file_count="${FILE_COUNT:-1500}"
rename_count="${RENAME_COUNT:-256}"
exec_count="${EXEC_COUNT:-300}"
log_dir="${LOG_DIR:-/Users/txc/code/Auto-OS/过程记录/最终材料/logs}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
log="${LOG:-${log_dir}/hvf-aarch64-probe-${case_name}-${stamp}.log}"
timeout_sec="${PROBE_TIMEOUT_SEC:-600}"

mkdir -p "$log_dir" /tmp/auto-os-hvf

guest_auto="/tmp/auto-os-hvf/hvf-probe-${case_name}-${stamp}.sh"
cat >"$guest_auto" <<EOF
#!/bin/sh
set -u

file_count=$file_count
exec_count=$exec_count
rename_count=$rename_count

phase_begin() {
  echo "===HVF-PROBE-PHASE-BEGIN name=\$1 t=\$(date +%s)==="
}

phase_end() {
  name="\$1"
  rc="\$2"
  start="\$3"
  end=\$(date +%s)
  echo "===HVF-PROBE-PHASE-END name=\$name rc=\$rc elapsed=\$((end - start)) t=\$end==="
}

run_tmpfs_create() {
  rm -rf /tmp/hvf-probe-tmpfs
  mkdir -p /tmp/hvf-probe-tmpfs
  i=0
  while [ "\$i" -lt "\$file_count" ]; do
    printf 'x\n' >"/tmp/hvf-probe-tmpfs/f\$i" || return 1
    i=\$((i + 1))
  done
  rm -rf /tmp/hvf-probe-tmpfs
}

run_ext4_create() {
  rm -rf /root/hvf-probe-ext4
  mkdir -p /root/hvf-probe-ext4
  i=0
  while [ "\$i" -lt "\$file_count" ]; do
    printf 'x\n' >"/root/hvf-probe-ext4/f\$i" || return 1
    i=\$((i + 1))
  done
  rm -rf /root/hvf-probe-ext4
}

run_rename_cleanup_one() {
  base="\$1"
  rm -rf "\$base"
  mkdir -p "\$base/src" "\$base/dst"
  i=0
  while [ "\$i" -lt "\$rename_count" ]; do
    printf 'src-%s\n' "\$i" >"\$base/src/s\$i" || return 1
    printf 'dst-%s\n' "\$i" >"\$base/dst/d\$i" || return 1
    i=\$((i + 1))
  done
  i=0
  while [ "\$i" -lt "\$rename_count" ]; do
    mv "\$base/src/s\$i" "\$base/dst/r\$i" || return 1
    i=\$((i + 1))
  done
  rmdir "\$base/src" || return 1
  rm -rf "\$base/dst" || return 1
  rmdir "\$base" || return 1
}

run_tmpfs_rename_cleanup() {
  run_rename_cleanup_one /tmp/hvf-probe-tmpfs-rename
}

run_ext4_rename_cleanup() {
  run_rename_cleanup_one /root/hvf-probe-ext4-rename
}

run_exec_true() {
  i=0
  while [ "\$i" -lt "\$exec_count" ]; do
    /bin/true || return 1
    i=\$((i + 1))
  done
}

run_phase() {
  name="\$1"
  phase_begin "\$name"
  start=\$(date +%s)
  set +e
  "run_\$name"
  rc=\$?
  set -e
  phase_end "\$name" "\$rc" "\$start"
  return "\$rc"
}

echo "===HVF-PROBE-RUN-BEGIN case=$case_name smp=$smp file_count=\$file_count rename_count=\$rename_count exec_count=\$exec_count==="
echo "cpu_count=\$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
echo "uname=\$(uname -a 2>/dev/null || true)"
echo "proc_stat_begin"
cat /proc/stat 2>/dev/null || true
echo "proc_stat_end"

run_phase tmpfs_create || exit 1
run_phase ext4_create || exit 1
run_phase tmpfs_rename_cleanup || exit 1
run_phase ext4_rename_cleanup || exit 1
run_phase exec_true || exit 1

echo "proc_stat_after_begin"
cat /proc/stat 2>/dev/null || true
echo "proc_stat_after_end"
echo "===HVF-PROBE-DONE case=$case_name rc=0==="
exit 0
EOF
chmod +x "$guest_auto"

debugfs_cmd="/tmp/auto-os-hvf/debugfs-replace-hvf-probe-${case_name}-${stamp}.cmd"
cat >"$debugfs_cmd" <<EOF
rm /opt/hvf-auto.sh
write $guest_auto /opt/hvf-auto.sh
sif /opt/hvf-auto.sh mode 0100755
EOF

/opt/homebrew/opt/e2fsprogs/sbin/debugfs -w -f "$debugfs_cmd" "$img" >/dev/null

echo "log=$log"
echo "case=$case_name smp=$smp file_count=$file_count rename_count=$rename_count exec_count=$exec_count kernel=$kernel"

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
deadline=$((SECONDS + timeout_sec))
rc=124
while kill -0 "$qemu_pid" 2>/dev/null; do
  if grep -qa "===HVF-PROBE-DONE" "$log"; then
    rc=0
    break
  fi
  if grep -qaiE "panic|trap|Segmentation|FATAL|HVF-PROBE-PHASE-END name=.* rc=[1-9]" "$log"; then
    rc=1
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
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

grep -aE "smp =|cpu_count=|HVF-PROBE-(RUN-BEGIN|PHASE-END|DONE)" "$log" || true
exit "$rc"
