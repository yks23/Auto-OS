#!/usr/bin/env bash
# 测试：riscv64 Linux 用户态（Docker）内 cargo check -p starryos。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$ROOT/scripts/m6-docker-riscvlinux-cargo-check.sh"
