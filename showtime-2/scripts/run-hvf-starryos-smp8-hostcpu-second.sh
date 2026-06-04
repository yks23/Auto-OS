#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out_dir="${OUT_DIR:-$root/showtime-2/final/cpu-util}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
case_name="${CASE_NAME:-smp8-j8-wakelocal-minfeatures-hostcpu1s-opt0-cgu256}"
source_tmpfs="${SOURCE_TMPFS:-1}"
log="$out_dir/hvf-aarch64-starryos-${case_name}-${stamp}.log"
host_cpu_csv="$out_dir/hvf-aarch64-starryos-${case_name}-${stamp}.hostcpu.csv"
out_prefix="$out_dir/smp8-j8-hostcpu1s-${stamp}"

mkdir -p "$out_dir"

helper="$root/showtime-2/scripts/run-hvf-starryos-guest-build.sh"
extractor="$root/showtime-2/scripts/extract-hvf-host-cpu-util.py"
kernel="${KERNEL:-$root/.guest-runs/aarch64-hvf/starryos-hvf-smp8-hvfopt-wake-local-20260524.bin}"
img="${IMG:-$root/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"

PROFILE=release \
SMP=8 \
JOBS=8 \
MEM="${MEM:-4096M}" \
KERNEL="$kernel" \
IMG="$img" \
LOG_DIR="$out_dir" \
LOG="$log" \
CASE_NAME="$case_name" \
SOURCE_TMPFS="$source_tmpfs" \
FAST_ALLOC_SLAB_ONLY=1 \
FEATURES="ax-feat/defplat,ax-feat/irq,ax-feat/rtc,ax-feat/bus-pci,gic-v3,cntv-timer,smp" \
CARGO_PROFILE_RELEASE_LTO=false \
CARGO_PROFILE_RELEASE_OPT_LEVEL=0 \
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256 \
TIMESTAMP_CARGO=1 \
CARGO_MESSAGE_FORMAT=json \
GUEST_CPU_MONITOR=0 \
HOST_CPU_MONITOR=1 \
HOST_CPU_MONITOR_INTERVAL=1 \
HOST_CPU_CSV="$host_cpu_csv" \
HOST_HEARTBEAT_INTERVAL=10 \
"$helper"

python3 "$extractor" \
  --log "$log" \
  --host-cpu-csv "$host_cpu_csv" \
  --smp 8 \
  --out-prefix "$out_prefix"
