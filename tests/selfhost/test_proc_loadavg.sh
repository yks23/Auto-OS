#!/bin/sh
set -e
x=$(cat /proc/loadavg)
n=$(echo "$x" | wc -w)
if [ "$n" -ne 5 ]; then
  echo "[TEST] proc_loadavg FAIL: expected 5 whitespace fields, got $n: '$x'"
  exit 1
fi
echo "[TEST] proc_loadavg PASS"
