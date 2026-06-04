#!/usr/bin/env bash
set -euo pipefail

pid="${1:?usage: monitor-qemu-top-cpu.sh QEMU_PID OUT_CSV [INTERVAL_SEC]}"
out="${2:?usage: monitor-qemu-top-cpu.sh QEMU_PID OUT_CSV [INTERVAL_SEC]}"
interval="${3:-1}"

mkdir -p "$(dirname "$out")"
printf 'epoch,pid,host_cpu_pct,rss_kb,vsz_kb,cpu_time,elapsed_time,mem,command\n' >"$out"

while kill -0 "$pid" 2>/dev/null; do
  line="$(
    top -l 2 -s "$interval" -pid "$pid" -stats pid,cpu,time,mem,command 2>/dev/null |
      awk -v pid="$pid" '$1 == pid { row = $0 } END { print row }'
  )"
  now="$(date +%s)"
  if [ -n "$line" ]; then
    set -- $line
    sample_pid="$1"
    cpu_pct="$2"
    cpu_time="$3"
    mem="$4"
    shift 4
    command="$*"
    printf '%s,%s,%s,,,%s,,%s,%s\n' "$now" "$sample_pid" "$cpu_pct" "$cpu_time" "$mem" "$command" >>"$out"
  else
    printf '%s,%s,,,,,,,\n' "$now" "$pid" >>"$out"
  fi
done
