#!/bin/sh
set -e
if ! grep -q "^processor" /proc/cpuinfo 2>/dev/null; then
  echo "[TEST] proc_cpuinfo FAIL: no processor line in /proc/cpuinfo"
  exit 1
fi
echo "[TEST] proc_cpuinfo PASS"
