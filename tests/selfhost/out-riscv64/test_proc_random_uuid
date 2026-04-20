#!/bin/sh
set -e
p=/proc/sys/kernel/random/uuid
a=$(tr -d '\n' < "$p")
b=$(tr -d '\n' < "$p")
if ! echo "$a" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "[TEST] proc_random_uuid FAIL: bad v4-like hex format a='$a'"
  exit 1
fi
if ! echo "$b" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "[TEST] proc_random_uuid FAIL: bad v4-like hex format b='$b'"
  exit 1
fi
if [ "$a" = "$b" ]; then
  echo "[TEST] proc_random_uuid FAIL: two reads returned identical value"
  exit 1
fi
echo "[TEST] proc_random_uuid PASS"
