#!/usr/bin/env bash
set -euo pipefail
cd "/Users/txc/code/Auto-OS"
echo "===TERMINAL-TOP stamp=20260530T162953==="
echo "waiting for qemu-system-aarch64 ..."
pid=""
for _ in $(seq 1 600); do
  pid="$(pgrep -n -f 'qemu-system-aarch64.*starryos-hvf-smp8-hvfopt-wake-local' || true)"
  if [ -n "$pid" ]; then
    break
  fi
  sleep 1
done
if [ -z "$pid" ]; then
  echo "ERROR: QEMU pid not found" >&2
  exit 2
fi
echo "qemu_pid=$pid"
echo "top_csv=/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/qemu-top-smp8-j8-20260530T162953.csv"
bash "/Users/txc/code/Auto-OS/showtime-2/scripts/monitor-qemu-top-cpu.sh" "$pid" "/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/qemu-top-smp8-j8-20260530T162953.csv" 1
echo "qemu exited; parsing top CSV"
python3 "/Users/txc/code/Auto-OS/showtime-2/scripts/extract-hvf-host-cpu-util.py" \
  --log "/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/hvf-aarch64-starryos-smp8-j8-wakelocal-minfeatures-hostcpu1s-opt0-cgu256-20260530T162953.log" \
  --host-cpu-csv "/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/qemu-top-smp8-j8-20260530T162953.csv" \
  --smp 8 \
  --out-prefix "/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-topcpu-20260530T162953"
echo "===TERMINAL-TOP-DONE stamp=20260530T162953==="
