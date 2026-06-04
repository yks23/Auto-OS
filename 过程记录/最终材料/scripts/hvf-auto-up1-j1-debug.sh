#!/bin/sh
set -u
export CARGO_BUILD_JOBS=1
export RAYON_NUM_THREADS=1
export TMPDIR=/tmp
export CARGO_TARGET_DIR=/tmp/target-hvf-up1-j1-debug-20260523T160000
echo "===HVF-UP1-J1-DEBUG-TMP-RUN-BEGIN==="
/opt/build-starryos-hvf-debug.sh
rc=$?
echo "===HVF-UP1-J1-DEBUG-TMP-RUN-END rc=$rc==="
exit "$rc"
