#!/bin/bash
# 由 guest-onecrate-syscall-evidence.sh 拷入 rootfs /opt/；init 通过 /opt/run-tests.sh 调用。
#
# 环境变量（run-tests 设置）：
#   GUEST_ONECRATE_MODE=cargo|rustc  — 默认 cargo；rustc=仅编 /opt/tiny/hello.rs（无 cargo、无 registry）
#   GUEST_ONECRATE_ALLOW_FETCH=0|1 — 默认 0：不跑 cargo fetch（控制变量：不依赖网络）
#   GUEST_ONECRATE_CRATE / GUEST_ONECRATE_TARGET / GUEST_ONECRATE_SAMPLE_SLEEP — 仅 cargo 模式用
set -eo pipefail
ulimit -s unlimited 2>/dev/null || true
MODE="${GUEST_ONECRATE_MODE:-cargo}"
ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH:-0}"
CRATE="${GUEST_ONECRATE_CRATE:-ax-errno}"
TARGET="${GUEST_ONECRATE_TARGET:-riscv64gc-unknown-none-elf}"
SLEEP_SEC="${GUEST_ONECRATE_SAMPLE_SLEEP:-0.5}"

echo "===GUEST_ONECRATE_BEGIN mode=${MODE} crate=${CRATE} target=${TARGET} allow_fetch=${ALLOW_FETCH}==="
date -u

if ! test -w /proc/syscall_stats_reset 2>/dev/null; then
  echo "===GUEST_ONECRATE_FAIL no /proc/syscall_stats_reset==="
  exit 2
fi
echo x >/proc/syscall_stats_reset

export PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin"
export LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib"
export SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp
export TMPDIR=/opt/tgoskits/.m6-tmp
export TMP=/opt/tgoskits/.m6-tmp
export TEMP=/opt/tgoskits/.m6-tmp
/bin/mkdir -p "$TMPDIR" /opt/tgoskits/m6-cargo-home/registry 2>/dev/null || true
export CARGO_HOME="${CARGO_HOME:-/opt/tgoskits/m6-cargo-home}"
export CC="${CC:-/opt/ccwrap/cc}"
export CXX="${CXX:-/opt/ccwrap/c++}"
export RUST_MIN_STACK="${RUST_MIN_STACK:-16777216}"
_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-$_NPROC}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_NPROC}"
export CARGO_TERM_PROGRESS="${CARGO_TERM_PROGRESS:-wide}"
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-true}"

: >/tmp/guest-onecrate-cargo.log

if [[ "${MODE}" == "rustc" ]]; then
  echo "[onecrate] rustc /opt/tiny/hello.rs -> /tmp/hello-onecrate (emit=obj; no cargo/fetch/registry; no guest link)"
  # 访客里 ccwrap/clang 链接 pie 会 SIGSEGV；冒烟只验证 rustc 前端+后端到 object，避免依赖系统链接器。
  ulimit -s unlimited 2>/dev/null || true
  T0=$(date +%s)
  _RF_ONECRATE="${RUSTFLAGS:-}"
  env PATH="/usr/bin:/usr/sbin:/bin:/sbin:/opt/alpine-rust/usr/bin" \
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
    RUSTFLAGS="${_RF_ONECRATE}" \
    /opt/alpine-rust/usr/bin/rustc /opt/tiny/hello.rs --emit=obj -o /tmp/hello-onecrate \
      >>/tmp/guest-onecrate-cargo.log 2>&1 &
  CPID=$!
elif [[ "${MODE}" == "cargo" ]]; then
  cd /opt/tgoskits
  # 默认不加完整 debuginfo，减轻 rustc 工作线程栈占用（musl + stack protector 下易触发
  # 「stack smashing」）；需要时 export GUEST_ONECRATE_RUSTFLAGS='-C debuginfo=2' 等覆盖。
  _GUEST_ONECRATE_RF_DEFAULT="-C debuginfo=0"
  export RUSTFLAGS="${GUEST_ONECRATE_RUSTFLAGS:-${_GUEST_ONECRATE_RF_DEFAULT}} ${RUSTFLAGS:-}"
  if [[ "${ALLOW_FETCH}" == "1" ]]; then
    # 访客内 cargo 可能较旧，不支持 `cargo fetch -p`；用 manifest-path 限定 ax-errno 子树，避免全 workspace fetch 过久。
    _mf="/opt/tgoskits/components/axerrno/Cargo.toml"
    if [[ "${CRATE}" != "ax-errno" || ! -f "${_mf}" ]]; then
      echo "===GUEST_ONECRATE_FAIL fetch_needs_manifest_path crate=${CRATE}==="
      exit 5
    fi
    echo "[onecrate] cargo fetch --manifest-path ${_mf} --target ${TARGET} (network; ALLOW_FETCH=1)"
    if ! /opt/alpine-rust/usr/bin/cargo fetch --manifest-path "${_mf}" --target "${TARGET}" >>/tmp/guest-onecrate-cargo.log 2>&1; then
      echo "===GUEST_ONECRATE_FAIL cargo_fetch_nonzero==="
      tail -80 /tmp/guest-onecrate-cargo.log 2>/dev/null || true
      exit 4
    fi
  else
    echo "[onecrate] skip cargo fetch (ALLOW_FETCH=${ALLOW_FETCH}; offline-only)"
  fi
  T0=$(date +%s)
  echo "[onecrate] cargo check -p ${CRATE} --target ${TARGET} --offline (sampled)"
  env PATH="$PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
    /opt/alpine-rust/usr/bin/cargo check -p "${CRATE}" --target "${TARGET}" --offline >>/tmp/guest-onecrate-cargo.log 2>&1 &
  CPID=$!
else
  echo "===GUEST_ONECRATE_FAIL unknown GUEST_ONECRATE_MODE=${MODE}==="
  exit 3
fi

while kill -0 "${CPID}" 2>/dev/null; do
  _w=$(( $(date +%s) - T0 ))
  _tot="?"
  if [ -r /proc/syscall_stats ]; then
    _tot="$(head -1 /proc/syscall_stats 2>/dev/null | awk '{print $2}')"
  fi
  echo "===ONECRATE_SYSCALL_SAMPLE rel_s=${_w} total=${_tot}"
  sleep "${SLEEP_SEC}"
done
set +e
wait "${CPID}"
RC=$?
set -e
T1=$(date +%s)
EL=$((T1 - T0))
echo "===GUEST_ONECRATE_CHECK_RC ${RC}==="
echo "===GUEST_ONECRATE_ELAPSED_S ${EL}==="
if [[ "${RC}" -ne 0 ]]; then
  echo "===GUEST_ONECRATE_CARGO_LOG_TAIL_BEGIN==="
  tail -80 /tmp/guest-onecrate-cargo.log 2>/dev/null || true
  echo "===GUEST_ONECRATE_CARGO_LOG_TAIL_END==="
fi
echo "===SYSCALL_STATS_AFTER_BEGIN==="
cat /proc/syscall_stats
echo "===SYSCALL_STATS_AFTER_END==="
echo "===GUEST_ONECRATE_END==="
exit "${RC}"
