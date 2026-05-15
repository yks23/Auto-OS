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
#   GUEST_ONECRATE_MODE=cargo-hello — 独立 hello crate，默认先跑 cargo metadata --offline；可设 phase=check。
#   GUEST_ONECRATE_MODE=probe — 仅跑 fd/pipe/ppoll/statx/readlinkat 小探针，不跑 cargo/rustc。
#   GUEST_ONECRATE_MODE=cargo — cargo check -p … --offline（默认，与宿主 onecrate 对齐时显式传入）。
#   GUEST_ONECRATE_CARGO_PHASE=check|check-vv|metadata|locate-project|hello-check|build|hello-build|run|hello-run — cargo 子阶段。
#   GUEST_ONECRATE_CARGO_TRACE=1 — cargo 模式下打开 CARGO_LOG=trace / RUST_LOG=cargo=trace。
#   GUEST_ONECRATE_CARGO_VERBOSE=1 — cargo 模式下打开 trace，并默认每 5s 串口 echo cargo log tail。
#   GUEST_ONECRATE_RESULTS / GUEST_ONECRATE_OUT_DIR / GUEST_ONECRATE_SUMMARY — 串口日志与 summary 路径（可选）。
#   GUEST_ONECRATE_PROGRESS_SEC — 传给访客 inner：cargo 运行中心跳秒数（默认 300，0=关闭）。
#   GUEST_ONECRATE_SYSCALL_STATS_SEC — inner 内严格定间隔（先 sleep 满周期）dump + ===ONECRATE_SYSCALL_5S=== 行（默认 5；0=关闭）。
#   GUEST_ONECRATE_SYSCALL_TRACE=1 — 访客内 echo 1 >/proc/syscall_trace，实时 syscall_trace 打到串口 info 日志。
#   GUEST_ONECRATE_TRACE_SNAPSHOT_SEC — 传给 inner；默认 0，>0 时周期 dump syscall in-flight/recent/task snapshot。
#   GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS=1 — snapshot 跳过 /proc/task_snapshot 和 /proc/tasks。
#   GUEST_ONECRATE_DEEP_TRACE_SEC — 传给 inner；默认 0，>0 时周期 dump futex/poll/pipe/path deep trace。
#   GUEST_ONECRATE_WAIT_ONLY=1 — 传给 inner；不启动 guest sleep 轮询，只 wait cargo/rustc/probe。
#   GUEST_ONECRATE_DEVLOG_SEC — cargo 时每隔该秒数用 logger 发最后一行 cargo 输出到 /dev/log（见 starry-userspace-log）；默认 15；0=关闭。
#   GUEST_ONECRATE_CARGO_TAIL_SEC — cargo 时每隔该秒数直接 echo cargo log tail 到串口；默认 0。
#   GUEST_ONECRATE_TAIL_HTTP — 默认 1：QEMU 前起 tail-http-serve.py，浏览器看串口 results.txt（GUEST_ONECRATE_TAIL_HTTP_PORT 默认 13888）；0=关闭。
#   GUEST_ONECRATE_DISPOSABLE_ROOTFS=1 — 先复制 rootfs 到 OUT_DIR/rootfs.img，再注入与启动，避免污染基准镜像。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

# On macOS (Darwin), QEMU runs natively and we cannot mount ext4 images.
# Instead, we use a Docker helper for the mount/inject step (if needed)
# and run QEMU natively. Set GUEST_ONECRATE_MACOS_NATIVE=1 to force this.
# Set GUEST_ONECRATE_MACOS_NATIVE=0 to use the Docker path (may fail on macOS arm64).
_GUEST_ONECRATE_OS="$(uname -s)"
_GUEST_ONECRATE_MACOS_NATIVE="${GUEST_ONECRATE_MACOS_NATIVE:-}"
if [[ -z "$_GUEST_ONECRATE_MACOS_NATIVE" ]]; then
  if [[ "$_GUEST_ONECRATE_OS" == "Darwin" ]]; then
    _GUEST_ONECRATE_MACOS_NATIVE=1
  else
    _GUEST_ONECRATE_MACOS_NATIVE=0
  fi
fi

if [[ "$(id -u)" -ne 0 && "$_GUEST_ONECRATE_MACOS_NATIVE" != "1" ]]; then
  exec docker run --rm --privileged --network host \
    -v "${REPO}:/work" -w /work \
    -e "GUEST_ONECRATE_ROOTFS=${GUEST_ONECRATE_ROOTFS:-}" \
    -e "GUEST_ONECRATE_DISPOSABLE_ROOTFS=${GUEST_ONECRATE_DISPOSABLE_ROOTFS:-}" \
    -e "GUEST_ONECRATE_TIMEOUT=${GUEST_ONECRATE_TIMEOUT:-}" \
    -e "GUEST_ONECRATE_SKIP_KERNEL_SAVE=${GUEST_ONECRATE_SKIP_KERNEL_SAVE:-}" \
    -e "GUEST_ONECRATE_CRATE=${GUEST_ONECRATE_CRATE:-}" \
    -e "GUEST_ONECRATE_TARGET=${GUEST_ONECRATE_TARGET:-}" \
    -e "GUEST_ONECRATE_SAMPLE_SLEEP=${GUEST_ONECRATE_SAMPLE_SLEEP:-}" \
    -e "GUEST_ONECRATE_MODE=${GUEST_ONECRATE_MODE:-cargo}" \
    -e "GUEST_ONECRATE_CARGO_PHASE=${GUEST_ONECRATE_CARGO_PHASE:-}" \
    -e "GUEST_ONECRATE_CARGO_TRACE=${GUEST_ONECRATE_CARGO_TRACE:-}" \
    -e "GUEST_ONECRATE_CARGO_VERBOSE=${GUEST_ONECRATE_CARGO_VERBOSE:-}" \
    -e "GUEST_ONECRATE_ALLOW_FETCH=${GUEST_ONECRATE_ALLOW_FETCH:-0}" \
    -e "GUEST_ONECRATE_RUSTFLAGS=${GUEST_ONECRATE_RUSTFLAGS:-}" \
    -e "GUEST_ONECRATE_RESULTS=${GUEST_ONECRATE_RESULTS:-}" \
    -e "GUEST_ONECRATE_OUT_DIR=${GUEST_ONECRATE_OUT_DIR:-}" \
    -e "GUEST_ONECRATE_SUMMARY=${GUEST_ONECRATE_SUMMARY:-}" \
    -e "GUEST_ONECRATE_PROGRESS_SEC=${GUEST_ONECRATE_PROGRESS_SEC:-}" \
    -e "GUEST_ONECRATE_SYSCALL_STATS_SEC=${GUEST_ONECRATE_SYSCALL_STATS_SEC:-}" \
    -e "GUEST_ONECRATE_SKIP_STATS_RESET=${GUEST_ONECRATE_SKIP_STATS_RESET:-}" \
    -e "GUEST_ONECRATE_SYSCALL_TRACE=${GUEST_ONECRATE_SYSCALL_TRACE:-}" \
    -e "GUEST_ONECRATE_TRACE_SNAPSHOT_SEC=${GUEST_ONECRATE_TRACE_SNAPSHOT_SEC:-}" \
    -e "GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS=${GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS:-}" \
    -e "GUEST_ONECRATE_DEEP_TRACE_SEC=${GUEST_ONECRATE_DEEP_TRACE_SEC:-}" \
    -e "GUEST_ONECRATE_WAIT_ONLY=${GUEST_ONECRATE_WAIT_ONLY:-}" \
    -e "GUEST_ONECRATE_DEVLOG_SEC=${GUEST_ONECRATE_DEVLOG_SEC:-}" \
    -e "GUEST_ONECRATE_CARGO_TAIL_SEC=${GUEST_ONECRATE_CARGO_TAIL_SEC:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP=${GUEST_ONECRATE_TAIL_HTTP:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP_PORT=${GUEST_ONECRATE_TAIL_HTTP_PORT:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP_LINES=${GUEST_ONECRATE_TAIL_HTTP_LINES:-}" \
    -e "GUEST_ONECRATE_TAIL_HTTP_REFRESH=${GUEST_ONECRATE_TAIL_HTTP_REFRESH:-}" \
    -e "GUEST_ONECRATE_STATS_HTTP=${GUEST_ONECRATE_STATS_HTTP:-}" \
    -e "STARRY_SMOKE_STATS_HTTP=${STARRY_SMOKE_STATS_HTTP:-}" \
    auto-os/starry:latest \
    bash /work/scripts/guest-onecrate-syscall-evidence.sh
fi

# ─── macOS native path ───────────────────────────────────────────────
# On macOS, we cannot mount ext4 images natively. Instead:
#   1. Use Docker for the mount/inject step (if rootfs needs modification)
#   2. Run QEMU natively (Homebrew qemu-system-riscv64)
#   3. Use rust-objcopy/llvm-objcopy instead of riscv64-linux-musl-objcopy
#
# If GUEST_ONECRATE_SKIP_INJECT=1 or the rootfs already has scripts,
# we skip the Docker inject step entirely.
if [[ "$_GUEST_ONECRATE_MACOS_NATIVE" == "1" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/inc/guest-macos-native.inc.sh"
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

if [[ "${GUEST_ONECRATE_DISPOSABLE_ROOTFS:-0}" == "1" ]]; then
  mkdir -p "$OUT_DIR"
  BASE_ROOTFS="$ROOTFS"
  ROOTFS="$OUT_DIR/rootfs.img"
  if [[ "$BASE_ROOTFS" != "$ROOTFS" ]]; then
    cp -f "$BASE_ROOTFS" "$ROOTFS"
  fi
  echo "[+] disposable rootfs: $BASE_ROOTFS -> $ROOTFS"
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

# Replace libscudo.so with musl symlink — crashes under QEMU TCG
if [[ -f "${MNT}/opt/alpine-rust/usr/lib/libscudo.so" && ! -L "${MNT}/opt/alpine-rust/usr/lib/libscudo.so" ]]; then
  rm -f "${MNT}/opt/alpine-rust/usr/lib/libscudo.so"
  ln -sf /lib/libc.musl-riscv64.so.1 "${MNT}/opt/alpine-rust/usr/lib/libscudo.so"
fi

CRATE="${GUEST_ONECRATE_CRATE:-ax-errno}"
TARGET="${GUEST_ONECRATE_TARGET:-riscv64gc-unknown-none-elf}"
SLEEP="${GUEST_ONECRATE_SAMPLE_SLEEP:-0.5}"
# 默认 cargo（与旧行为一致）；受控最简：GUEST_ONECRATE_MODE=rustc GUEST_ONECRATE_ALLOW_FETCH=0
ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH:-0}"
# `set -u` 下，未引用的 heredoc 展开若出现未赋值名（例如误写 ${MODE}）会直接失败；此处先 export 默认值，heredoc 只引用已定义名。
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

mkdir -p "${MNT}/opt/tiny"
# rustc 最简受控路径（无 cargo、无网络）；cargo 模式时亦存在，无害。
cat >"${MNT}/opt/tiny/hello.rs" <<'HELLO'
fn main() {}
HELLO

mkdir -p "${MNT}/opt/onecrate-hello/src"
cat >"${MNT}/opt/onecrate-hello/Cargo.toml" <<'HELLO_CARGO'
[package]
name = "onecrate-hello"
version = "0.1.0"
edition = "2021"

[dependencies]
HELLO_CARGO
cat >"${MNT}/opt/onecrate-hello/src/main.rs" <<'HELLO_RS'
fn main() {
    println!("hello from starry cargo");
}
HELLO_RS

# Cargo 会用 O_CREAT|O_NOFOLLOW 打开这些 cache 哨兵文件。当前 Starry/rsext4
# create 路径在访客内可能卡住；rootfs 注入阶段预置它们，让 cargo 走普通 open。
mkdir -p "${MNT}/opt/tgoskits/.m6-tmp" "${MNT}/opt/tgoskits/m6-cargo-home/registry"
cat >"${MNT}/opt/tgoskits/m6-cargo-home/config.toml" <<'CARGO_CONFIG'
[cache]
auto-clean-frequency = "never"
CARGO_CONFIG
: >"${MNT}/opt/tgoskits/m6-cargo-home/.package-cache"
: >"${MNT}/opt/tgoskits/m6-cargo-home/.package-cache-journal"
: >"${MNT}/opt/tgoskits/m6-cargo-home/.global-cache"
: >"${MNT}/opt/tgoskits/m6-cargo-home/.global-cache-journal"

if [[ "${GUEST_ONECRATE_MODE}" == "probe" ]]; then
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

/* riscv64-linux-musl toolchain may not link libc statx(); use syscall. */
#ifndef __NR_statx
#if defined(__riscv) && __riscv_xlen == 64
#define __NR_statx 291
#endif
#endif

static int fail(const char *what) {
  printf("PROBE_FAIL %s errno=%d (%s)\n", what, errno, strerror(errno));
  return 1;
}

static int expect(int cond, const char *what) {
  if (!cond) {
    printf("PROBE_FAIL %s\n", what);
    return 1;
  }
  printf("PROBE_OK %s\n", what);
  return 0;
}

int main(void) {
  int rc = 0;
  int p[2];
  char ch = 0;

  if (pipe2(p, O_CLOEXEC | O_NONBLOCK) != 0) return fail("pipe2");
  int fl = fcntl(p[0], F_GETFL);
  if (fl < 0) return fail("fcntl_getfl_initial");
  rc |= expect((fl & O_NONBLOCK) != 0, "getfl_initial_nonblock");

  if (fcntl(p[0], F_SETFL, fl & ~O_NONBLOCK) != 0) return fail("fcntl_setfl_clear");
  fl = fcntl(p[0], F_GETFL);
  if (fl < 0) return fail("fcntl_getfl_cleared");
  rc |= expect((fl & O_NONBLOCK) == 0, "setfl_clear_nonblock");

  if (fcntl(p[0], F_SETFL, fl | O_NONBLOCK) != 0) return fail("fcntl_setfl_set");
  errno = 0;
  ssize_t n = read(p[0], &ch, 1);
  rc |= expect(n < 0 && errno == EAGAIN, "nonblock_empty_read_eagain");

  if (close(p[1]) != 0) return fail("close_writer");
  struct pollfd fds[1] = {{ .fd = p[0], .events = POLLIN, .revents = 0 }};
  int pr = ppoll(fds, 1, NULL, NULL);
  if (pr < 0) return fail("ppoll_hup");
  rc |= expect(pr == 1 && (fds[0].revents & (POLLIN | POLLHUP)) != 0, "ppoll_pipe_hup");
  n = read(p[0], &ch, 1);
  rc |= expect(n == 0, "pipe_eof_after_writer_close");
  close(p[0]);

  int fd = open("/bin/sh", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return fail("open_bin_sh");
  struct statx sx;
  memset(&sx, 0, sizeof(sx));
  if (syscall(__NR_statx, fd, "", AT_EMPTY_PATH, STATX_ALL, &sx) != 0)
    return fail("statx_empty_path");
  rc |= expect((sx.stx_mask & STATX_BASIC_STATS) == STATX_BASIC_STATS, "statx_basic_mask");
  close(fd);

  char buf[256];
  ssize_t rn = readlinkat(AT_FDCWD, "/proc/self/exe", buf, sizeof(buf) - 1);
  if (rn < 0) return fail("readlink_proc_self_exe");
  buf[rn] = 0;
  rc |= expect(rn > 0 && buf[0] == '/', "readlink_proc_self_exe_absolute");

  int tfd = open("/tmp/.readlink_probe", O_CREAT | O_WRONLY | O_TRUNC, 0644);
  if (tfd < 0) return fail("open_tmp_probe");
  if (write(tfd, "x", 1) != 1) return fail("write_tmp_probe");
  close(tfd);
  errno = 0;
  rn = readlinkat(AT_FDCWD, "/tmp/.readlink_probe", buf, sizeof(buf));
  unlink("/tmp/.readlink_probe");
  rc |= expect(rn < 0 && errno == EINVAL, "readlink_regular_file_einval");

  int fut = 0;
  struct timespec fts = { .tv_sec = 0, .tv_nsec = 1000000 };
  errno = 0;
  long fr = syscall(SYS_futex, &fut, FUTEX_WAIT, 0, &fts, NULL, 0);
  rc |= expect(fr < 0 && errno == ETIMEDOUT, "futex_wait_timeout");

  printf("PROBE_DONE rc=%d\n", rc);
  return rc;
}
PROBE_C
  riscv64-linux-musl-gcc -static -O2 -Wall -Wextra \
    "${MNT}/opt/fd-pipe-probe.c" -o "${MNT}/opt/fd-pipe-probe"
  chmod +x "${MNT}/opt/fd-pipe-probe"
fi

tee "${MNT}/opt/run-tests.sh" >/dev/null <<EOF
#!/bin/bash
echo "===GUEST_ONECRATE_RUN_TESTS_BEGIN==="
export GUEST_ONECRATE_CRATE="${CRATE}"
export GUEST_ONECRATE_TARGET="${TARGET}"
export GUEST_ONECRATE_SAMPLE_SLEEP="${SLEEP}"
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE}"
export GUEST_ONECRATE_CARGO_PHASE="${GUEST_ONECRATE_CARGO_PHASE}"
export GUEST_ONECRATE_CARGO_TRACE="${GUEST_ONECRATE_CARGO_TRACE}"
export GUEST_ONECRATE_CARGO_VERBOSE="${GUEST_ONECRATE_CARGO_VERBOSE}"
export GUEST_ONECRATE_ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH}"
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
echo "===GUEST_ONECRATE_EXEC_BASH==="
exec /bin/bash --noprofile --norc /opt/guest-onecrate-inner.sh
EOF
chmod +x "${MNT}/opt/run-tests.sh"
tee "${MNT}/opt/guest-onecrate-env.sh" >/dev/null <<EOF
export GUEST_ONECRATE_CRATE="${CRATE}"
export GUEST_ONECRATE_TARGET="${TARGET}"
export GUEST_ONECRATE_SAMPLE_SLEEP="${SLEEP}"
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE}"
export GUEST_ONECRATE_CARGO_PHASE="${GUEST_ONECRATE_CARGO_PHASE}"
export GUEST_ONECRATE_CARGO_TRACE="${GUEST_ONECRATE_CARGO_TRACE}"
export GUEST_ONECRATE_CARGO_VERBOSE="${GUEST_ONECRATE_CARGO_VERBOSE}"
export GUEST_ONECRATE_ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH}"
export GUEST_ONECRATE_RUSTFLAGS="${GUEST_ONECRATE_RUSTFLAGS}"
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
EOF
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

# QEMU TCG LR/SC broken under MTTCG; only need single-threaded TCG when SMP > 1.
_EVSMP="${EVIDENCE_SMP:-1}"
_evtcg=()
if [[ "$_EVSMP" -gt 1 ]]; then _evtcg=(-accel tcg,thread=single); fi
set +e
timeout "$TO" qemu-system-riscv64 \
  -nographic -machine virt -bios default -smp "$_EVSMP" -m 5G \
  "${_evtcg[@]}" \
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
