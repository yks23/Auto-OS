#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out_dir="${OUT_DIR:-$root/过程记录/最终材料/final/cpu-util}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
case_name="${CASE_NAME:-smp8-j8-wakelocal-minfeatures-hostcpu1s-opt0-cgu256}"
source_tmpfs="${SOURCE_TMPFS:-1}"

mkdir -p "$out_dir"

build_script="$out_dir/terminal-build-$stamp.sh"
top_script="$out_dir/terminal-top-$stamp.sh"
run_log="$out_dir/hvf-aarch64-starryos-${case_name}-${stamp}.log"
top_csv="$out_dir/qemu-top-smp8-j8-$stamp.csv"
top_prefix="$out_dir/smp8-j8-topcpu-$stamp"

cat >"$build_script" <<EOF_BUILD
#!/usr/bin/env bash
set -euo pipefail
cd "$root"
echo "===TERMINAL-BUILD stamp=$stamp==="
echo "log=$run_log"
echo "source_tmpfs=$source_tmpfs"
SOURCE_TMPFS="$source_tmpfs" STAMP="$stamp" CASE_NAME="$case_name" \\
  bash "$root/过程记录/最终材料/scripts/run-hvf-starryos-smp8-hostcpu-second.sh"
echo "===TERMINAL-BUILD-DONE stamp=$stamp rc=\$?==="
EOF_BUILD
chmod +x "$build_script"

cat >"$top_script" <<EOF_TOP
#!/usr/bin/env bash
set -euo pipefail
cd "$root"
echo "===TERMINAL-TOP stamp=$stamp==="
echo "waiting for qemu-system-aarch64 ..."
pid=""
for _ in \$(seq 1 600); do
  pid="\$(pgrep -n -f 'qemu-system-aarch64.*starryos-hvf-smp8-hvfopt-wake-local' || true)"
  if [ -n "\$pid" ]; then
    break
  fi
  sleep 1
done
if [ -z "\$pid" ]; then
  echo "ERROR: QEMU pid not found" >&2
  exit 2
fi
echo "qemu_pid=\$pid"
echo "top_csv=$top_csv"
bash "$root/过程记录/最终材料/scripts/monitor-qemu-top-cpu.sh" "\$pid" "$top_csv" 1
echo "qemu exited; parsing top CSV"
python3 "$root/过程记录/最终材料/scripts/extract-hvf-host-cpu-util.py" \\
  --log "$run_log" \\
  --host-cpu-csv "$top_csv" \\
  --smp 8 \\
  --out-prefix "$top_prefix"
echo "===TERMINAL-TOP-DONE stamp=$stamp==="
EOF_TOP
chmod +x "$top_script"

osascript <<EOF_OSA
tell application "Terminal"
  activate
  do script "bash '$build_script'"
  delay 2
  do script "bash '$top_script'"
end tell
EOF_OSA

cat <<EOF_OUT
stamp=$stamp
build_script=$build_script
top_script=$top_script
run_log=$run_log
top_csv=$top_csv
top_prefix=$top_prefix
EOF_OUT
