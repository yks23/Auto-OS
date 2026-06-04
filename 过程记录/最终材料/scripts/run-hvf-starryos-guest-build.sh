#!/usr/bin/env bash
set -euo pipefail

case_name="${CASE_NAME:?set CASE_NAME, e.g. smp8-j8-debug-tmp}"
profile="${PROFILE:-debug}"
jobs="${JOBS:-8}"
smp="${SMP:-8}"
kernel="${KERNEL:?set KERNEL path}"
img="${IMG:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"
mem="${MEM:-4096M}"
source_tmpfs="${SOURCE_TMPFS:-0}"
log_dir="${LOG_DIR:-/Users/txc/code/Auto-OS/过程记录/最终材料/logs}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
target_dir="${TARGET_DIR:-/tmp/target-hvf-${case_name}-${stamp}}"
work_dir="${WORK_DIR:-/tmp/src-hvf-${case_name}-${stamp}}"
log="${LOG:-${log_dir}/hvf-aarch64-starryos-${case_name}-${stamp}.log}"
dry_run="${DRY_RUN:-0}"
profile_release_lto="${CARGO_PROFILE_RELEASE_LTO:-}"
profile_release_codegen_units="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-}"
profile_release_debug="${CARGO_PROFILE_RELEASE_DEBUG:-}"
profile_release_opt_level="${CARGO_PROFILE_RELEASE_OPT_LEVEL:-}"
profile_release_panic="${CARGO_PROFILE_RELEASE_PANIC:-}"
profile_release_overflow_checks="${CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS:-}"
profile_release_debug_assertions="${CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS:-}"
profile_release_strip="${CARGO_PROFILE_RELEASE_STRIP:-}"
profile_release_build_override_opt_level="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OPT_LEVEL:-}"
profile_release_build_override_codegen_units="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_CODEGEN_UNITS:-}"
profile_release_build_override_debug="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG:-}"
profile_release_build_override_incremental="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_INCREMENTAL:-}"
profile_release_build_override_overflow_checks="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OVERFLOW_CHECKS:-}"
profile_release_build_override_debug_assertions="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG_ASSERTIONS:-}"
profile_dev_lto="${CARGO_PROFILE_DEV_LTO:-}"
profile_dev_codegen_units="${CARGO_PROFILE_DEV_CODEGEN_UNITS:-}"
profile_dev_debug="${CARGO_PROFILE_DEV_DEBUG:-}"
profile_dev_opt_level="${CARGO_PROFILE_DEV_OPT_LEVEL:-}"
profile_dev_panic="${CARGO_PROFILE_DEV_PANIC:-}"
profile_dev_overflow_checks="${CARGO_PROFILE_DEV_OVERFLOW_CHECKS:-}"
profile_dev_debug_assertions="${CARGO_PROFILE_DEV_DEBUG_ASSERTIONS:-}"
profile_dev_strip="${CARGO_PROFILE_DEV_STRIP:-}"
profile_term_progress_when="${CARGO_TERM_PROGRESS_WHEN:-}"
cargo_quiet="${CARGO_QUIET:-0}"
rustc_timing="${RUSTC_TIMING:-0}"
fast_alloc_slab_only="${FAST_ALLOC_SLAB_ONLY:-0}"
fast_selfbuild_no_dynamic_debug="${FAST_SELFBUILD_NO_DYNAMIC_DEBUG:-0}"
fast_selfbuild_display_gating="${FAST_SELFBUILD_DISPLAY_GATING:-0}"
fast_selfbuild_netng_delegacy="${FAST_SELFBUILD_NETNG_DELEGACY:-0}"
guest_proc_monitor="${GUEST_PROC_MONITOR:-0}"
guest_proc_monitor_interval="${GUEST_PROC_MONITOR_INTERVAL:-30}"
guest_cpu_monitor="${GUEST_CPU_MONITOR:-0}"
guest_cpu_monitor_interval="${GUEST_CPU_MONITOR_INTERVAL:-5}"
host_cpu_monitor="${HOST_CPU_MONITOR:-0}"
host_cpu_monitor_interval="${HOST_CPU_MONITOR_INTERVAL:-1}"
host_cpu_csv="${HOST_CPU_CSV:-${log%.log}.hostcpu.csv}"
host_heartbeat_interval="${HOST_HEARTBEAT_INTERVAL:-0}"
features="${FEATURES-qemu,gic-v3,cntv-timer,smp}"
no_default_features="${NO_DEFAULT_FEATURES:-0}"
timestamp_cargo="${TIMESTAMP_CARGO:-0}"
prebuild_std="${PREBUILD_STD:-0}"
stdwarm_only="${STDWARM_ONLY:-0}"
cargo_message_format="${CARGO_MESSAGE_FORMAT:-}"
cargo_timings="${CARGO_TIMINGS:-0}"
cargo_subcommand="${CARGO_SUBCOMMAND:-build}"
build_package="${BUILD_PACKAGE-starryos}"
build_bin="${BUILD_BIN-starryos}"
build_target="${BUILD_TARGET-aarch64-unknown-none-softfloat}"
build_std="${BUILD_STD-core,alloc,compiler_builtins}"
build_std_features="${BUILD_STD_FEATURES:-}"
if [ "$profile" = "release" ]; then
  marker="STARRYOS-BUILD"
  cargo_profile_arg="--release"
else
  marker="STARRYOS-DEBUG-BUILD"
  cargo_profile_arg=""
fi
if [ "$cargo_quiet" = "1" ]; then
  cargo_quiet_arg="-q"
else
  cargo_quiet_arg=""
fi

mkdir -p "$log_dir" /tmp/auto-os-hvf

guest_auto="/tmp/auto-os-hvf/hvf-auto-${case_name}-${stamp}.sh"
cat >"$guest_auto" <<EOF
#!/bin/sh
set -u
finish_guest() {
  rc="\$1"
  echo "===HVF-${case_name}-RUN-END rc=\$rc==="
  sync 2>/dev/null || true
  if command -v poweroff >/dev/null 2>&1; then
    poweroff -f 2>/dev/null || poweroff 2>/dev/null || true
  elif command -v halt >/dev/null 2>&1; then
    halt -f 2>/dev/null || halt 2>/dev/null || true
  fi
  exit "\$rc"
}
export CARGO_BUILD_JOBS=$jobs
export RAYON_NUM_THREADS=$jobs
export TMPDIR=/tmp
export CARGO_TARGET_DIR=$target_dir
echo "===HVF-${case_name}-RUN-BEGIN==="
if [ "$source_tmpfs" = "1" ]; then
  WORK_DIR="$work_dir"
  echo "===HVF-SOURCE-TMPFS-COPY-BEGIN work_dir=\$WORK_DIR==="
  rm -rf "\$WORK_DIR"
  mkdir -p "\$WORK_DIR"
  for p in Cargo.toml Cargo.lock rust-toolchain.toml .cargo components os apps drivers platform scripts tools xtask test-suit vendor; do
    if [ -e "/opt/tgoskits/\$p" ]; then
      cp -a "/opt/tgoskits/\$p" "\$WORK_DIR/"
    fi
  done
  if [ -f "\$WORK_DIR/.cargo/config.toml" ]; then
    sed -i "s#/opt/tgoskits/vendor#\$WORK_DIR/vendor#g" "\$WORK_DIR/.cargo/config.toml"
  fi
  if [ "$fast_alloc_slab_only" = "1" ]; then
    axalloc_toml="\$WORK_DIR/os/arceos/modules/axalloc/Cargo.toml"
    if [ -f "\$axalloc_toml" ]; then
      sed -i 's/default = \["tlsf", "ax-allocator\\/page-alloc-4g"\]/default = ["slab", "ax-allocator\\/page-alloc-4g"]/g' "\$axalloc_toml"
      sed -i '/^[[:space:]]*"tlsf",[[:space:]]*$/d' "\$axalloc_toml"
      echo "===HVF-FAST-ALLOC-SLAB-ONLY==="
    fi
  fi
  if [ "$fast_selfbuild_no_dynamic_debug" = "1" ]; then
    starryos_toml="\$WORK_DIR/os/StarryOS/starryos/Cargo.toml"
    if [ -f "\$starryos_toml" ]; then
      sed -i 's#starry-kernel = { workspace = true, features = \\["dev-log", "ext4"\\] }#starry-kernel = { version = "0.5.12", path = "../kernel", default-features = false, features = ["dev-log", "ext4"] }#g' "\$starryos_toml"
      echo "===HVF-FAST-SELFBUILD-NO-DYNAMIC-DEBUG==="
    fi
  fi
  if [ "$fast_selfbuild_display_gating" = "1" ]; then
    starryos_toml="\$WORK_DIR/os/StarryOS/starryos/Cargo.toml"
    kernel_toml="\$WORK_DIR/os/StarryOS/kernel/Cargo.toml"
    dev_mod="\$WORK_DIR/os/StarryOS/kernel/src/pseudofs/dev/mod.rs"
    if [ -f "\$kernel_toml" ] && [ -f "\$starryos_toml" ] && [ -f "\$dev_mod" ]; then
      grep -q '^display = \["dep:ax-display"\]$' "\$kernel_toml" || \
        sed -i '/^dev-log = \[\]$/a display = ["dep:ax-display"]' "\$kernel_toml"
      sed -i 's/^ax-display\.workspace = true$/ax-display = { workspace = true, optional = true }/' "\$kernel_toml"
      grep -q '"starry-kernel/display",' "\$starryos_toml" || \
        sed -i '/"ax-feat\/display",/a \  "starry-kernel/display",' "\$starryos_toml"

      sed -i '/^mod card0;$/i #[cfg(feature = "display")]' "\$dev_mod"
      sed -i '/^mod drm;$/i #[cfg(feature = "display")]' "\$dev_mod"
      sed -i '/^mod fb;$/i #[cfg(feature = "display")]' "\$dev_mod"
      sed -i '/^    if ax_display::has_display() {$/i \    #[cfg(feature = "display")]' "\$dev_mod"
      sed -i '/^    let dri_card0 = card0::Card0::new();$/i \    #[cfg(feature = "display")]' "\$dev_mod"
      sed -i '/^    let mut dri_dir = DirMapping::new();$/i \    #[cfg(feature = "display")]' "\$dev_mod"
      sed -i '/^    dri_dir.add($/i \    #[cfg(feature = "display")]' "\$dev_mod"
      sed -i 's/^    #\[cfg(all(feature = "rknpu", not(any(windows, unix))))\]$/    #[cfg(all(feature = "display", feature = "rknpu", not(any(windows, unix))))]/' "\$dev_mod"
      sed -i '/^    root.add("dri", SimpleDir::new_maker(fs.clone(), Arc::new(dri_dir)));$/i \    #[cfg(feature = "display")]' "\$dev_mod"

      if grep -q '^display = \["dep:ax-display"\]$' "\$kernel_toml" && \
        grep -q '^ax-display = { workspace = true, optional = true }$' "\$kernel_toml" && \
        grep -q '#\[cfg(feature = "display")\]' "\$dev_mod"; then
        echo "===HVF-FAST-SELFBUILD-DISPLAY-GATING==="
      else
        echo "===HVF-FAST-SELFBUILD-DISPLAY-GATING-FAIL==="
        finish_guest 125
      fi
    fi
  fi
  if [ "$fast_selfbuild_netng_delegacy" = "1" ]; then
    axfeat_toml="\$WORK_DIR/os/arceos/api/axfeat/Cargo.toml"
    if [ -f "\$axfeat_toml" ]; then
      sed -i 's#^net-ng = \["net", "irq", "multitask", "ax-runtime/net-ng"\]\$#net-ng = ["alloc", "paging", "ax-driver/virtio-net", "irq", "multitask", "ax-runtime/net-ng"]#' "\$axfeat_toml"
      if grep -q '^net-ng = \["alloc", "paging", "ax-driver/virtio-net", "irq", "multitask", "ax-runtime/net-ng"\]$' "\$axfeat_toml"; then
        echo "===HVF-FAST-SELFBUILD-NETNG-DELEGACY==="
      else
        echo "===HVF-FAST-SELFBUILD-NETNG-DELEGACY-FAIL==="
        finish_guest 126
      fi
    fi
  fi
  echo "===HVF-SOURCE-TMPFS-COPY-END==="
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/rust-nightly/bin"
  export LD_LIBRARY_PATH="/usr/lib:/opt/rust-nightly/lib:\${LD_LIBRARY_PATH:-}"
  if [ "$rustc_timing" = "1" ]; then
    echo "===RUSTC-TIMING-DISABLED reason=wrapper-breaks-cargo-rustc-vV==="
  fi
  export RUSTC="/opt/rustc-nightly-sysroot"
  export RUSTDOC="/opt/rustdoc-nightly-sysroot"
  export RUSTC_BOOTSTRAP=1
  export CARGO_INCREMENTAL=0
  export CARGO_NET_OFFLINE=true
  if [ -n "$profile_release_lto" ]; then
    export CARGO_PROFILE_RELEASE_LTO="$profile_release_lto"
  fi
  if [ -n "$profile_release_codegen_units" ]; then
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="$profile_release_codegen_units"
  fi
  if [ -n "$profile_release_debug" ]; then
    export CARGO_PROFILE_RELEASE_DEBUG="$profile_release_debug"
  fi
  if [ -n "$profile_release_opt_level" ]; then
    export CARGO_PROFILE_RELEASE_OPT_LEVEL="$profile_release_opt_level"
  fi
  if [ -n "$profile_release_panic" ]; then
    export CARGO_PROFILE_RELEASE_PANIC="$profile_release_panic"
  fi
  if [ -n "$profile_release_overflow_checks" ]; then
    export CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS="$profile_release_overflow_checks"
  fi
  if [ -n "$profile_release_debug_assertions" ]; then
    export CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS="$profile_release_debug_assertions"
  fi
  if [ -n "$profile_release_strip" ]; then
    export CARGO_PROFILE_RELEASE_STRIP="$profile_release_strip"
  fi
  if [ -n "$profile_release_build_override_opt_level" ]; then
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OPT_LEVEL="$profile_release_build_override_opt_level"
  fi
  if [ -n "$profile_release_build_override_codegen_units" ]; then
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_CODEGEN_UNITS="$profile_release_build_override_codegen_units"
  fi
  if [ -n "$profile_release_build_override_debug" ]; then
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG="$profile_release_build_override_debug"
  fi
  if [ -n "$profile_release_build_override_incremental" ]; then
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_INCREMENTAL="$profile_release_build_override_incremental"
  fi
  if [ -n "$profile_release_build_override_overflow_checks" ]; then
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OVERFLOW_CHECKS="$profile_release_build_override_overflow_checks"
  fi
  if [ -n "$profile_release_build_override_debug_assertions" ]; then
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG_ASSERTIONS="$profile_release_build_override_debug_assertions"
  fi
  if [ -n "$profile_dev_lto" ]; then
    export CARGO_PROFILE_DEV_LTO="$profile_dev_lto"
  fi
  if [ -n "$profile_dev_codegen_units" ]; then
    export CARGO_PROFILE_DEV_CODEGEN_UNITS="$profile_dev_codegen_units"
  fi
  if [ -n "$profile_dev_debug" ]; then
    export CARGO_PROFILE_DEV_DEBUG="$profile_dev_debug"
  fi
  if [ -n "$profile_dev_opt_level" ]; then
    export CARGO_PROFILE_DEV_OPT_LEVEL="$profile_dev_opt_level"
  fi
  if [ -n "$profile_dev_panic" ]; then
    export CARGO_PROFILE_DEV_PANIC="$profile_dev_panic"
  fi
  if [ -n "$profile_dev_overflow_checks" ]; then
    export CARGO_PROFILE_DEV_OVERFLOW_CHECKS="$profile_dev_overflow_checks"
  fi
  if [ -n "$profile_dev_debug_assertions" ]; then
    export CARGO_PROFILE_DEV_DEBUG_ASSERTIONS="$profile_dev_debug_assertions"
  fi
  if [ -n "$profile_dev_strip" ]; then
    export CARGO_PROFILE_DEV_STRIP="$profile_dev_strip"
  fi
  if [ -n "$profile_term_progress_when" ]; then
    export CARGO_TERM_PROGRESS_WHEN="$profile_term_progress_when"
  fi
  export AX_CONFIG_PATH="\$WORK_DIR/os/StarryOS/.axconfig.toml"
  export RUSTFLAGS="\${EXTRA_RUSTFLAGS:-} -Clink-arg=-Tlinker.x -Clink-arg=-no-pie -Clink-arg=-znostart-stop-gc"
  mkdir -p "$target_dir"
  echo "===$marker-ENV-BEGIN==="
  echo "jobs=$jobs"
  echo "target_dir=$target_dir"
  echo "work_dir=\$WORK_DIR"
  echo "source_tmpfs=1"
  echo "release_lto=\${CARGO_PROFILE_RELEASE_LTO:-workspace-default}"
  echo "release_codegen_units=\${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-workspace-default}"
  echo "release_debug=\${CARGO_PROFILE_RELEASE_DEBUG:-workspace-default}"
  echo "release_opt_level=\${CARGO_PROFILE_RELEASE_OPT_LEVEL:-workspace-default}"
  echo "release_panic=\${CARGO_PROFILE_RELEASE_PANIC:-workspace-default}"
  echo "release_overflow_checks=\${CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS:-workspace-default}"
  echo "release_debug_assertions=\${CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS:-workspace-default}"
  echo "release_strip=\${CARGO_PROFILE_RELEASE_STRIP:-workspace-default}"
  echo "release_build_override_opt_level=\${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OPT_LEVEL:-workspace-default}"
  echo "release_build_override_codegen_units=\${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_CODEGEN_UNITS:-workspace-default}"
  echo "release_build_override_debug=\${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG:-workspace-default}"
  echo "release_build_override_incremental=\${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_INCREMENTAL:-workspace-default}"
  echo "release_build_override_overflow_checks=\${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OVERFLOW_CHECKS:-workspace-default}"
  echo "release_build_override_debug_assertions=\${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG_ASSERTIONS:-workspace-default}"
  echo "dev_lto=\${CARGO_PROFILE_DEV_LTO:-workspace-default}"
  echo "dev_codegen_units=\${CARGO_PROFILE_DEV_CODEGEN_UNITS:-workspace-default}"
  echo "dev_debug=\${CARGO_PROFILE_DEV_DEBUG:-workspace-default}"
  echo "dev_opt_level=\${CARGO_PROFILE_DEV_OPT_LEVEL:-workspace-default}"
  echo "dev_panic=\${CARGO_PROFILE_DEV_PANIC:-workspace-default}"
  echo "dev_overflow_checks=\${CARGO_PROFILE_DEV_OVERFLOW_CHECKS:-workspace-default}"
  echo "dev_debug_assertions=\${CARGO_PROFILE_DEV_DEBUG_ASSERTIONS:-workspace-default}"
  echo "dev_strip=\${CARGO_PROFILE_DEV_STRIP:-workspace-default}"
  echo "cargo_term_progress_when=\${CARGO_TERM_PROGRESS_WHEN:-workspace-default}"
  echo "cargo_quiet=$cargo_quiet"
  echo "rustc_timing=$rustc_timing"
  echo "fast_alloc_slab_only=$fast_alloc_slab_only"
  echo "fast_selfbuild_no_dynamic_debug=$fast_selfbuild_no_dynamic_debug"
  echo "fast_selfbuild_display_gating=$fast_selfbuild_display_gating"
  echo "fast_selfbuild_netng_delegacy=$fast_selfbuild_netng_delegacy"
  echo "guest_proc_monitor=$guest_proc_monitor"
  echo "guest_proc_monitor_interval=$guest_proc_monitor_interval"
  echo "guest_cpu_monitor=$guest_cpu_monitor"
  echo "guest_cpu_monitor_interval=$guest_cpu_monitor_interval"
  echo "host_cpu_monitor=$host_cpu_monitor"
  echo "host_cpu_monitor_interval=$host_cpu_monitor_interval"
  echo "host_cpu_csv=$host_cpu_csv"
  echo "host_heartbeat_interval=$host_heartbeat_interval"
  echo "features=$features"
  echo "no_default_features=$no_default_features"
  echo "timestamp_cargo=$timestamp_cargo"
  echo "prebuild_std=$prebuild_std"
  echo "stdwarm_only=$stdwarm_only"
  echo "cargo_message_format=$cargo_message_format"
  echo "cargo_timings=$cargo_timings"
  echo "cargo_subcommand=$cargo_subcommand"
  echo "build_package=$build_package"
  echo "build_bin=$build_bin"
  echo "build_target=$build_target"
  echo "build_std=$build_std"
  echo "build_std_features=$build_std_features"
  echo "sysroot=\$(\$RUSTC --print sysroot 2>/dev/null || true)"
  echo "cpu_count=\$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
  echo "rustflags=\$RUSTFLAGS"
  \$RUSTC --version || true
  /usr/bin/cargo --version || true
  echo "===$marker-ENV-END==="
  cd "\$WORK_DIR" || exit 1
  if [ "$prebuild_std" = "1" ]; then
    stdwarm_dir="/tmp/hvf-stdwarm-${case_name}-${stamp}"
    rm -rf "\$stdwarm_dir"
    mkdir -p "\$stdwarm_dir/src"
    cat >"\$stdwarm_dir/Cargo.toml" <<'STDWARM_TOML'
[package]
name = "hvf-stdwarm"
version = "0.0.0"
edition = "2024"

[lib]
path = "src/lib.rs"
STDWARM_TOML
    cat >"\$stdwarm_dir/src/lib.rs" <<'STDWARM_RS'
#![no_std]
extern crate alloc;

pub fn touch_alloc() -> usize {
    alloc::vec::Vec::<u8>::new().len()
}
STDWARM_RS
    stdwarm_start=\$(date +%s)
    echo "===$marker-STDWARM-START jobs=$jobs start=\$stdwarm_start==="
    stdwarm_build_std_features_arg=""
    if [ -n "$build_std_features" ]; then
      stdwarm_build_std_features_arg="-Z build-std-features=$build_std_features"
    fi
    set +e
    /usr/bin/cargo build $cargo_quiet_arg --manifest-path "\$stdwarm_dir/Cargo.toml" \\
      --target aarch64-unknown-none-softfloat \\
      -Z build-std=core,alloc,compiler_builtins \\
      \$stdwarm_build_std_features_arg \\
      --target-dir "$target_dir" \\
      $cargo_profile_arg
    stdwarm_rc=\$?
    set -e
    stdwarm_end=\$(date +%s)
    stdwarm_elapsed=\$((stdwarm_end - stdwarm_start))
    echo "===$marker-STDWARM-END jobs=$jobs rc=\$stdwarm_rc elapsed=\$stdwarm_elapsed==="
    if [ "\$stdwarm_rc" != "0" ]; then
      echo "===$marker-STDWARM-FAIL jobs=$jobs rc=\$stdwarm_rc elapsed=\$stdwarm_elapsed==="
      finish_guest "\$stdwarm_rc"
    fi
    echo "===$marker-STDWARM-PASS jobs=$jobs elapsed=\$stdwarm_elapsed==="
    if [ "$stdwarm_only" = "1" ]; then
      finish_guest 0
    fi
    cd "\$WORK_DIR" || exit 1
  fi
  monitor_pid=""
  cpu_monitor_pid=""
  if [ "$guest_proc_monitor" = "1" ]; then
    monitor_interval=$guest_proc_monitor_interval
    emit_proc_detail() {
      pid="\$1"
      [ -d "/proc/\$pid" ] || return 0
      comm=\$(cat "/proc/\$pid/comm" 2>/dev/null || true)
      cmdline=\$(tr '\\0' ' ' <"/proc/\$pid/cmdline" 2>/dev/null || true)
      case "\$comm \$cmdline" in
        *cargo*|*rustc*|*build-script*|*compiler*|*cc*|*ld*|*ar*)
          echo "---PROC-DETAIL pid=\$pid comm=\$comm---"
          echo "cmdline=\$cmdline"
          echo "status_begin pid=\$pid"
          cat "/proc/\$pid/status" 2>/dev/null || true
          echo "status_end pid=\$pid"
          echo "stat=\$(cat "/proc/\$pid/stat" 2>/dev/null || true)"
          echo "fd_begin pid=\$pid"
          ls -l "/proc/\$pid/fd" 2>/dev/null || true
          echo "fd_end pid=\$pid"
          echo "children=\$(cat "/proc/\$pid/task/\$pid/children" 2>/dev/null || true)"
          echo "task_begin pid=\$pid"
          for td in "/proc/\$pid/task/"*; do
            [ -d "\$td" ] || continue
            tid="\${td##*/}"
            echo "---TASK pid=\$pid tid=\$tid---"
            echo "task_stat=\$(cat "\$td/stat" 2>/dev/null || true)"
            echo "task_wchan=\$(cat "\$td/wchan" 2>/dev/null || true)"
            echo "task_children=\$(cat "\$td/children" 2>/dev/null || true)"
            cat "\$td/status" 2>/dev/null | sed 's/^/task_status: /' || true
          done
          echo "task_end pid=\$pid"
          ;;
      esac
    }
    snapshot_proc() {
      echo "===GUEST-PROC-MONITOR t=\$(date +%s)==="
      echo "proc_stat_begin"
      cat /proc/stat 2>/dev/null || true
      echo "proc_stat_end"
      echo "loadavg=\$(cat /proc/loadavg 2>/dev/null || true)"
      echo "meminfo_begin"
      sed -n '1,12p' /proc/meminfo 2>/dev/null || true
      echo "meminfo_end"
      echo "ps_begin"
      ps -o pid,ppid,stat,etime,args 2>/dev/null || ps w 2>/dev/null || ps
      echo "ps_end"
      for d in /proc/[0-9]*; do
        [ -d "\$d" ] || continue
        emit_proc_detail "\${d##*/}"
      done
      echo "===GUEST-PROC-MONITOR-END t=\$(date +%s)==="
    }
    (
      while :; do
        snapshot_proc
        sleep "\$monitor_interval"
      done
    ) &
    monitor_pid="\$!"
  fi
  if [ "$guest_cpu_monitor" = "1" ]; then
    (
      while :; do
        now=\$(date +%s)
        echo "===GUEST-CPU-MONITOR t=\$now==="
        sed -n '1,9p' /proc/stat 2>/dev/null || true
        echo "loadavg=\$(cat /proc/loadavg 2>/dev/null || true)"
        grep '^MemAvailable:' /proc/meminfo 2>/dev/null || true
        echo "===GUEST-CPU-MONITOR-END t=\$(date +%s)==="
        sleep "$guest_cpu_monitor_interval"
      done
    ) &
    cpu_monitor_pid="\$!"
  fi
  start=\$(date +%s)
  echo "===$marker-START jobs=$jobs start=\$start==="
  set +e
  no_default_features_arg=""
  if [ "$no_default_features" = "1" ]; then
    no_default_features_arg="--no-default-features"
  fi
  cargo_message_format_arg=""
  if [ -n "$cargo_message_format" ]; then
    cargo_message_format_arg="--message-format $cargo_message_format"
  fi
  cargo_timings_arg=""
  if [ "$cargo_timings" = "1" ]; then
    cargo_timings_arg="--timings"
  fi
  cargo_package_arg=""
  if [ -n "$build_package" ]; then
    cargo_package_arg="-p $build_package"
  fi
  cargo_bin_arg=""
  if [ -n "$build_bin" ]; then
    cargo_bin_arg="--bin $build_bin"
  fi
  cargo_build_std_arg=""
  if [ -n "$build_std" ] && [ "$build_std" != "none" ]; then
    cargo_build_std_arg="-Z build-std=$build_std"
  fi
  cargo_build_std_features_arg=""
  if [ -n "$build_std_features" ]; then
    cargo_build_std_features_arg="-Z build-std-features=$build_std_features"
  fi
  cargo_features_arg=""
  if [ -n "$features" ]; then
    cargo_features_arg="--features $features"
  fi
  echo "===$marker-CARGO-COMMAND subcommand=$cargo_subcommand package=$build_package bin=$build_bin target=$build_target build_std=$build_std features=$features==="
  if [ "$timestamp_cargo" = "1" ]; then
    rc_file="/tmp/hvf-cargo-rc-\$\$"
    rm -f "\$rc_file"
    (
      /usr/bin/cargo "$cargo_subcommand" $cargo_quiet_arg \\
        \$cargo_package_arg \\
        \$cargo_bin_arg \\
        --target "$build_target" \\
        \$cargo_build_std_arg \\
        \$cargo_build_std_features_arg \\
        --target-dir "$target_dir" \\
        \$no_default_features_arg \\
        \$cargo_message_format_arg \\
        \$cargo_timings_arg \\
        \$cargo_features_arg \\
        $cargo_profile_arg
      echo "\$?" >"\$rc_file"
    ) 2>&1 | while IFS= read -r line; do
      printf '===CARGO-LINE t=%s=== %s\\n' "\$(date +%s)" "\$line"
    done
    rc=\$(cat "\$rc_file" 2>/dev/null || echo 127)
    rm -f "\$rc_file"
  else
    /usr/bin/cargo "$cargo_subcommand" $cargo_quiet_arg \\
      \$cargo_package_arg \\
      \$cargo_bin_arg \\
      --target "$build_target" \\
      \$cargo_build_std_arg \\
      \$cargo_build_std_features_arg \\
      --target-dir "$target_dir" \\
      \$no_default_features_arg \\
      \$cargo_message_format_arg \\
      \$cargo_timings_arg \\
      \$cargo_features_arg \\
      $cargo_profile_arg
    rc=\$?
  fi
  set -e
  if [ -n "\$monitor_pid" ]; then
    kill "\$monitor_pid" 2>/dev/null || true
    wait "\$monitor_pid" 2>/dev/null || true
  fi
  if [ -n "\$cpu_monitor_pid" ]; then
    kill "\$cpu_monitor_pid" 2>/dev/null || true
    wait "\$cpu_monitor_pid" 2>/dev/null || true
  fi
  end=\$(date +%s)
  elapsed=\$((end - start))
  echo "===$marker-END jobs=$jobs rc=\$rc elapsed=\$elapsed==="
  if [ "\$rc" = "0" ]; then
    echo "===$marker-PASS jobs=$jobs elapsed=\$elapsed==="
  else
    echo "===$marker-FAIL jobs=$jobs rc=\$rc elapsed=\$elapsed==="
  fi
  finish_guest "\$rc"
elif [ "$profile" = "release" ]; then
  /opt/build-starryos-hvf.sh
else
  /opt/build-starryos-hvf-debug.sh
fi
rc=\$?
finish_guest "\$rc"
EOF
chmod +x "$guest_auto"

if [ "$dry_run" = "1" ]; then
  echo "guest_auto=$guest_auto"
  sed -n '1,420p' "$guest_auto"
  exit 0
fi

debugfs_cmd="/tmp/auto-os-hvf/debugfs-replace-hvf-auto-${case_name}-${stamp}.cmd"
cat >"$debugfs_cmd" <<EOF
rm /opt/hvf-auto.sh
write $guest_auto /opt/hvf-auto.sh
sif /opt/hvf-auto.sh mode 0100755
EOF

/opt/homebrew/opt/e2fsprogs/sbin/debugfs -w -f "$debugfs_cmd" "$img"

echo "log=$log"
if [ "$host_cpu_monitor" = "1" ]; then
  echo "host_cpu_csv=$host_cpu_csv"
fi
echo "case=$case_name profile=$profile smp=$smp jobs=$jobs source_tmpfs=$source_tmpfs target_dir=$target_dir work_dir=$work_dir kernel=$kernel"

/opt/homebrew/bin/qemu-system-aarch64 \
  -snapshot \
  -nographic \
  -accel hvf \
  -machine virt,gic-version=3 \
  -cpu host \
  -m "$mem" \
  -smp "$smp" \
  -device virtio-blk-pci,drive=disk0 \
  -drive "id=disk0,if=none,format=raw,file=$img,file.locking=off" \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  -kernel "$kernel" \
  -monitor none \
  -serial mon:stdio \
  >"$log" 2>&1 &
qemu_pid=$!

host_cpu_monitor_pid=""
stop_host_cpu_monitor() {
  if [ -n "$host_cpu_monitor_pid" ]; then
    kill "$host_cpu_monitor_pid" 2>/dev/null || true
    wait "$host_cpu_monitor_pid" 2>/dev/null || true
    host_cpu_monitor_pid=""
  fi
}

if [ "$host_cpu_monitor" = "1" ]; then
  mkdir -p "$(dirname "$host_cpu_csv")"
  printf 'epoch,pid,host_cpu_pct,rss_kb,vsz_kb,cpu_time,elapsed_time\n' >"$host_cpu_csv"
  (
    while kill -0 "$qemu_pid" 2>/dev/null; do
      now="$(date +%s)"
      ps_line="$(
        ps -p "$qemu_pid" -o pid= -o %cpu= -o rss= -o vsz= -o time= -o etime= 2>/dev/null |
          awk 'NR == 1 { print }'
      )"
      if [ -n "$ps_line" ]; then
        set -- $ps_line
        printf '%s,%s,%s,%s,%s,%s,%s\n' "$now" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" >>"$host_cpu_csv"
      else
        printf '%s,%s,,,,,\n' "$now" "$qemu_pid" >>"$host_cpu_csv"
      fi
      sleep "$host_cpu_monitor_interval"
    done
  ) &
  host_cpu_monitor_pid="$!"
fi

set +e
last_host_heartbeat=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  now="$(date +%s)"
  if [ "$host_heartbeat_interval" != "0" ] && [ $((now - last_host_heartbeat)) -ge "$host_heartbeat_interval" ]; then
    echo "===HOST-QEMU-ALIVE t=$now pid=$qemu_pid log=$log==="
    last_host_heartbeat="$now"
  fi
  if LC_ALL=C grep -a -q "===HVF-${case_name}-RUN-END rc=" "$log"; then
    marker_rc="$(
      LC_ALL=C sed -n "s/^===HVF-${case_name}-RUN-END rc=\([0-9][0-9]*\)===.*/\1/p" "$log" | tail -1
    )"
    echo "===HOST-QEMU-STOP reason=guest-run-end pid=$qemu_pid rc=${marker_rc:-unknown}===" >>"$log"
    stop_host_cpu_monitor
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null
    exit "${marker_rc:-0}"
  fi
  sleep 2
done
wait "$qemu_pid"
qemu_rc="$?"
stop_host_cpu_monitor
exit "$qemu_rc"
