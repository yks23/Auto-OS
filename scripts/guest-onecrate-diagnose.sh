#!/usr/bin/env bash
# 从串口 results.txt 生成可读诊断块（默认 stderr + diagnosis.txt）。始终 exit 0，不拖累调用方 set -e。
# 用法: guest-onecrate-diagnose.sh [--quiet-stderr] <results.txt>
# 环境: GUEST_ONECRATE_RESULTS 可作为唯一参数缺省时的路径（与 evidence 一致）。
set -uo pipefail

QUIET_STDERR=0
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    --quiet-stderr) QUIET_STDERR=1 ;;
    *) break ;;
  esac
  shift
done

RESULT="${1:-${GUEST_ONECRATE_RESULTS:-}}"
if [[ -z "$RESULT" ]]; then
  echo "guest-onecrate-diagnose.sh: missing results path (arg or GUEST_ONECRATE_RESULTS)" >&2
  exit 0
fi

RESULTS_DIR="$(dirname "$RESULT")"
mkdir -p "$RESULTS_DIR" 2>/dev/null || true
OUT="${RESULTS_DIR}/diagnosis.txt"
PAT='error:|panic:|Compiling |Finished |cargo check|CHECK_RC|stack smashing|SIG|timeout|terminating|ONECRATE_SYSCALL_5S|ONECRATE_SYSCALL_STATS|SYSCALL_STATS'

emit() {
  echo "===GUEST_ONECRATE_DIAGNOSIS==="
  echo "results_path: $RESULT"
  if [[ ! -e "$RESULT" ]]; then
    echo "file: (missing)"
    echo "===GUEST_ONECRATE_DIAGNOSIS_END==="
    return 0
  fi
  _sz="$(wc -c <"$RESULT" 2>/dev/null | tr -d ' ')" || _sz="?"
  _lines="$(wc -l <"$RESULT" 2>/dev/null | tr -d ' ')" || _lines="?"
  echo "file_bytes: ${_sz}"
  echo "file_lines: ${_lines}"
  echo "--- last_80_lines ---"
  tail -n 80 "$RESULT" 2>/dev/null || echo "(tail failed)"
  echo "--- grep_E (${PAT}) ---"
  grep -a -E -n "$PAT" "$RESULT" 2>/dev/null | tail -n 200 || echo "(no matches or grep failed)"
  echo "--- strings_last40 (optional) ---"
  if command -v strings >/dev/null 2>&1; then
    strings "$RESULT" 2>/dev/null | tail -n 40 || echo "(strings failed)"
  else
    echo "(strings not available)"
  fi
  echo "===GUEST_ONECRATE_DIAGNOSIS_END==="
}

if [[ "$QUIET_STDERR" -eq 1 ]]; then
  emit >"$OUT"
else
  emit | tee "$OUT" >&2
fi
exit 0
