#!/usr/bin/env bash
set -euo pipefail
cd "/Users/txc/code/Auto-OS"
echo "===TERMINAL-BUILD stamp=20260530T162953==="
echo "log=/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/hvf-aarch64-starryos-smp8-j8-wakelocal-minfeatures-hostcpu1s-opt0-cgu256-20260530T162953.log"
echo "source_tmpfs=1"
SOURCE_TMPFS="1" STAMP="20260530T162953" CASE_NAME="smp8-j8-wakelocal-minfeatures-hostcpu1s-opt0-cgu256" \
  bash "/Users/txc/code/Auto-OS/过程记录/最终材料/scripts/run-hvf-starryos-smp8-hostcpu-second.sh"
echo "===TERMINAL-BUILD-DONE stamp=20260530T162953 rc=$?==="
