#!/bin/sh
set -e
f=/proc/meminfo
for key in MemTotal MemFree MemAvailable; do
  if ! grep -q "^${key}:" "$f" 2>/dev/null; then
    echo "[TEST] proc_meminfo FAIL: missing ${key} in /proc/meminfo"
    exit 1
  fi
done
echo "[TEST] proc_meminfo PASS"
