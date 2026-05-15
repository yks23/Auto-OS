#!/bin/bash
# 由 guest-onecrate-syscall-evidence.sh 拷入 rootfs /opt/；init 通过 /opt/run-tests.sh 调用。
#
# 环境变量（run-tests 设置）：
#   GUEST_ONECRATE_MODE=cargo|cargo-hello|rustc|probe  — 默认 cargo；cargo-hello=独立 hello crate；
#     rustc=仅编 /opt/tiny/hello.rs；probe=fd/pipe/path 语义探针
#   GUEST_ONECRATE_CARGO_PHASE=check|check-vv|metadata|locate-project|hello-check|build|hello-build|run|hello-run
#     — cargo 子阶段，默认 check；cargo-hello 支持 metadata|check|check-vv|build|run，默认 metadata（由 evidence 脚本设置）。
#   GUEST_ONECRATE_HELLO_USE_LLD=1 — cargo-hello 的 build/run 默认尝试 rust-lld 链接，绕过 guest 内 cc/clang 崩溃。
#   GUEST_ONECRATE_HELLO_LINKER=/opt/alpine-rust/usr/bin/rust-lld — 可覆盖 hello build/run 的 linker 路径。
#   GUEST_ONECRATE_CARGO_TRACE=1 — cargo 模式下设置 CARGO_LOG=trace / RUST_LOG=cargo=trace
#   GUEST_ONECRATE_CARGO_VERBOSE=1 — cargo 模式下打开 trace，并默认每 5s 串口 echo cargo log tail
#   GUEST_ONECRATE_ALLOW_FETCH=0|1 — 默认 0：不跑 cargo fetch（控制变量：不依赖网络）
#   GUEST_ONECRATE_CRATE / GUEST_ONECRATE_TARGET / GUEST_ONECRATE_SAMPLE_SLEEP — 仅 cargo 模式用
#   GUEST_ONECRATE_PROGRESS_SEC — 访客串口心跳间隔（秒），默认 300；设为 0 关闭
#   GUEST_ONECRATE_SYSCALL_STATS_SEC — cargo/rustc 子进程存活期间每满该秒数 sleep 一次后：
#     先打一行 ===ONECRATE_SYSCALL_5S===（速率表，见下），再打完整 ===ONECRATE_SYSCALL_STATS_*===；
#     默认 5；0=关闭；非法值按 5。与主循环 ===ONECRATE_SYSCALL_SAMPLE===（GUEST_ONECRATE_SAMPLE_SLEEP，
#     默认 0.5s）独立：后者是高频快照，前者是严格定间隔的累计差分统计。
#   GUEST_ONECRATE_SYSCALL_TRACE=1 — 写 /proc/syscall_trace 开启内核实时 syscall_trace info 日志。
#   GUEST_ONECRATE_TRACE_SNAPSHOT_SEC — 默认 0；>0 时开启 /proc/syscall_trace_snapshot，
#     每 N 秒 dump syscall in-flight/recent/task snapshot/stats_total 到串口。
#   GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS=1 — snapshot 只 dump syscall 相关 proc 文件，
#     跳过 /proc/task_snapshot 和 /proc/tasks。
#   GUEST_ONECRATE_DEEP_TRACE_SEC — 默认 0；>0 时开启 /proc/syscall_deep_trace，
#     每 N 秒 dump futex/poll/pipe/path deep ring、task block snapshot 和 syscall recent。
#   GUEST_ONECRATE_DEVLOG_SEC — 仅 cargo：每隔该秒数用 logger(1) 把 cargo.log 最后一行发到 /dev/log
#     （Starry 上用户态 syslog 走 Unix /dev/log，见 .cursor/skills/starry-userspace-log）；0=关闭。
#   GUEST_ONECRATE_CARGO_TAIL_SEC — 仅 cargo：每隔该秒数直接 echo cargo.log tail 到串口；0=关闭。
set -eo pipefail
ulimit -s unlimited 2>/dev/null || true
MODE="${GUEST_ONECRATE_MODE:-cargo}"
ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH:-0}"
CRATE="${GUEST_ONECRATE_CRATE:-ax-errno}"
TARGET="${GUEST_ONECRATE_TARGET:-riscv64gc-unknown-none-elf}"
SLEEP_SEC="${GUEST_ONECRATE_SAMPLE_SLEEP:-0.5}"

echo "===GUEST_ONECRATE_BEGIN mode=${MODE} crate=${CRATE} target=${TARGET} allow_fetch=${ALLOW_FETCH}==="
date -u

if [[ "${GUEST_ONECRATE_SKIP_STATS_RESET:-0}" == "1" ]]; then
  echo "[onecrate] skip syscall stats reset"
elif ! echo x >/proc/syscall_stats_reset 2>/dev/null; then
  echo "===GUEST_ONECRATE_FAIL no /proc/syscall_stats_reset==="
  exit 2
fi
TRACE_SYSCALLS="${GUEST_ONECRATE_SYSCALL_TRACE:-0}"
TRACE_SYSCALLS_ENABLED=0
if [[ "${TRACE_SYSCALLS}" =~ ^(1|true|on|yes)$ ]]; then
  if test -w /proc/syscall_trace 2>/dev/null; then
    echo 1 >/proc/syscall_trace
    TRACE_SYSCALLS_ENABLED=1
    echo "[onecrate] syscall trace: enabled via /proc/syscall_trace (kernel info log)"
  else
    echo "[onecrate] syscall trace: /proc/syscall_trace not writable (need newer kernel)"
  fi
fi

# ── Detect Rust toolchain location ──
_CARGO_BIN=""
_RUSTC_BIN=""
_RUST_LLD=""
if [[ -x /opt/alpine-rust/usr/bin/cargo ]]; then
  # Alpine musl rootfs with rustc installed at /opt/alpine-rust/
  _CARGO_BIN="/opt/alpine-rust/usr/bin/cargo"
  _RUSTC_BIN="/opt/alpine-rust/usr/bin/rustc"
  export PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin"
  export LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib"
elif [[ -x /root/.cargo/bin/cargo ]]; then
  # Rustup-based rootfs with toolchain at /root/.cargo/bin/ and /root/.rustup/
  _CARGO_BIN="/root/.cargo/bin/cargo"
  _RUSTC_BIN="/root/.cargo/bin/rustc"
  export PATH="/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  # Don't set LD_LIBRARY_PATH for rustup/glibc rootfs — let the dynamic linker handle it
  unset LD_LIBRARY_PATH 2>/dev/null || true
  # Set rustup environment so the proxy knows where to find things
  export RUSTUP_HOME="${RUSTUP_HOME:-/root/.rustup}"
  if [[ -z "${RUSTUP_TOOLCHAIN:-}" ]] && [[ -d "${RUSTUP_HOME}/toolchains" ]]; then
    _tc="$(ls -d "${RUSTUP_HOME}"/toolchains/nightly-*riscv64* 2>/dev/null | head -1)"
    if [[ -n "$_tc" ]]; then
      export RUSTUP_TOOLCHAIN="$(basename "$_tc")"
    fi
  fi
  # Find rust-lld
  for _lld_cand in \
    /root/.rustup/toolchains/*/lib/rustlib/riscv64gc-unknown-linux-gnu/bin/rust-lld \
    /root/.rustup/toolchains/*/lib/rustlib/riscv64-alpine-linux-musl/bin/rust-lld; do
    if [[ -x "${_lld_cand}" ]]; then
      _RUST_LLD="${_lld_cand}"
      break
    fi
  done
else
  # Fallback: use whatever is in PATH
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  unset LD_LIBRARY_PATH 2>/dev/null || true
fi
echo "[onecrate] toolchain: cargo=${_CARGO_BIN:-<not found>} rustc=${_RUSTC_BIN:-<not found>} rust-lld=${_RUST_LLD:-<not found>}"
# Prevent vec_cache.rs:201 ICE: disable rustc parallel frontend under QEMU TCG timing.
# Set GUEST_ONECRATE_NO_SERIAL_RUSTC=1 to disable.
if [[ "${GUEST_ONECRATE_NO_SERIAL_RUSTC:-}" != "1" && -n "${_RUSTC_BIN}" ]]; then
  export RUSTC_BOOTSTRAP=1
  _SERIAL_RF="-Z threads=0"
else
  _SERIAL_RF=""
fi
export SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp
export TMPDIR=/opt/tgoskits/.m6-tmp
export TMP=/opt/tgoskits/.m6-tmp
export TEMP=/opt/tgoskits/.m6-tmp
/bin/mkdir -p "$TMPDIR" /opt/tgoskits/m6-cargo-home/registry 2>/dev/null || true
export CARGO_HOME="${CARGO_HOME:-/opt/tgoskits/m6-cargo-home}"
export CARGO_CACHE_AUTO_CLEAN_FREQUENCY="${CARGO_CACHE_AUTO_CLEAN_FREQUENCY:-never}"
if [[ -x /opt/ccwrap/cc ]]; then
  export CC="${CC:-/opt/ccwrap/cc}"
  export CXX="${CXX:-/opt/ccwrap/c++}"
elif command -v gcc >/dev/null 2>&1; then
  export CC="${CC:-gcc}"
  export CXX="${CXX:-g++}"
elif command -v cc >/dev/null 2>&1; then
  export CC="${CC:-cc}"
  export CXX="${CXX:-c++}"
fi
export RUST_MIN_STACK="${RUST_MIN_STACK:-16777216}"
_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
_JOBS="${GUEST_ONECRATE_JOBS:-1}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-$_JOBS}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_JOBS}"
export CARGO_TERM_PROGRESS="${CARGO_TERM_PROGRESS:-wide}"
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-true}"

: >/tmp/guest-onecrate-cargo.log

_is_cargo_like() {
  [[ "${MODE}" == cargo* ]]
}

_setup_hello_crate() {
  HELLO_DIR="/opt/onecrate-hello"
  if [[ ! -f "${HELLO_DIR}/Cargo.toml" ]]; then
    HELLO_DIR="/tmp/onecrate-hello"
    /bin/mkdir -p "${HELLO_DIR}/src" 2>/dev/null || true
    printf '[package]\nname = "onecrate-hello"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' >"${HELLO_DIR}/Cargo.toml"
    printf 'fn main() { println!("hello from starry cargo"); }\n' >"${HELLO_DIR}/src/main.rs"
  fi

  export CARGO_HOME="${GUEST_ONECRATE_HELLO_CARGO_HOME:-${CARGO_HOME}}"
  export CARGO_TARGET_DIR="${GUEST_ONECRATE_HELLO_TARGET_DIR:-/tmp/onecrate-target}"
  /bin/mkdir -p "${CARGO_HOME}" "${CARGO_TARGET_DIR}" "${TMPDIR}" 2>/dev/null || true
  cat >"${CARGO_HOME}/config.toml" <<'CARGO_HELLO_CONFIG'
[net]
offline = true

[cache]
auto-clean-frequency = "never"

[build]
jobs = 1
CARGO_HELLO_CONFIG
  echo "[onecrate] hello crate=${HELLO_DIR} CARGO_HOME=${CARGO_HOME} CARGO_TARGET_DIR=${CARGO_TARGET_DIR}"
}

_setup_tmp_hello_check_crate() {
  HELLO_DIR="/tmp/onecrate-hello"
  /bin/mkdir -p "${HELLO_DIR}/src" 2>/dev/null || true
  printf '[package]\nname = "onecrate-hello"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\nname = "onecrate_hello"\npath = "src/lib.rs"\n\n[dependencies]\n' >"${HELLO_DIR}/Cargo.toml"
  printf 'pub fn hello() -> String { "hello".to_string() }\n' >"${HELLO_DIR}/src/lib.rs"
  rm -f "${HELLO_DIR}/src/main.rs" 2>/dev/null || true
  export CARGO_HOME="${GUEST_ONECRATE_HELLO_CARGO_HOME:-${CARGO_HOME}}"
  unset CARGO_TARGET_DIR
  echo "[onecrate] hello-check crate=${HELLO_DIR} cwd=$(pwd) CARGO_HOME=${CARGO_HOME} CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-<unset>}"
}

_setup_tmp_hello_bin_crate() {
  HELLO_DIR="/tmp/onecrate-hello"
  /bin/mkdir -p "${HELLO_DIR}/src" 2>/dev/null || true
  printf '[package]\nname = "onecrate-hello"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' >"${HELLO_DIR}/Cargo.toml"
  printf 'fn main() { println!("hello from starry cargo"); }\n' >"${HELLO_DIR}/src/main.rs"
  rm -f "${HELLO_DIR}/src/lib.rs" 2>/dev/null || true
  export CARGO_HOME="${GUEST_ONECRATE_HELLO_CARGO_HOME:-${CARGO_HOME}}"
  unset CARGO_TARGET_DIR
  echo "[onecrate] hello-bin crate=${HELLO_DIR} cwd=$(pwd) CARGO_HOME=${CARGO_HOME} CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-<unset>}"
}

_setup_hello_linker_wrapper() {
  HELLO_LINKER_WRAPPER="/tmp/onecrate-linker.sh"
  : >/tmp/onecrate-linker.log
  cat >"${HELLO_LINKER_WRAPPER}" <<'HELLO_LINKER_WRAPPER_SH'
#!/bin/sh
LOG=/tmp/onecrate-linker.log
{
  echo "=== onecrate_linker_invocation_begin pid=$$ ppid=$PPID ==="
  echo "argv: $*"
  echo "LD_LIBRARY_PATH(before)=${LD_LIBRARY_PATH:-<unset>}"
} >>"$LOG"
unset LD_LIBRARY_PATH
echo "LD_LIBRARY_PATH(after)=<unset>" >>"$LOG"
if [ -x /usr/bin/gcc ]; then
  /usr/bin/gcc "$@" >>"$LOG" 2>&1
  ec=$?
  echo "exit=/usr/bin/gcc code=$ec" >>"$LOG"
  exit $ec
fi
if [ -x /usr/bin/cc ]; then
  /usr/bin/cc "$@" >>"$LOG" 2>&1
  ec=$?
  echo "exit=/usr/bin/cc code=$ec" >>"$LOG"
  exit $ec
fi
if [ -x /opt/ccwrap/cc ]; then
  /opt/ccwrap/cc "$@" >>"$LOG" 2>&1
  ec=$?
  echo "exit=/opt/ccwrap/cc code=$ec" >>"$LOG"
  exit $ec
fi
cc "$@" >>"$LOG" 2>&1
ec=$?
echo "exit=cc code=$ec" >>"$LOG"
exit $ec
HELLO_LINKER_WRAPPER_SH
  chmod +x "${HELLO_LINKER_WRAPPER}" 2>/dev/null || true
}

_hello_linker_path() {
  local _use_lld="${GUEST_ONECRATE_HELLO_USE_LLD:-0}"
  local _force="${GUEST_ONECRATE_HELLO_LINKER:-}"
  local _cand=""
  if [[ -n "${_force}" ]] && [[ -x "${_force}" ]]; then
    printf '%s\n' "${_force}"
    return 0
  fi
  if [[ "${_use_lld}" =~ ^(1|true|on|yes)$ ]]; then
    for _cand in \
      "${_RUST_LLD:-}" \
      /opt/alpine-rust/usr/bin/rust-lld \
      /opt/alpine-rust/usr/lib/rustlib/riscv64-alpine-linux-musl/bin/rust-lld \
      /opt/alpine-rust/usr/lib/rustlib/*/bin/rust-lld \
      /root/.rustup/toolchains/*/lib/rustlib/riscv64gc-unknown-linux-gnu/bin/rust-lld \
      /root/.rustup/toolchains/*/lib/rustlib/riscv64-alpine-linux-musl/bin/rust-lld \
      /usr/bin/rust-lld \
      /opt/alpine-rust/usr/bin/ld.lld \
      /usr/bin/ld.lld; do
      if [[ -x "${_cand}" ]]; then
        echo "[onecrate] hello linker: auto-picked ${_cand}" >&2
        printf '%s\n' "${_cand}"
        return 0
      fi
    done
  fi
  if [[ -n "${HELLO_LINKER_WRAPPER:-}" ]] && [[ -x "${HELLO_LINKER_WRAPPER}" ]]; then
    printf '%s\n' "${HELLO_LINKER_WRAPPER}"
    return 0
  fi
  echo "[onecrate] hello linker fallback: rust-lld=$(command -v rust-lld 2>/dev/null || echo none) ld.lld=$(command -v ld.lld 2>/dev/null || echo none) cc=$(command -v cc 2>/dev/null || echo none)" >&2
  printf '%s\n' ""
}

_hello_gcc_lib_search_flags() {
  local _flags=""
  local _d=""
  for _d in \
    /usr/lib/gcc/*/* \
    /lib/gcc/*/* \
    /opt/alpine-rust/usr/lib/gcc/*/* \
    /opt/alpine-rust/lib/gcc/*/* \
    /root/.rustup/toolchains/*/lib/rustlib/riscv64gc-unknown-linux-gnu/lib \
    /root/.rustup/toolchains/*/lib/rustlib/riscv64-alpine-linux-musl/lib; do
    if [[ -d "${_d}" ]]; then
      _flags="${_flags} -C link-arg=-L${_d}"
    fi
  done
  printf '%s\n' "${_flags}"
}

_read_proc_first_total() {
  local _tag="" _value=""
  if read -r _value _rest </proc/syscall_stats_total 2>/dev/null && [[ "${_value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${_value}"
  elif read -r _tag _value _rest </proc/syscall_stats 2>/dev/null && [[ "${_tag}" == "total" ]]; then
    printf '%s\n' "${_value}"
  else
    printf '%s\n' "-"
  fi
}

_dump_proc_file() {
  local _path="$1" _line=""
  [[ -r "${_path}" ]] || return 0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    printf '%s\n' "${_line}"
  done <"${_path}"
}

_dump_cargo_observation() {
  local _pid="${1:-}" _fd="" _target="" _line=""
  [[ -n "${_pid}" ]] || return 0
  echo "--- /proc/${_pid}/status ---"
  _dump_proc_file "/proc/${_pid}/status"
  echo "--- /proc/${_pid}/fd ---"
  if [[ -d "/proc/${_pid}/fd" ]]; then
    for _fd in /proc/"${_pid}"/fd/*; do
      [[ -e "${_fd}" ]] || continue
      _target="$(readlink "${_fd}" 2>/dev/null || true)"
      printf '%s -> %s\n' "${_fd##*/}" "${_target:-?}"
    done
  else
    echo "(fd directory unavailable)"
  fi
  echo "--- /proc/${_pid}/maps ---"
  _dump_proc_file "/proc/${_pid}/maps"
  echo "--- /tmp/guest-onecrate-cargo.log.tail ---"
  if [[ -r /tmp/guest-onecrate-cargo.log ]]; then
    tail -20 /tmp/guest-onecrate-cargo.log 2>/dev/null || true
  else
    echo "(cargo log unavailable)"
  fi
  echo "--- /tmp/onecrate-linker.log.tail ---"
  if [[ -r /tmp/onecrate-linker.log ]]; then
    tail -20 /tmp/onecrate-linker.log 2>/dev/null || true
  else
    echo "(linker log unavailable)"
  fi
}

# M6 selfbuild mode: exec the starry-kernel build script directly
if [[ "${MODE}" == "m6-build" ]]; then
  echo "[onecrate] M6 selfbuild mode: exec /opt/build-starry-kernel.sh"
  echo "===M6_BUILD_BEGIN==="
  export PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin"
  export LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib"
  export CARGO_HOME="/opt/tgoskits/m6-cargo-home"
  export TMPDIR="/opt/tgoskits/.m6-tmp"
  export TMP="/opt/tgoskits/.m6-tmp"
  export TEMP="/opt/tgoskits/.m6-tmp"
  export CC="/opt/ccwrap/cc"
  export CXX="/opt/ccwrap/c++"
  export RUST_MIN_STACK="${RUST_MIN_STACK:-16777216}"
  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
  export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-1}"
  export CARGO_TERM_PROGRESS="wide"
  export CARGO_TERM_VERBOSE="true"
  export CARGO_CACHE_AUTO_CLEAN_FREQUENCY="never"
  if [[ "${GUEST_ONECRATE_NO_SERIAL_RUSTC:-}" != "1" ]]; then
    export RUSTC_BOOTSTRAP=1
  fi
  /bin/mkdir -p "$TMPDIR" "$CARGO_HOME" 2>/dev/null || true
  exec /bin/bash --noprofile --norc /opt/build-starry-kernel.sh
fi

if [[ "${MODE}" == "probe" ]]; then
  echo "[onecrate] probe /opt/fd-pipe-probe"
  set +e
  /opt/fd-pipe-probe >/tmp/guest-onecrate-cargo.log 2>&1
  RC=$?
  cat /tmp/guest-onecrate-cargo.log || true
  set -e
  if [[ "${RC}" -eq 0 ]]; then
    echo "===GUEST_PROBE_PASS==="
  else
    echo "===GUEST_PROBE_FAIL rc=${RC}==="
  fi
  echo "===GUEST_ONECRATE_CHECK_RC ${RC}==="
  echo "===GUEST_ONECRATE_ELAPSED_S 0==="
  echo "===SYSCALL_STATS_AFTER_BEGIN==="
  cat /proc/syscall_stats
  echo "===SYSCALL_STATS_AFTER_END==="
  echo "===GUEST_ONECRATE_END==="
  exit "${RC}"
elif [[ "${MODE}" == "rustc" ]]; then
  echo "[onecrate] rustc /opt/tiny/hello.rs -> /tmp/hello-onecrate (emit=obj; no cargo/fetch/registry; no guest link)"
  # 访客里 ccwrap/clang 链接 pie 会 SIGSEGV；冒烟只验证 rustc 前端+后端到 object，避免依赖系统链接器。
  ulimit -s unlimited 2>/dev/null || true
  T0=$(date +%s)
  _RF_ONECRATE="${_SERIAL_RF} ${RUSTFLAGS:-}"
  env PATH="/usr/bin:/usr/sbin:/bin:/sbin:/opt/alpine-rust/usr/bin" \
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
    RUSTFLAGS="${_RF_ONECRATE}" \
    "${_RUSTC_BIN}" /opt/tiny/hello.rs --emit=obj -o /tmp/hello-onecrate \
      >>/tmp/guest-onecrate-cargo.log 2>&1 &
  CPID=$!
elif [[ "${MODE}" == "cargo-hello" ]]; then
  CARGO_PHASE="${GUEST_ONECRATE_CARGO_PHASE:-metadata}"
  CARGO_TRACE="${GUEST_ONECRATE_CARGO_TRACE:-0}"
  CARGO_VERBOSE="${GUEST_ONECRATE_CARGO_VERBOSE:-0}"
  if [[ "${CARGO_VERBOSE}" =~ ^(1|true|on|yes)$ ]]; then
    CARGO_TRACE=1
    export GUEST_ONECRATE_CARGO_TAIL_SEC="${GUEST_ONECRATE_CARGO_TAIL_SEC:-5}"
  fi
  if [[ "${CARGO_TRACE}" =~ ^(1|true|on|yes)$ ]]; then
    export CARGO_LOG="${CARGO_LOG:-trace}"
    export RUST_LOG="${RUST_LOG:-cargo=trace}"
    echo "[onecrate] cargo trace logs enabled CARGO_LOG=${CARGO_LOG} RUST_LOG=${RUST_LOG}"
  fi
  _GUEST_ONECRATE_RF_DEFAULT="-C debuginfo=0"
  export RUSTFLAGS="${GUEST_ONECRATE_RUSTFLAGS:-${_GUEST_ONECRATE_RF_DEFAULT}} ${_SERIAL_RF} ${RUSTFLAGS:-}"
  T0=$(date +%s)
  case "${CARGO_PHASE}" in
    metadata)
      _setup_hello_crate
      echo "[onecrate] phase=hello-metadata cargo metadata --manifest-path ${HELLO_DIR}/Cargo.toml --offline"
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        CARGO_HOME="$CARGO_HOME" CARGO_TARGET_DIR="$CARGO_TARGET_DIR" RUSTFLAGS="$RUSTFLAGS" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" metadata --manifest-path "${HELLO_DIR}/Cargo.toml" --offline --format-version 1 >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    check|hello-check)
      _setup_tmp_hello_check_crate
      echo "[onecrate] phase=hello-check cargo check --manifest-path ${HELLO_DIR}/Cargo.toml --offline"
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        CARGO_HOME="$CARGO_HOME" RUSTFLAGS="$RUSTFLAGS" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" check --manifest-path "${HELLO_DIR}/Cargo.toml" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    build|hello-build)
      _setup_tmp_hello_bin_crate
      _setup_hello_linker_wrapper
      _HELLO_LINKER="$(_hello_linker_path)"
      _HELLO_RF="${RUSTFLAGS}"
      if [[ -n "${_HELLO_LINKER}" ]]; then
        if [[ "${_HELLO_LINKER}" == *ld.lld || "${_HELLO_LINKER}" == *rust-lld ]]; then
          _HELLO_RF="${_HELLO_RF} -C link-arg=-L/opt/alpine-rust/usr/lib -C link-arg=-L/opt/alpine-rust/lib -C link-arg=-L/usr/lib -C link-arg=-L/lib"
          _HELLO_RF="${_HELLO_RF}$(_hello_gcc_lib_search_flags)"
        fi
        _HELLO_RF="${_HELLO_RF} -C linker=${_HELLO_LINKER}"
        echo "[onecrate] hello linker: ${_HELLO_LINKER}"
      fi
      echo "[onecrate] phase=hello-build cargo build --manifest-path ${HELLO_DIR}/Cargo.toml --offline"
      if [[ -n "${_HELLO_LINKER}" ]]; then
        env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
          CARGO_HOME="$CARGO_HOME" RUSTFLAGS="${_HELLO_RF}" RUSTC_LINKER="${_HELLO_LINKER}" \
          RUSTC="${_RUSTC_BIN}" \
          CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_LINKER="${_HELLO_LINKER}" \
          CARGO_TARGET_RISCV64_UNKNOWN_LINUX_MUSL_LINKER="${_HELLO_LINKER}" \
          "${_CARGO_BIN}" build --manifest-path "${HELLO_DIR}/Cargo.toml" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      else
        env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
          CARGO_HOME="$CARGO_HOME" RUSTFLAGS="${_HELLO_RF}" \
          RUSTC="${_RUSTC_BIN}" \
          "${_CARGO_BIN}" build --manifest-path "${HELLO_DIR}/Cargo.toml" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      fi
      ;;
    run|hello-run)
      _setup_tmp_hello_bin_crate
      _setup_hello_linker_wrapper
      _HELLO_LINKER="$(_hello_linker_path)"
      _HELLO_RF="${RUSTFLAGS}"
      if [[ -n "${_HELLO_LINKER}" ]]; then
        if [[ "${_HELLO_LINKER}" == *ld.lld || "${_HELLO_LINKER}" == *rust-lld ]]; then
          _HELLO_RF="${_HELLO_RF} -C link-arg=-L/opt/alpine-rust/usr/lib -C link-arg=-L/opt/alpine-rust/lib -C link-arg=-L/usr/lib -C link-arg=-L/lib"
          _HELLO_RF="${_HELLO_RF}$(_hello_gcc_lib_search_flags)"
        fi
        _HELLO_RF="${_HELLO_RF} -C linker=${_HELLO_LINKER}"
        echo "[onecrate] hello linker: ${_HELLO_LINKER}"
      fi
      echo "[onecrate] phase=hello-run cargo run --manifest-path ${HELLO_DIR}/Cargo.toml --offline"
      if [[ -n "${_HELLO_LINKER}" ]]; then
        env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
          CARGO_HOME="$CARGO_HOME" RUSTFLAGS="${_HELLO_RF}" RUSTC_LINKER="${_HELLO_LINKER}" \
          RUSTC="${_RUSTC_BIN}" \
          CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_LINKER="${_HELLO_LINKER}" \
          CARGO_TARGET_RISCV64_UNKNOWN_LINUX_MUSL_LINKER="${_HELLO_LINKER}" \
          "${_CARGO_BIN}" run --manifest-path "${HELLO_DIR}/Cargo.toml" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      else
        env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
          CARGO_HOME="$CARGO_HOME" RUSTFLAGS="${_HELLO_RF}" \
          RUSTC="${_RUSTC_BIN}" \
          "${_CARGO_BIN}" run --manifest-path "${HELLO_DIR}/Cargo.toml" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      fi
      ;;
    check-vv)
      _setup_tmp_hello_check_crate
      echo "[onecrate] phase=hello-check-vv cargo check -vv --manifest-path ${HELLO_DIR}/Cargo.toml --offline"
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        CARGO_HOME="$CARGO_HOME" RUSTFLAGS="$RUSTFLAGS" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" check -vv --manifest-path "${HELLO_DIR}/Cargo.toml" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    *)
      echo "===GUEST_ONECRATE_FAIL unknown cargo-hello phase=${CARGO_PHASE}==="
      exit 6
      ;;
  esac
  CPID=$!
elif [[ "${MODE}" == "cargo" ]]; then
  cd /opt/tgoskits
  CARGO_PHASE="${GUEST_ONECRATE_CARGO_PHASE:-check}"
  CARGO_TRACE="${GUEST_ONECRATE_CARGO_TRACE:-0}"
  CARGO_VERBOSE="${GUEST_ONECRATE_CARGO_VERBOSE:-0}"
  if [[ "${CARGO_VERBOSE}" =~ ^(1|true|on|yes)$ ]]; then
    CARGO_TRACE=1
    export GUEST_ONECRATE_CARGO_TAIL_SEC="${GUEST_ONECRATE_CARGO_TAIL_SEC:-5}"
  fi
  if [[ "${CARGO_TRACE}" =~ ^(1|true|on|yes)$ ]]; then
    export CARGO_LOG="${CARGO_LOG:-trace}"
    export RUST_LOG="${RUST_LOG:-cargo=trace}"
    echo "[onecrate] cargo trace logs enabled CARGO_LOG=${CARGO_LOG} RUST_LOG=${RUST_LOG}"
  fi
  # 默认不加完整 debuginfo，减轻 rustc 工作线程栈占用（musl + stack protector 下易触发
  # 「stack smashing」）；需要时 export GUEST_ONECRATE_RUSTFLAGS='-C debuginfo=2' 等覆盖。
  _GUEST_ONECRATE_RF_DEFAULT="-C debuginfo=0"
  export RUSTFLAGS="${GUEST_ONECRATE_RUSTFLAGS:-${_GUEST_ONECRATE_RF_DEFAULT}} ${_SERIAL_RF} ${RUSTFLAGS:-}"
  _mf="/opt/tgoskits/components/axerrno/Cargo.toml"
  if [[ "${ALLOW_FETCH}" == "1" ]]; then
    # 访客内 cargo 可能较旧，不支持 `cargo fetch -p`；用 manifest-path 限定 ax-errno 子树，避免全 workspace fetch 过久。
    if [[ "${CRATE}" != "ax-errno" || ! -f "${_mf}" ]]; then
      echo "===GUEST_ONECRATE_FAIL fetch_needs_manifest_path crate=${CRATE}==="
      exit 5
    fi
    echo "[onecrate] cargo fetch --manifest-path ${_mf} --target ${TARGET} (network; ALLOW_FETCH=1)"
    if ! "${_CARGO_BIN}" fetch --manifest-path "${_mf}" --target "${TARGET}" >>/tmp/guest-onecrate-cargo.log 2>&1; then
      echo "===GUEST_ONECRATE_FAIL cargo_fetch_nonzero==="
      tail -80 /tmp/guest-onecrate-cargo.log 2>/dev/null || true
      exit 4
    fi
  else
    echo "[onecrate] skip cargo fetch (ALLOW_FETCH=${ALLOW_FETCH}; offline-only)"
  fi
  T0=$(date +%s)
  case "${CARGO_PHASE}" in
    check)
      echo "[onecrate] phase=check cargo check -p ${CRATE} --target ${TARGET} --offline"
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" check -p "${CRATE}" --target "${TARGET}" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    check-vv)
      echo "[onecrate] phase=check-vv cargo check -vv -p ${CRATE} --target ${TARGET} --offline"
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" check -vv -p "${CRATE}" --target "${TARGET}" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    metadata)
      echo "[onecrate] phase=metadata cargo metadata --manifest-path ${_mf} --offline"
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" metadata --manifest-path "${_mf}" --offline --format-version 1 >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    locate-project)
      echo "[onecrate] phase=locate-project cargo locate-project --workspace"
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" locate-project --workspace --message-format plain >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    hello-check)
      echo "[onecrate] phase=hello-check create /tmp/onecrate-hello and cargo check --offline"
      /bin/mkdir -p /tmp/onecrate-hello/src 2>/dev/null || true
      printf '[package]\nname = "onecrate-hello"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' >/tmp/onecrate-hello/Cargo.toml
      printf 'fn main() {}\n' >/tmp/onecrate-hello/src/main.rs
      env PATH="$PATH" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
        RUSTC="${_RUSTC_BIN}" \
        "${_CARGO_BIN}" check --manifest-path /tmp/onecrate-hello/Cargo.toml --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
      ;;
    *)
      echo "===GUEST_ONECRATE_FAIL unknown GUEST_ONECRATE_CARGO_PHASE=${CARGO_PHASE}==="
      exit 6
      ;;
  esac
  CPID=$!
else
  echo "===GUEST_ONECRATE_FAIL unknown GUEST_ONECRATE_MODE=${MODE}==="
  exit 3
fi
T0S=${SECONDS:-0}

STATS_DUMP_PID=""
TRACE_SNAPSHOT_PID=""
DEEP_TRACE_PID=""
CARGO_TAIL_PID=""
WAIT_ONLY="${GUEST_ONECRATE_WAIT_ONLY:-0}"
_SYSCALL_IV_RAW="${GUEST_ONECRATE_SYSCALL_STATS_SEC:-5}"
_SYSCALL_IV=5
if [[ "${_SYSCALL_IV_RAW}" == "0" ]]; then
  _SYSCALL_IV=0
elif [[ "${_SYSCALL_IV_RAW}" =~ ^[1-9][0-9]*$ ]]; then
  _SYSCALL_IV="${_SYSCALL_IV_RAW}"
fi
if [[ "${_SYSCALL_IV}" != "0" && "${WAIT_ONLY}" != "1" ]]; then
  _ONECRATE_SYSCALL_PREV="/tmp/.onecrate_syscall_total_prev"
  rm -f "${_ONECRATE_SYSCALL_PREV}"
  (
    while true; do
      sleep "${_SYSCALL_IV}" || true
      if ! kill -0 "${CPID}" 2>/dev/null; then
        break
      fi
      T="$(_read_proc_first_total)"
      t_rel=$(( SECONDS - T0S ))
      delta="-"
      dps="-"
      if [[ "${T}" =~ ^[0-9]+$ ]]; then
        if [[ -f "${_ONECRATE_SYSCALL_PREV}" ]]; then
          read -r _prev <"${_ONECRATE_SYSCALL_PREV}" 2>/dev/null || _prev=""
          if [[ "${_prev}" =~ ^[0-9]+$ ]]; then
            delta=$(( T - _prev ))
            dps="${delta}/${_SYSCALL_IV}"
          fi
        fi
        printf '%s\n' "${T}" >"${_ONECRATE_SYSCALL_PREV}"
      else
        T="-"
      fi
      echo "===ONECRATE_SYSCALL_5S t_rel=${t_rel} total=${T} delta=${delta} dps=${dps}==="
      echo "===ONECRATE_SYSCALL_STATS_BEGIN==="
      _dump_proc_file /proc/syscall_stats
      echo "===ONECRATE_SYSCALL_STATS_END==="
      _dump_proc_file /proc/diagnostic_summary 2>/dev/null || true
    done
  ) &
  STATS_DUMP_PID=$!
fi

_TRACE_SNAPSHOT_RAW="${GUEST_ONECRATE_TRACE_SNAPSHOT_SEC:-0}"
_TRACE_SNAPSHOT_IV=0
if [[ "${_TRACE_SNAPSHOT_RAW}" =~ ^[1-9][0-9]*$ ]]; then
  _TRACE_SNAPSHOT_IV="${_TRACE_SNAPSHOT_RAW}"
fi
if [[ "${_TRACE_SNAPSHOT_IV}" != "0" && "${WAIT_ONLY}" != "1" ]]; then
  if test -w /proc/syscall_trace_snapshot 2>/dev/null; then
    echo 1 >/proc/syscall_trace_snapshot || true
    echo "[onecrate] trace snapshot: enabled every ${_TRACE_SNAPSHOT_IV}s"
    (
      while true; do
        sleep "${_TRACE_SNAPSHOT_IV}" || true
        if ! kill -0 "${CPID}" 2>/dev/null; then
          break
        fi
        t_rel=$(( SECONDS - T0S ))
        echo "===ONECRATE_TRACE_SNAPSHOT_BEGIN t_rel=${t_rel}==="
        echo "--- /proc/syscall_inflight ---"
        _dump_proc_file /proc/syscall_inflight
        echo "--- /proc/syscall_trace_recent ---"
        _dump_proc_file /proc/syscall_trace_recent
        if [[ "${GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS:-0}" != "1" ]]; then
          echo "--- /proc/task_snapshot ---"
          _dump_proc_file /proc/task_snapshot
          echo "--- /proc/tasks ---"
          _dump_proc_file /proc/tasks
        fi
        if _is_cargo_like; then
          _dump_cargo_observation "${CPID}"
        fi
        echo "--- /proc/syscall_stats_total ---"
        _dump_proc_file /proc/syscall_stats_total
        echo "===ONECRATE_TRACE_SNAPSHOT_END==="
      done
    ) &
    TRACE_SNAPSHOT_PID=$!
  else
    echo "[onecrate] trace snapshot: /proc/syscall_trace_snapshot not writable (need newer kernel)"
  fi
fi

_DEEP_TRACE_RAW="${GUEST_ONECRATE_DEEP_TRACE_SEC:-0}"
_DEEP_TRACE_IV=0
if [[ "${_DEEP_TRACE_RAW}" =~ ^[1-9][0-9]*$ ]]; then
  _DEEP_TRACE_IV="${_DEEP_TRACE_RAW}"
fi
if [[ "${_DEEP_TRACE_IV}" != "0" ]]; then
  if test -w /proc/syscall_deep_trace 2>/dev/null; then
    echo 1 >/proc/syscall_deep_trace || true
    echo "[onecrate] deep trace: enabled every ${_DEEP_TRACE_IV}s"
    if [[ "${WAIT_ONLY}" == "1" ]]; then
      echo "[onecrate] wait-only: deep trace uses kernel timer samples; no guest sleep dump loop"
    else
      (
        while true; do
          sleep "${_DEEP_TRACE_IV}" || true
          if ! kill -0 "${CPID}" 2>/dev/null; then
            break
          fi
          t_rel=$(( SECONDS - T0S ))
          echo "===ONECRATE_DEEP_TRACE_BEGIN t_rel=${t_rel}==="
          echo "--- /proc/deep_trace_recent ---"
          _dump_proc_file /proc/deep_trace_recent
          echo "--- /proc/task_block_snapshot ---"
          _dump_proc_file /proc/task_block_snapshot
          echo "--- /proc/syscall_inflight ---"
          _dump_proc_file /proc/syscall_inflight
          echo "--- /proc/syscall_trace_recent ---"
          _dump_proc_file /proc/syscall_trace_recent
          echo "--- /proc/task_snapshot ---"
          if [[ "${GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS:-0}" != "1" ]]; then
            _dump_proc_file /proc/task_snapshot
          else
            echo "(skipped by GUEST_ONECRATE_TRACE_SNAPSHOT_SKIP_TASKS=1)"
          fi
          if _is_cargo_like; then
            _dump_cargo_observation "${CPID}"
          fi
          echo "===ONECRATE_DEEP_TRACE_END==="
        done
      ) &
      DEEP_TRACE_PID=$!
    fi
  else
    echo "[onecrate] deep trace: /proc/syscall_deep_trace not writable (need newer kernel)"
  fi
fi

_CARGO_TAIL_RAW="${GUEST_ONECRATE_CARGO_TAIL_SEC:-0}"
_CARGO_TAIL_IV=0
if _is_cargo_like && [[ "${_CARGO_TAIL_RAW}" =~ ^[1-9][0-9]*$ ]]; then
  _CARGO_TAIL_IV="${_CARGO_TAIL_RAW}"
fi
if [[ "${_CARGO_TAIL_IV}" != "0" ]]; then
  echo "[onecrate] cargo tail: serial echo every ${_CARGO_TAIL_IV}s"
  (
    while true; do
      sleep "${_CARGO_TAIL_IV}" || true
      if ! kill -0 "${CPID}" 2>/dev/null; then
        break
      fi
      t_rel=$(( SECONDS - T0S ))
      echo "===ONECRATE_CARGO_LOG_TAIL_BEGIN t_rel=${t_rel}==="
      if [[ -s /tmp/guest-onecrate-cargo.log ]]; then
        tail -20 /tmp/guest-onecrate-cargo.log 2>/dev/null || true
      else
        echo "(cargo log empty)"
      fi
      echo "===ONECRATE_CARGO_LOG_TAIL_END==="
    done
  ) &
  CARGO_TAIL_PID=$!
fi

PROGRESS_SEC="${GUEST_ONECRATE_PROGRESS_SEC:-300}"
LAST_PE=0
DEVLOG_SEC_RAW="${GUEST_ONECRATE_DEVLOG_SEC:-0}"
DEVLOG_SEC=0
if _is_cargo_like && [[ "${DEVLOG_SEC_RAW}" =~ ^[1-9][0-9]*$ ]]; then
  DEVLOG_SEC="${DEVLOG_SEC_RAW}"
fi
# 首次打 /dev/log 不早于 cargo 已跑满 DEVLOG_SEC 秒，之后严格每 DEVLOG_SEC 秒一条。
LAST_DEVLOG_FIRE=-1
_what="cargo check"
[[ "${MODE}" == "rustc" ]] && _what="rustc"
if _is_cargo_like; then
  _what="cargo ${CARGO_PHASE:-check}"
fi

if _is_cargo_like && [[ "${DEVLOG_SEC}" -gt 0 ]]; then
  echo "[onecrate] devlog: logger -> /dev/log every ${DEVLOG_SEC}s (last line of /tmp/guest-onecrate-cargo.log; skill starry-userspace-log)"
fi

if [[ "${WAIT_ONLY}" == "1" ]]; then
  echo "[onecrate] wait-only: waiting for ${_what} pid=${CPID} without guest sleep polling"
else
  while kill -0 "${CPID}" 2>/dev/null; do
    _w=$(( SECONDS - T0S ))
    if _is_cargo_like && [[ "${DEVLOG_SEC}" -gt 0 ]]; then
      _fire=0
      if (( LAST_DEVLOG_FIRE < 0 )); then
        (( _w >= DEVLOG_SEC )) && _fire=1
      elif (( _w - LAST_DEVLOG_FIRE >= DEVLOG_SEC )); then
        _fire=1
      fi
      if (( _fire )); then
        LAST_DEVLOG_FIRE=${_w}
        if command -v logger >/dev/null 2>&1 && [[ -r /tmp/guest-onecrate-cargo.log ]]; then
          _cl="$(tail -1 /tmp/guest-onecrate-cargo.log 2>/dev/null | tr '\r' ' ' | cut -c1-220)"
          if [[ -n "${_cl// /}" ]]; then
            logger -t onecrate-cargo "${_cl}" 2>/dev/null || true
          fi
        fi
      fi
    fi
    if [[ "${PROGRESS_SEC}" != "0" ]] && (( _w - LAST_PE >= PROGRESS_SEC )); then
      echo "[onecrate] still running ${_what} pid=${CPID} elapsed=${_w}s wall_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      LAST_PE=${_w}
    fi
    _tot="?"
    if [ -r /proc/syscall_stats ]; then
      _tot="$(_read_proc_first_total)"
    fi
    echo "===ONECRATE_SYSCALL_SAMPLE rel_s=${_w} total=${_tot}"
    sleep "${SLEEP_SEC}"
  done
fi
if [[ -n "${STATS_DUMP_PID:-}" ]]; then
  kill "${STATS_DUMP_PID}" 2>/dev/null || true
  wait "${STATS_DUMP_PID}" 2>/dev/null || true
fi
if [[ -n "${TRACE_SNAPSHOT_PID:-}" ]]; then
  kill "${TRACE_SNAPSHOT_PID}" 2>/dev/null || true
  wait "${TRACE_SNAPSHOT_PID}" 2>/dev/null || true
fi
if [[ -n "${DEEP_TRACE_PID:-}" ]]; then
  kill "${DEEP_TRACE_PID}" 2>/dev/null || true
  wait "${DEEP_TRACE_PID}" 2>/dev/null || true
fi
if [[ -n "${CARGO_TAIL_PID:-}" ]]; then
  kill "${CARGO_TAIL_PID}" 2>/dev/null || true
  wait "${CARGO_TAIL_PID}" 2>/dev/null || true
fi
set +e
wait "${CPID}"
RC=$?
set -e
EL=$(( SECONDS - T0S ))
echo "===GUEST_ONECRATE_CHECK_RC ${RC}==="
echo "===GUEST_ONECRATE_ELAPSED_S ${EL}==="
if [[ "${TRACE_SYSCALLS_ENABLED}" == "1" ]] && test -w /proc/syscall_trace 2>/dev/null; then
  echo 0 >/proc/syscall_trace || true
  echo "[onecrate] syscall trace: disabled"
fi
if [[ "${_TRACE_SNAPSHOT_IV}" != "0" ]] && test -w /proc/syscall_trace_snapshot 2>/dev/null; then
  echo 0 >/proc/syscall_trace_snapshot || true
  echo "[onecrate] trace snapshot: disabled"
fi
if [[ "${_DEEP_TRACE_IV}" != "0" ]] && test -w /proc/syscall_deep_trace 2>/dev/null; then
  echo 0 >/proc/syscall_deep_trace || true
  echo "[onecrate] deep trace: disabled"
fi
if [[ "${RC}" -ne 0 ]]; then
  echo "===GUEST_ONECRATE_CARGO_LOG_TAIL_BEGIN==="
  tail -80 /tmp/guest-onecrate-cargo.log 2>/dev/null || true
  echo "===GUEST_ONECRATE_CARGO_LOG_TAIL_END==="
fi
echo "===SYSCALL_STATS_AFTER_BEGIN==="
cat /proc/syscall_stats
echo "===SYSCALL_STATS_AFTER_END==="
echo "===DIAGNOSTIC_SUMMARY_BEGIN==="
cat /proc/diagnostic_summary 2>/dev/null || echo "(diagnostic_summary unavailable)"
echo "===DIAGNOSTIC_SUMMARY_END==="
echo "===SYSCALL_ERROR_STATS_BEGIN==="
cat /proc/syscall_error_stats 2>/dev/null || echo "(syscall_error_stats unavailable)"
echo "===SYSCALL_ERROR_STATS_END==="
echo "===PAGE_FAULT_STATS_BEGIN==="
cat /proc/page_fault_stats 2>/dev/null || echo "(page_fault_stats unavailable)"
echo "===PAGE_FAULT_STATS_END==="
echo "===SIGNAL_STATS_BEGIN==="
cat /proc/signal_stats 2>/dev/null || echo "(signal_stats unavailable)"
echo "===SIGNAL_STATS_END==="
echo "===SYSCALL_LATENCY_BEGIN==="
cat /proc/syscall_latency_stats 2>/dev/null || echo "(latency unavailable)"
echo "===SYSCALL_LATENCY_END==="
echo "===GUEST_ONECRATE_END==="
exit "${RC}"
