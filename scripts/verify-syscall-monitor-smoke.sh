#!/usr/bin/env bash
# Smoke-test (宿主仅): 验证 m6-selfbuild-progress-http.py 对串口块的解析与 /api/syscall_series。
#
# **重要**：本脚本写入的是**完全伪造**的 SYSCALL_STATS 文本，**不运行 Starry 访客、不运行 cargo**。
# 用户要的「真实」syscall 动态必须在 **QEMU 内 Starry 访客** 串口里出现由内核 /proc/syscall_stats
# 打出的块；不得以本脚本的数字当作访客编译结果。
#
# Python 对每个块用各 `nr count` 行之和作为 total；块内 `total N` 行会被解析器跳过。
#
# 真机前置：访客内核须暴露 /proc/syscall_stats（新编 starryos）；可选 strings … | grep syscall_stats。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TMP="$(mktemp -d)"

LOG_FILE="$TMP/m6-fake-serial.log"
# Three snapshots: totals 100 -> 2500 -> 9000 via nr/count sums (monotonic).
cat >"$LOG_FILE" <<'EOF'
noise before blocks
===SYSCALL_STATS_BEGIN===
total 100
0 60
1 40
===SYSCALL_STATS_END===
===SYSCALL_STATS_BEGIN===
total 2500
0 2000
1 500
===SYSCALL_STATS_END===
===SYSCALL_STATS_BEGIN===
total 9000
1 5000
2 4000
===SYSCALL_STATS_END===
EOF

pick_free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
}

PORT="$(pick_free_port)"
export M6_PROGRESS_LOG="$LOG_FILE"
export M6_PROGRESS_BIND="127.0.0.1"
export M6_PROGRESS_PORT="$PORT"

HTTP_PID=""
cleanup() {
  if [[ -n "${HTTP_PID}" ]] && kill -0 "${HTTP_PID}" 2>/dev/null; then
    kill "${HTTP_PID}" 2>/dev/null || true
    wait "${HTTP_PID}" 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

python3 "$REPO_ROOT/scripts/m6-selfbuild-progress-http.py" &
HTTP_PID=$!

sleep 1

JSON="$(curl -sSf "http://127.0.0.1:${PORT}/api/syscall_series")"
export JSON_PAYLOAD="$JSON"

python3 -c '
import json, os, sys
d = json.loads(os.environ["JSON_PAYLOAD"])
series = d.get("series") or []
if len(series) < 3:
    print("verify-syscall-monitor-smoke: expected series len >= 3, got", len(series), file=sys.stderr)
    sys.exit(1)
t0 = float(series[0]["total"])
t1 = float(series[-1]["total"])
if not (t1 > t0):
    print("verify-syscall-monitor-smoke: expected series[-1].total > series[0].total:", t0, t1, file=sys.stderr)
    sys.exit(1)
if "stall_hint" not in d:
    print("verify-syscall-monitor-smoke: missing stall_hint in payload", file=sys.stderr)
    sys.exit(1)
print("verify-syscall-monitor-smoke: ok (snapshots=", len(series), ", first_total=", int(t0), ", last_total=", int(t1), ", stall_hint=", d.get("stall_hint"), ")", sep="")
'
