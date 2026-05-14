#!/usr/bin/env bash
# guest-macos-native.inc.sh — macOS native QEMU guest run.
#
# Sourced by guest-onecrate-syscall-evidence.sh when running on macOS
# (GUEST_ONECRATE_MACOS_NATIVE=1). Replaces the Docker-based pipeline
# with native macOS operations:
#   - kernel binary via rust-objcopy / llvm-objcopy (not riscv64-linux-musl-objcopy)
#   - rootfs mount/inject via a one-shot Docker container
#   - QEMU via Homebrew qemu-system-riscv64
#
# This file is sourced, not executed directly. It expects the caller to
# have set: SCRIPT_DIR, REPO, and all GUEST_ONECRATE_* environment variables.

echo "[macos-native] running QEMU guest natively on macOS"

# ── Resolve paths (mirrors the Docker path logic) ────────────────
SAVE_DIR="${REPO}/.guest-runs/saved"
KERNEL_SRC="${REPO}/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
KERNEL_SAVE="${SAVE_DIR}/starryos-riscv64.release"
KERNEL_BIN="${SAVE_DIR}/starryos-riscv64.release.bin"
OUT_DIR="${GUEST_ONECRATE_OUT_DIR:-${REPO}/.guest-runs/guest-onecrate-bench}"
mkdir -p "$OUT_DIR"
RESULT="${GUEST_ONECRATE_RESULTS:-${GUEST_ONECRATE_RESULT:-$OUT_DIR/results.txt}}"
mkdir -p "$(dirname "$RESULT")"
RESULTS_DIR="$(dirname "$RESULT")"
SUMMARY="${GUEST_ONECRATE_SUMMARY:-$RESULTS_DIR/summary.txt}"
TO="${GUEST_ONECRATE_TIMEOUT:-7200}"

ROOTFS="${GUEST_ONECRATE_ROOTFS:-}"
if [[ -z "$ROOTFS" ]]; then
  if [[ -f "${REPO}/.guest-runs/riscv64-m6/rootfs-run.img" ]]; then
    ROOTFS="${REPO}/.guest-runs/riscv64-m6/rootfs-run.img"
  elif [[ -f "${REPO}/.guest-runs/rootfs-selfbuild-riscv64.img" ]]; then
    ROOTFS="${REPO}/.guest-runs/rootfs-selfbuild-riscv64.img"
  elif [[ -f "${REPO}/tests/selfhost/rootfs-selfbuild-riscv64.img" ]]; then
    ROOTFS="${REPO}/tests/selfhost/rootfs-selfbuild-riscv64.img"
  else
    echo "error: no rootfs image found. Set GUEST_ONECRATE_ROOTFS." >&2
    exit 1
  fi
fi

if [[ "${GUEST_ONECRATE_DISPOSABLE_ROOTFS:-0}" == "1" ]]; then
  mkdir -p "$OUT_DIR"
  BASE_ROOTFS="$ROOTFS"
  ROOTFS="$OUT_DIR/rootfs.img"
  if [[ "$BASE_ROOTFS" != "$ROOTFS" ]]; then
    cp -f "$BASE_ROOTFS" "$ROOTFS"
  fi
  echo "[macos-native] disposable rootfs: $BASE_ROOTFS -> $ROOTFS"
fi

[[ -f "$KERNEL_SRC" ]] || { echo "missing kernel ELF: $KERNEL_SRC"; exit 1; }
[[ -f "$ROOTFS" ]] || { echo "missing rootfs: $ROOTFS"; exit 1; }
[[ -f "${SCRIPT_DIR}/guest-onecrate-inner.sh" ]] || { echo "missing ${SCRIPT_DIR}/guest-onecrate-inner.sh"; exit 1; }

# ── Resolve objcopy ──────────────────────────────────────────────
# macOS doesn't have riscv64-linux-musl-objcopy; use rust-objcopy or
# llvm-objcopy from the Rust toolchain.
OBJCOPY=""
if command -v rust-objcopy >/dev/null 2>&1; then
  OBJCOPY=rust-objcopy
elif [[ -n "$(rustc --print sysroot 2>/dev/null)" ]]; then
  _sysroot="$(rustc --print sysroot)"
  _host="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
  if [[ -n "$_host" && -f "${_sysroot}/lib/rustlib/${_host}/bin/llvm-objcopy" ]]; then
    OBJCOPY="${_sysroot}/lib/rustlib/${_host}/bin/llvm-objcopy"
  fi
fi
if [[ -z "$OBJCOPY" ]]; then
  echo "error: need objcopy. Install cargo-binutils: cargo install cargo-binutils" >&2
  exit 1
fi
echo "[macos-native] objcopy: ${OBJCOPY}"

# ── Prepare kernel binary ────────────────────────────────────────
mkdir -p "$SAVE_DIR" "$RESULTS_DIR"
if [[ "${GUEST_ONECRATE_SKIP_KERNEL_SAVE:-0}" != "1" ]]; then
  cp -f "$KERNEL_SRC" "$KERNEL_SAVE"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$KERNEL_SAVE" > "${KERNEL_SAVE}.sha256"
  fi
fi
"$OBJCOPY" -I elf64-littleriscv -O binary "$KERNEL_SAVE" "$KERNEL_BIN"

# ── Environment defaults (mirrors the Docker path) ───────────────
CRATE="${GUEST_ONECRATE_CRATE:-ax-errno}"
TARGET="${GUEST_ONECRATE_TARGET:-riscv64gc-unknown-none-elf}"
SLEEP="${GUEST_ONECRATE_SAMPLE_SLEEP:-0.5}"
ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH:-0}"
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE:-cargo}"
if [[ -z "${GUEST_ONECRATE_CARGO_PHASE:-}" ]]; then
  if [[ "${GUEST_ONECRATE_MODE}" == "cargo-hello" ]]; then
    export GUEST_ONECRATE_CARGO_PHASE="metadata"
  else
    export GUEST_ONECRATE_CARGO_PHASE="check"
  fi
else
  export GUEST_ONECRATE_CARGO_PHASE
fi
export GUEST_ONECRATE_CARGO_TRACE="${GUEST_ONECRATE_CARGO_TRACE:-0}"
export GUEST_ONECRATE_CARGO_VERBOSE="${GUEST_ONECRATE_CARGO_VERBOSE:-0}"
export GUEST_ONECRATE_ALLOW_FETCH="${ALLOW_FETCH}"
export GUEST_ONECRATE_PROGRESS_SEC="${GUEST_ONECRATE_PROGRESS_SEC:-300}"
export GUEST_ONECRATE_SYSCALL_STATS_SEC="${GUEST_ONECRATE_SYSCALL_STATS_SEC:-5}"
export GUEST_ONECRATE_SKIP_STATS_RESET="${GUEST_ONECRATE_SKIP_STATS_RESET:-0}"
export GUEST_ONECRATE_SYSCALL_TRACE="${GUEST_ONECRATE_SYSCALL_TRACE:-0}"
export GUEST_ONECRATE_TRACE_SNAPSHOT_SEC="${GUEST_ONECRATE_TRACE_SNAPSHOT_SEC:-0}"
export GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS="${GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS:-0}"
export GUEST_ONECRATE_DEEP_TRACE_SEC="${GUEST_ONECRATE_DEEP_TRACE_SEC:-0}"
export GUEST_ONECRATE_WAIT_ONLY="${GUEST_ONECRATE_WAIT_ONLY:-0}"
if [[ -z "${GUEST_ONECRATE_DEVLOG_SEC:-}" ]]; then
  if [[ "${GUEST_ONECRATE_MODE}" == "cargo-hello" ]]; then
    export GUEST_ONECRATE_DEVLOG_SEC="0"
  else
    export GUEST_ONECRATE_DEVLOG_SEC="15"
  fi
else
  export GUEST_ONECRATE_DEVLOG_SEC
fi
if [[ -z "${GUEST_ONECRATE_CARGO_TAIL_SEC:-}" ]]; then
  if [[ "${GUEST_ONECRATE_CARGO_PHASE}" == "metadata" ]]; then
    export GUEST_ONECRATE_CARGO_TAIL_SEC="10"
  else
    export GUEST_ONECRATE_CARGO_TAIL_SEC="0"
  fi
else
  export GUEST_ONECRATE_CARGO_TAIL_SEC
fi

# ── Mount/inject step via Docker ─────────────────────────────────
# On macOS, we cannot mount ext4 images natively. Use a one-shot
# Docker container to mount the rootfs and inject scripts.
#
# If GUEST_ONECRATE_SKIP_INJECT=1, skip this step (rootfs already
# has the needed scripts from a previous run).
SKIP_INJECT="${GUEST_ONECRATE_SKIP_INJECT:-0}"

if [[ "$SKIP_INJECT" != "1" ]]; then
  echo "[macos-native] injecting scripts into rootfs via Docker..."
  if ! docker image inspect auto-os/starry:latest >/dev/null 2>&1; then
    echo "[macos-native] WARNING: auto-os/starry:latest not found — skipping inject" >&2
    echo "[macos-native] The rootfs must already have /opt/run-tests.sh" >&2
    SKIP_INJECT=1
  fi
fi

if [[ "$SKIP_INJECT" != "1" ]]; then
  # Build the inject command — this mirrors the mount/inject logic from the
  # Docker path but runs in a one-shot container.
  INJECT_SCRIPT="${REPO}/.guest-runs/.macos-inject-$$.sh"
  MNT="/tmp/guest-onecrate-mnt"

  cat > "$INJECT_SCRIPT" <<'INJECT_HEADER'
#!/bin/bash
set -euo pipefail
MNT="/tmp/guest-onecrate-mnt"
ROOTFS="$1"
mount -o loop,rw "$ROOTFS" "$MNT" || { echo "mount failed"; exit 1; }
INJECT_HEADER

  # ── hello.rs (rustc mode) ──
  cat >> "$INJECT_SCRIPT" <<'HELLO_RS'
mkdir -p "${MNT}/opt/tiny"
cat >"${MNT}/opt/tiny/hello.rs" <<'HELLO'
fn main() {}
HELLO
HELLO_RS

  # ── onecrate-hello crate (cargo-hello mode) ──
  # NOTE: inner heredoc labels must differ from outer label '_INJ_CARGO' to avoid premature termination.
  cat >> "$INJECT_SCRIPT" <<'_INJ_CARGO'
mkdir -p "${MNT}/opt/onecrate-hello/src"
cat >"${MNT}/opt/onecrate-hello/Cargo.toml" <<'_INJ_CARGO_TOML'
[package]
name = "onecrate-hello"
version = "0.1.0"
edition = "2021"

[dependencies]
_INJ_CARGO_TOML
cat >"${MNT}/opt/onecrate-hello/src/main.rs" <<'_INJ_MAIN_RS'
fn main() {
    println!("hello from starry cargo");
}
_INJ_MAIN_RS
_INJ_CARGO

  # ── cargo cache sentinels ──
  cat >> "$INJECT_SCRIPT" <<'_INJ_CACHE'
mkdir -p "${MNT}/opt/tgoskits/.m6-tmp" "${MNT}/opt/tgoskits/m6-cargo-home/registry"
cat >"${MNT}/opt/tgoskits/m6-cargo-home/config.toml" <<'_INJ_CARGO_CFG'
[net]
offline = true

[cache]
auto-clean-frequency = "never"

[build]
jobs = 1
_INJ_CARGO_CFG
: >"${MNT}/opt/tgoskits/m6-cargo-home/.package-cache"
: >"${MNT}/opt/tgoskits/m6-cargo-home/.package-cache-journal"
: >"${MNT}/opt/tgoskits/m6-cargo-home/.global-cache"
: >"${MNT}/opt/tgoskits/m6-cargo-home/.global-cache-journal"
_INJ_CACHE

  # ── probe binary (if needed) ──
  if [[ "${GUEST_ONECRATE_MODE:-}" == "probe" ]]; then
    cat >> "$INJECT_SCRIPT" <<'PROBE_BUILD'
if command -v riscv64-linux-musl-gcc >/dev/null 2>&1 && [ ! -x "${MNT}/opt/fd-pipe-probe" ]; then
  cat >"${MNT}/opt/fd-pipe-probe.c" <<'PROBE_C'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/futex.h>
#include <linux/stat.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifndef __NR_statx
#if defined(__riscv) && __riscv_xlen == 64
#define __NR_statx 291
#endif
#endif
static int fail(const char *what) { printf("PROBE_FAIL %s errno=%d (%s)\n", what, errno, strerror(errno)); return 1; }
static int expect(int cond, const char *what) { if (!cond) { printf("PROBE_FAIL %s\n", what); return 1; } printf("PROBE_OK %s\n", what); return 0; }
int main(void) {
  int rc = 0; int p[2]; char ch = 0;
  if (pipe2(p, O_CLOEXEC | O_NONBLOCK) != 0) return fail("pipe2");
  int fl = fcntl(p[0], F_GETFL); if (fl < 0) return fail("fcntl_getfl_initial");
  rc |= expect((fl & O_NONBLOCK) != 0, "getfl_initial_nonblock");
  if (fcntl(p[0], F_SETFL, fl & ~O_NONBLOCK) != 0) return fail("fcntl_setfl_clear");
  fl = fcntl(p[0], F_GETFL); if (fl < 0) return fail("fcntl_getfl_cleared");
  rc |= expect((fl & O_NONBLOCK) == 0, "setfl_clear_nonblock");
  if (fcntl(p[0], F_SETFL, fl | O_NONBLOCK) != 0) return fail("fcntl_setfl_set");
  errno = 0; ssize_t n = read(p[0], &ch, 1);
  rc |= expect(n < 0 && errno == EAGAIN, "nonblock_empty_read_eagain");
  if (close(p[1]) != 0) return fail("close_writer");
  struct pollfd fds[1] = {{ .fd = p[0], .events = POLLIN, .revents = 0 }};
  int pr = ppoll(fds, 1, NULL, NULL);
  if (pr < 0) return fail("ppoll_hup");
  rc |= expect(pr == 1 && (fds[0].revents & (POLLIN | POLLHUP)) != 0, "ppoll_pipe_hup");
  n = read(p[0], &ch, 1); rc |= expect(n == 0, "pipe_eof_after_writer_close");
  close(p[0]);
  printf("PROBE_DONE rc=%d\n", rc); return rc;
}
PROBE_C
  riscv64-linux-musl-gcc -static -O2 -Wall -Wextra "${MNT}/opt/fd-pipe-probe.c" -o "${MNT}/opt/fd-pipe-probe" 2>/dev/null && chmod +x "${MNT}/opt/fd-pipe-probe" || echo "  warn: probe build failed"
fi
PROBE_BUILD
  fi

  # ── guest-onecrate-env.sh (sourced by init.sh before guest-onecrate-inner.sh) ──
  # The StarryOS init.sh checks for /opt/guest-onecrate-inner.sh and sources
  # /opt/guest-onecrate-env.sh for env vars before exec-ing the inner script.
  # Without this file, the inner script runs with default (cargo) settings.
  cat >> "$INJECT_SCRIPT" <<ENV_SH_EOF
cat > "\${MNT}/opt/guest-onecrate-env.sh" <<'_ENVEOF'
export GUEST_ONECRATE_CRATE="${CRATE}"
export GUEST_ONECRATE_TARGET="${TARGET}"
export GUEST_ONECRATE_SAMPLE_SLEEP="${SLEEP}"
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE}"
export GUEST_ONECRATE_CARGO_PHASE="${GUEST_ONECRATE_CARGO_PHASE}"
export GUEST_ONECRATE_CARGO_TRACE="${GUEST_ONECRATE_CARGO_TRACE}"
export GUEST_ONECRATE_CARGO_VERBOSE="${GUEST_ONECRATE_CARGO_VERBOSE}"
export GUEST_ONECRATE_ALLOW_FETCH="${ALLOW_FETCH}"
export GUEST_ONECRATE_RUSTFLAGS="${GUEST_ONECRATE_RUSTFLAGS:-}"
export GUEST_ONECRATE_PROGRESS_SEC="${GUEST_ONECRATE_PROGRESS_SEC}"
export GUEST_ONECRATE_SYSCALL_STATS_SEC="${GUEST_ONECRATE_SYSCALL_STATS_SEC}"
export GUEST_ONECRATE_SKIP_STATS_RESET="${GUEST_ONECRATE_SKIP_STATS_RESET}"
export GUEST_ONECRATE_SYSCALL_TRACE="${GUEST_ONECRATE_SYSCALL_TRACE}"
export GUEST_ONECRATE_TRACE_SNAPSHOT_SEC="${GUEST_ONECRATE_TRACE_SNAPSHOT_SEC}"
export GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS="${GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS}"
export GUEST_ONECRATE_DEEP_TRACE_SEC="${GUEST_ONECRATE_DEEP_TRACE_SEC}"
export GUEST_ONECRATE_WAIT_ONLY="${GUEST_ONECRATE_WAIT_ONLY}"
export GUEST_ONECRATE_DEVLOG_SEC="${GUEST_ONECRATE_DEVLOG_SEC}"
export GUEST_ONECRATE_CARGO_TAIL_SEC="${GUEST_ONECRATE_CARGO_TAIL_SEC}"
export GUEST_ONECRATE_HELLO_USE_LLD="${GUEST_ONECRATE_HELLO_USE_LLD:-0}"
export GUEST_ONECRATE_HELLO_LINKER="${GUEST_ONECRATE_HELLO_LINKER:-}"
export GUEST_ONECRATE_JOBS="${GUEST_ONECRATE_JOBS:-1}"
_ENVEOF
ENV_SH_EOF

  # ── run-tests.sh (fallback for init paths that use it) ──
  cat >> "$INJECT_SCRIPT" <<RUN_TESTS_EOF
tee "\${MNT}/opt/run-tests.sh" >/dev/null <<'EOF'
#!/bin/bash
echo "===GUEST_ONECRATE_RUN_TESTS_BEGIN==="
export GUEST_ONECRATE_CRATE="${CRATE}"
export GUEST_ONECRATE_TARGET="${TARGET}"
export GUEST_ONECRATE_SAMPLE_SLEEP="${SLEEP}"
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE}"
export GUEST_ONECRATE_CARGO_PHASE="${GUEST_ONECRATE_CARGO_PHASE}"
export GUEST_ONECRATE_CARGO_TRACE="${GUEST_ONECRATE_CARGO_TRACE}"
export GUEST_ONECRATE_CARGO_VERBOSE="${GUEST_ONECRATE_CARGO_VERBOSE}"
export GUEST_ONECRATE_ALLOW_FETCH="${ALLOW_FETCH}"
export GUEST_ONECRATE_RUSTFLAGS="${GUEST_ONECRATE_RUSTFLAGS:-}"
export GUEST_ONECRATE_PROGRESS_SEC="${GUEST_ONECRATE_PROGRESS_SEC}"
export GUEST_ONECRATE_SYSCALL_STATS_SEC="${GUEST_ONECRATE_SYSCALL_STATS_SEC}"
export GUEST_ONECRATE_SKIP_STATS_RESET="${GUEST_ONECRATE_SKIP_STATS_RESET}"
export GUEST_ONECRATE_SYSCALL_TRACE="${GUEST_ONECRATE_SYSCALL_TRACE}"
export GUEST_ONECRATE_TRACE_SNAPSHOT_SEC="${GUEST_ONECRATE_TRACE_SNAPSHOT_SEC}"
export GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS="${GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS}"
export GUEST_ONECRATE_DEEP_TRACE_SEC="${GUEST_ONECRATE_DEEP_TRACE_SEC}"
export GUEST_ONECRATE_WAIT_ONLY="${GUEST_ONECRATE_WAIT_ONLY}"
export GUEST_ONECRATE_DEVLOG_SEC="${GUEST_ONECRATE_DEVLOG_SEC}"
export GUEST_ONECRATE_CARGO_TAIL_SEC="${GUEST_ONECRATE_CARGO_TAIL_SEC}"
export GUEST_ONECRATE_HELLO_USE_LLD="${GUEST_ONECRATE_HELLO_USE_LLD:-0}"
export GUEST_ONECRATE_HELLO_LINKER="${GUEST_ONECRATE_HELLO_LINKER:-}"
export GUEST_ONECRATE_JOBS="${GUEST_ONECRATE_JOBS:-1}"
echo "===GUEST_ONECRATE_EXEC_BASH==="
exec /bin/bash --noprofile --norc /opt/guest-onecrate-inner.sh
EOF
chmod +x "\${MNT}/opt/run-tests.sh"
cp -f "/work/scripts/guest-onecrate-inner.sh" "\${MNT}/opt/guest-onecrate-inner.sh"
chmod +x "\${MNT}/opt/guest-onecrate-inner.sh"
umount "\${MNT}" || { echo "umount failed"; exit 1; }
echo "inject-done"
RUN_TESTS_EOF

  chmod +x "$INJECT_SCRIPT"

  # Run the inject script in a Docker container.
  # This is a quick operation (just mount + copy files + umount).
  DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
  echo "[macos-native] running inject via Docker (platform=${DOCKER_PLATFORM})..."
  set +e
  docker run --rm --privileged \
    --platform "${DOCKER_PLATFORM}" \
    -v "${REPO}:/work" \
    auto-os/starry:latest \
    bash -c "mkdir -p /tmp/guest-onecrate-mnt && bash /work/.guest-runs/.macos-inject-$$.sh /work/${ROOTFS#${REPO}/}" \
    2>&1 | tail -5
  INJECT_RC=$?
  set -e
  rm -f "$INJECT_SCRIPT"

  if [[ "$INJECT_RC" -ne 0 ]]; then
    echo "[macos-native] WARNING: Docker inject failed (rc=$INJECT_RC)" >&2
    echo "[macos-native] Continuing — the rootfs may already have the needed scripts" >&2
    echo "[macos-native] Set GUEST_ONECRATE_SKIP_INJECT=1 to suppress this warning" >&2
  else
    echo "[macos-native] inject done"
  fi
fi

# ── Verify QEMU is available ─────────────────────────────────────
if ! command -v qemu-system-riscv64 >/dev/null 2>&1; then
  echo "error: qemu-system-riscv64 not found. Install: brew install qemu" >&2
  exit 1
fi

# ── HTTP sidecars (same as Docker path) ──────────────────────────
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

# ── Run QEMU natively ────────────────────────────────────────────
# macOS doesn't have GNU `timeout`; use background process + kill.
echo "[macos-native] starting QEMU..."
qemu-system-riscv64 \
  -nographic -machine virt -bios default -smp 1 -m 4G \
  -kernel "$KERNEL_BIN" -cpu rv64 \
  -monitor none -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive "id=disk0,if=none,format=raw,file=$ROOTFS,file.locking=off" \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  >"$RESULT" 2>&1 </dev/null &
QEMU_PID=$!

# Wait with timeout
QEMU_RC=0
SECONDS=0
while kill -0 "$QEMU_PID" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$TO" ]]; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_RC=124  # same as GNU timeout(1)
    break
  fi
  sleep 2
done
if [[ "$QEMU_RC" -ne 124 ]]; then
  wait "$QEMU_PID" 2>/dev/null || QEMU_RC=$?
fi

# ── Post-run diagnostics (same as Docker path) ───────────────────
export GUEST_ONECRATE_RESULT="$RESULT"
export GUEST_ONECRATE_Q_RC="$QEMU_RC"
set +e
if [[ "$QEMU_RC" -ne 0 ]] || [[ ! -s "$RESULT" ]] || ! grep -a -q '===GUEST_ONECRATE_CHECK_RC 0===' "$RESULT" 2>/dev/null; then
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
print("macos_native: true")
PY

if [[ "$QEMU_RC" -eq 124 ]]; then
  echo "[+] qemu outer exit=$QEMU_RC (timeout killed QEMU)"
else
  echo "[+] qemu outer exit=$QEMU_RC"
fi

if [[ ! -s "$RESULT" ]]; then
  echo "[!] serial log empty: $RESULT"
  exit 1
fi
if ! grep -a -q '===GUEST_ONECRATE_CHECK_RC 0===' "$RESULT"; then
  echo "[!] missing ===GUEST_ONECRATE_CHECK_RC 0=== in $RESULT (qemu_exit=$QEMU_RC)"
  exit 1
fi

# Exit here — skip the rest of the Docker-path script.
exit 0
