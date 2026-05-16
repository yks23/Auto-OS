#!/usr/bin/env bash
# 快速打印 onecrate 冒烟使用的内核 / rootfs 与串口日志尾部（宿主侧）。
# **不启动 QEMU** — 仅诊断；实机全流程请运行 `scripts/verify-sterile-phase1.sh` 或
# `scripts/guest-onecrate-syscall-evidence.sh`。
# 与 scripts/guest-onecrate-syscall-evidence.sh 一致：非 root 宿主侧由 auto-os/starry:latest 编排。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="auto-os/starry:latest"
KERNEL="${KERNEL:-$ROOT/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos}"
ROOTFS="${GUEST_ONECRATE_ROOTFS:-}"
if [[ -z "$ROOTFS" ]]; then
  if [[ -f "$ROOT/.guest-runs/riscv64-m6/rootfs-run.img" ]]; then
    ROOTFS="$ROOT/.guest-runs/riscv64-m6/rootfs-run.img"
  else
    ROOTFS="$ROOT/tests/selfhost/rootfs-selfbuild-riscv64.img"
  fi
fi
LOG="${GUEST_ONECRATE_RESULT:-$ROOT/.guest-runs/guest-onecrate-bench/results.txt}"
echo "IMAGE=$IMAGE"
echo "KERNEL=$KERNEL"
echo "ROOTFS=$ROOTFS"
echo "SERIAL_LOG=$LOG"
if [[ -f "$KERNEL" ]]; then ls -la "$KERNEL"; else echo "missing kernel"; fi
if [[ -f "$ROOTFS" ]]; then ls -la "$ROOTFS"; else echo "missing rootfs"; fi
if [[ -f "$LOG" ]]; then echo "--- tail $LOG ---"; tail -n 80 "$LOG"; else echo "missing log"; fi
