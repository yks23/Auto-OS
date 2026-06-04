#!/usr/bin/env bash
# 测试：本机是否已有成功的 M5 复现产物（供 CI / 本地二次确认）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$ROOT/scripts/verify-reproduce-m5.sh"
