#!/usr/bin/env bash
# QEMU 内 Starry 访客：syscall 采样 + 受控编译（见 scripts/guest-onecrate-inner.sh）。
# 限时：QEMU 外层 timeout（默认 7200s）；宿主 orchestrator 另包一层。
# HTTP 侧车（可选）：GUEST_ONECRATE_STATS_HTTP=1 或 STARRY_SMOKE_STATS_HTTP=1 时，在 QEMU 前启动
#   python3 scripts/starry-smoke-syscall-http.py，STARRY_SMOKE_LOG 指向本脚本写入的串口文件（与 tail 监控同一路径）；
#   默认监听 127.0.0.1:1378（STARRY_SMOKE_STATS_BIND / STARRY_SMOKE_STATS_PORT 可改）。
#
# 控制变量（无网络）：
#   GUEST_ONECRATE_ALLOW_FETCH=0（默认）— 不跑 cargo fetch；须 rootfs 内 CARGO_HOME 已具备离线依赖。
#   GUEST_ONECRATE_MODE=rustc — 最简：rustc 将 /opt/tiny/hello.rs 编译为 object（--emit=obj），无 cargo、无 registry、不跑访客链接器。
#   GUEST_ONECRATE_MODE=cargo — cargo check -p … --offline（默认，与宿主 onecrate 对齐时显式传入）。
#   GUEST_ONECRATE_RESULTS / GUEST_ONECRATE_OUT_DIR / GUEST_ONECRATE_SUMMARY — 串口日志与 summary 路径（可选）。
#   GUEST_ONECRATE_PROGRESS_SEC — 传给访客 inner：cargo 运行中心跳秒数（默认 300，0=关闭）。
#   GUEST_ONECRATE_SYSCALL_STATS_SEC — inner 内严格定间隔（先 sleep 满周期）dump + ===ONECRATE_SYSCALL_5S=== 行（默认 5；0=关闭）。
#   GUEST_ONECRATE_DEVLOG_SEC — cargo 时每隔该秒数用 logger 发最后一行 cargo 输出到 /dev/log（见 starry-userspace-log）；默认 15；0=关闭。
#   GUEST_ONECRATE_TAIL_HTTP — 默认 1：QEMU 前起 tail-http-serve.py，浏览器看串口 results.txt（GUEST_ONECRATE_TAIL_HTTP_PORT 默认 13888）；0=关闭。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  exec docker run --rm --privileged --network host \
    -v "${REPO}:/work" -w /work \
    -e "GUEST_ONECRATE_ROOTFS=${GUEST_ONECRATE_ROOTFS:-}" \
    -e "GUEST_ONECRATE_TIMEOUT=${GUEST_ONECRATE_TIMEOUT:-}" \
    -e "GUEST_ONECRATE_SKIP_KERNEL_SAVE=${GUEST_ONECRATE_SKIP_KERNEL_SAVE:-}" \
    -e "GUEST_ONECRATE_CRATE=${GUEST_ONECRATE_CRATE:-}" \
    -e "GUEST_ONECRATE_TARGET=${GUEST_ONECRATE_TARGET:-}" \
    -e "GUEST_ONECRATE_SAMPLE_SLEEP=${GUEST_ONECRATE_SAMPLE_SLEEP:-}" \
    -e "GUEST_ONECRATE_MODE=${GUEST_ONECRATE_MODE:-cargo}" \
    -e "GUEST_ONECRATE_ALLOW_FETCH=${GUEST_ONECRATE_ALLOW_FETCH:-0}" \
    -e "GUEST_ONECRATE_RESULTS=${GUEST_ONECRATE_RESULTS:-}" \
    -e "GUEST_ONECRATE_OUT_DIR=${GUEST_ONECRATE_OUT_DIR:-}" \
    -e "GUEST_ONECRATE_SUMMARY=${GUEST_ONECRATE_SUMMARY:-}" \
    -e "GUEST_ONECRATE_PROGRESS_SEC=${GUEST_ONECRATE_PROGRESS_SEC:-}" \
    -e "GUEST_ONECRATE_SYSCALL_STATS_SEC=${GUEST_ONECRATE_SYSCALL_STATS_SEC:-}" \
    -e "GUEST_ONECRATE_DEVLOG_SEC=${GUEST_ONECRATE_DEVLOG_SEC:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP=${GUEST_ONECRATE_TAIL_HTTP:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP_PORT=${GUEST_ONECRATE_TAIL_HTTP_PORT:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP_LINES=${GUEST_ONECRATE_TAIL_HTTP_LINES:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP_REFRESH=${GUEST_ONECRATE_TAIL_HTTP_REFRESH:-}" \
    -e "GUEST_ONECRATE_STATS_HTTP=${GUEST_ONECRATE_STATS_HTTP:-}" \
    -e "STARRY_SMOKE_STATS_HTTP=${STARRY_SMOKE_STATS_HTTP:-}" \
    auto-os/starry:latest \
    bash /work/scripts/guest-onecrate-syscall-evidence.sh
fi

cd /work
export PATH="/opt/riscv64-linux-musl-cross/bin:${PATH:-}"

SAVE_DIR="/work/.guest-runs/saved"
KERNEL_SRC="/work/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
KERNEL_SAVE="${SAVE_DIR}/starryos-riscv64.release"
KERNEL_BIN="${SAVE_DIR}/starryos-riscv64.release.bin"
OUT_DIR="${GUEST_ONECRATE_OUT_DIR:-/work/.guest-runs/guest-onecrate-bench}"
mkdir -p "$OUT_DIR"
RESULT="${GUEST_ONECRATE_RESULTS:-${GUEST_ONECRATE_RESULT:-$OUT_DIR/results.txt}}"
mkdir -p "$(dirname "$RESULT")"
RESULTS_DIR="$(dirname "$RESULT")"
SUMMARY="${GUEST_ONECRATE_SUMMARY:-$RESULTS_DIR/summary.txt}"
MNT=/tmp/guest-onecrate-mnt
TO="${GUEST_ONECRATE_TIMEOUT:-7200}"

ROOTFS="${GUEST_ONECRATE_ROOTFS:-}"
if [[ -z "$ROOTFS" ]]; then
  if [[ -f "/work/.guest-runs/riscv64-m6/rootfs-run.img" ]]; then
    ROOTFS="/work/.guest-runs/riscv64-m6/rootfs-run.img"
  else
    ROOTFS="/work/tests/selfhost/rootfs-selfbuild-riscv64.img"
  fi
fi

[[ -f "$KERNEL_SRC" ]] || { echo "missing kernel ELF: $KERNEL_SRC"; exit 1; }
[[ -f "$ROOTFS" ]] || { echo "missing rootfs: $ROOTFS"; exit 1; }
[[ -f "/work/scripts/guest-onecrate-inner.sh" ]] || { echo "missing /work/scripts/guest-onecrate-inner.sh"; exit 1; }

mkdir -p "$SAVE_DIR" "$RESULTS_DIR"
if [[ "${GUEST_ONECRATE_SKIP_KERNEL_SAVE:-0}" != "1" ]]; then
  cp -f "$KERNEL_SRC" "$KERNEL_SAVE"
  sha256sum "$KERNEL_SAVE" >"${KERNEL_SAVE}.sha256"
fi
riscv64-linux-musl-objcopy -O binary "$KERNEL_SAVE" "$KERNEL_BIN"

umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
mount -o loop,rw "$ROOTFS" "$MNT"

CRATE="${GUEST_ONECRATE_CRATE:-ax-errno}"
TARGET="${GUEST_ONECRATE_TARGET:-riscv64gc-unknown-none-elf}"
SLEEP="${GUEST_ONECRATE_SAMPLE_SLEEP:-0.5}"
# 默认 cargo（与旧行为一致）；受控最简：GUEST_ONECRATE_MODE=rustc GUEST_ONECRATE_ALLOW_FETCH=0
ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH:-0}"
# `set -u` 下，未引用的 heredoc 展开若出现未赋值名（例如误写 ${MODE}）会直接失败；此处先 export 默认值，heredoc 只引用已定义名。
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE:-cargo}"
export GUEST_ONECRATE_ALLOW_FETCH="${ALLOW_FETCH}"
export GUEST_ONECRATE_PROGRESS_SEC="${GUEST_ONECRATE_PROGRESS_SEC:-300}"
export GUEST_ONECRATE_SYSCALL_STATS_SEC="${GUEST_ONECRATE_SYSCALL_STATS_SEC:-5}"
export GUEST_ONECRATE_DEVLOG_SEC="${GUEST_ONECRATE_DEVLOG_SEC:-15}"

mkdir -p "${MNT}/opt/tiny"
# rustc 最简受控路径（无 cargo、无网络）；cargo 模式时亦存在，无害。
cat >"${MNT}/opt/tiny/hello.rs" <<'HELLO'
fn main() {}
HELLO

tee "${MNT}/opt/run-tests.sh" >/dev/null <<EOF
#!/bin/sh
export GUEST_ONECRATE_CRATE="${CRATE}"
export GUEST_ONECRATE_TARGET="${TARGET}"
export GUEST_ONECRATE_SAMPLE_SLEEP="${SLEEP}"
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE}"
export GUEST_ONECRATE_ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH}"
export GUEST_ONECRATE_PROGRESS_SEC="${GUEST_ONECRATE_PROGRESS_SEC}"
export GUEST_ONECRATE_SYSCALL_STATS_SEC="${GUEST_ONECRATE_SYSCALL_STATS_SEC}"
export GUEST_ONECRATE_DEVLOG_SEC="${GUEST_ONECRATE_DEVLOG_SEC}"
exec /bin/bash --noprofile --norc /opt/guest-onecrate-inner.sh
EOF
chmod +x "${MNT}/opt/run-tests.sh"
cp -f "/work/scripts/guest-onecrate-inner.sh" "${MNT}/opt/guest-onecrate-inner.sh"
chmod +x "${MNT}/opt/guest-onecrate-inner.sh"

umount "$MNT" || { echo "umount failed"; exit 1; }

GUEST_ONECRATE_HTTP_PID=""
GUEST_ONECRATE_TAIL_HTTP_PID=""
_onecrate_cleanup_sidecars() {
  if [[ -n "${GUEST_ONECRATE_HTTP_PID:-}" ]]; then
    kill "${GUEST_ONECRATE_HTTP_PID}" 2>/dev/null || true
    wait "${GUEST_ONECRATE_HTTP_PID}" 2>/dev/null || true
    GUEST_ONECRATE_HTTP_PID=""
  fi
  if [[ -n "${GUEST_ONECRATE_TAIL_HTTP_PID:-}" ]]; then
    kill "${GUEST_ONECRATE_TAIL_HTTP_PID}" 2>/dev/null || true
    wait "${GUEST_ONECRATE_TAIL_HTTP_PID}" 2>/dev/null || true
    GUEST_ONECRATE_TAIL_HTTP_PID=""
  fi
}
trap _onecrate_cleanup_sidecars EXIT

echo "[+] QEMU timeout=${TO}s -> $RESULT"
rm -f "$RESULT" "$SUMMARY"
: >"$RESULT"

_tail_gui="${GUEST_ONECRATE_TAIL_HTTP:-1}"
if [[ "${_tail_gui}" == "1" ]]; then
  _tp="${GUEST_ONECRATE_TAIL_HTTP_PORT:-13888}"
  _tl="${GUEST_ONECRATE_TAIL_HTTP_LINES:-200}"
  _tr="${GUEST_ONECRATE_TAIL_HTTP_REFRESH:-3}"
  python3 "${SCRIPT_DIR}/tail-http-serve.py" "$RESULT" "$_tp" "$_tl" "$_tr" &
  GUEST_ONECRATE_TAIL_HTTP_PID=$!
  echo "[+] tail GUI pid=${GUEST_ONECRATE_TAIL_HTTP_PID} http://127.0.0.1:${_tp}/ (raw: /raw) file=${RESULT}" >&2
fi

_stats_http="${GUEST_ONECRATE_STATS_HTTP:-${STARRY_SMOKE_STATS_HTTP:-0}}"
if [[ "${_stats_http}" == "1" ]]; then
  export STARRY_SMOKE_LOG="$RESULT"
  export M6_SYSCALL_STATS_INTERVAL_SEC="${GUEST_ONECRATE_SYSCALL_STATS_SEC:-5}"
  python3 "${SCRIPT_DIR}/starry-smoke-syscall-http.py" &
  GUEST_ONECRATE_HTTP_PID=$!
  echo "[+] syscall stats HTTP sidecar pid=${GUEST_ONECRATE_HTTP_PID} STARRY_SMOKE_LOG=${RESULT} (default http://127.0.0.1:1378/)" >&2
fi

set +e
timeout "$TO" qemu-system-riscv64 \
  -nographic -machine virt -bios default -smp 4 -m 5G \
  -kernel "$KERNEL_BIN" -cpu rv64 \
  -monitor none -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file="$ROOTFS",file.locking=off \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  >"$RESULT" 2>&1 </dev/null
Q_RC=$?
set -e

export GUEST_ONECRATE_RESULT="$RESULT"
export GUEST_ONECRATE_Q_RC="$Q_RC"
set +e
if [[ "$Q_RC" -ne 0 ]] || [[ ! -s "$RESULT" ]] || ! grep -a -q '===GUEST_ONECRATE_CHECK_RC 0===' "$RESULT" 2>/dev/null; then
  bash "${SCRIPT_DIR}/guest-onecrate-diagnose.sh" "$RESULT" || true
else
  bash "${SCRIPT_DIR}/guest-onecrate-diagnose.sh" --quiet-stderr "$RESULT" || true
fi
set -e

python3 - <<'PY' | tee "$SUMMARY"
import os, re
from pathlib import Path

def last_line_matching(text, pat):
    for line in reversed(text.splitlines()):
        if re.search(pat, line):
            return line.strip()[:800]
    return ""

def tail_hint_best_effort(text):
    hints = []
    specs = [
        ("timeout", re.compile(r"timeout|timed out|terminating", re.I)),
        ("panic", re.compile(r"panic", re.I)),
        ("sig", re.compile(r"\bSIG[A-Z0-9]+\b|signal", re.I)),
        ("stack", re.compile(r"stack smashing", re.I)),
        ("error", re.compile(r"error(\[|:)", re.I)),
        ("finished", re.compile(r"\bFinished\b", re.I)),
    ]
    for label, cre in specs:
        if not cre.search(text):
            continue
        for line in reversed(text.splitlines()):
            if cre.search(line):
                hints.append(f"{label}:{line.strip()[:200]}")
                break
    return " | ".join(hints) if hints else "(no strong hints)"

p = Path(os.environ["GUEST_ONECRATE_RESULT"])
raw = p.read_bytes().decode("utf-8", errors="replace") if p.is_file() else ""
rc = m.group(1) if (m := re.search(r"===GUEST_ONECRATE_CHECK_RC (\d+)===" , raw)) else "?"
el = m.group(1) if (m := re.search(r"===GUEST_ONECRATE_ELAPSED_S (\d+)===" , raw)) else "?"
blk = re.search(r"===SYSCALL_STATS_AFTER_BEGIN===\s*\n(total \d+)", raw, re.M)
total_line = blk.group(1) if blk else "?"
ok = blk is not None and rc == "0"
has_marker = bool(re.search(r"===GUEST_ONECRATE_CHECK_RC \d+===", raw))
last_c = last_line_matching(raw, r"Compiling ")
last_e = last_line_matching(raw, r"error(\[|:)")
if not last_e:
    last_e = last_line_matching(raw, r"^error:")
print("=== guest_onecrate_syscall_evidence ===")
print("ok:", ok)
print("cargo_check_rc:", rc)
print("elapsed_s:", el)
print("syscall_stats_first_line:", total_line)
print("serial_log:", str(p))
print("qemu_outer_exit:", os.environ.get("GUEST_ONECRATE_Q_RC", "?"))
print("last_compiling_line:", last_c or "(none)")
print("last_error_line:", last_e or "(none)")
print("has_check_rc_marker:", has_marker)
print("tail_hint:", tail_hint_best_effort(raw))
PY

if [[ "$Q_RC" -eq 124 ]]; then
  echo "[+] qemu outer exit=$Q_RC (timeout(1) killed QEMU)"
else
  echo "[+] qemu outer exit=$Q_RC"
fi

# 供宿主/CI 判断：必须在本轮串口里看到 rustc/cargo 成功标记（禁止仅靠旧 results.txt 冒充通过）。
if [[ ! -s "$RESULT" ]]; then
  echo "[!] serial log empty: $RESULT"
  exit 1
fi
if ! grep -a -q '===GUEST_ONECRATE_CHECK_RC 0===' "$RESULT"; then
  echo "[!] missing ===GUEST_ONECRATE_CHECK_RC 0=== in $RESULT (qemu_exit=$Q_RC)"
  exit 1
fi
