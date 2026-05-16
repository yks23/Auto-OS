#!/usr/bin/env bash
# M6 代理：在 **仓库 Docker 镜像 auto-os/starry:latest** 内对 starryos 跑与 scripts/build.sh 等价的配置 + cargo check。
#
# 镜像缺失时自动构建（与 reproduce-all.sh 同源 Dockerfile；docker/ 下脚本由 Dockerfile COPY）：
#   docker build --platform linux/amd64 --pull --network host -t auto-os/starry:latest -f Dockerfile .
# （在仓库根执行；`-f` 指向 `$ROOT/Dockerfile`，上下文为 `$ROOT`。）
#
# 显式 --platform linux/amd64，便于在 Apple Silicon 上与 arceos 的 x86_64 版 riscv64-linux-musl-cross 预编译包一致
# （见 tests/selfhost/m6/docker-inner-cargo-check.sh）。
#
# 挂载可写仓库根（在 tgoskits/os/StarryOS 生成 .axconfig.toml）。
#
# 与「在 QEMU 的 riscv64 Alpine guest 里跑 rustc」的区别见 tests/selfhost/m6/README.md。
#
# 环境变量：
#   M6_SKIP_DOCKER=1   — 跳过（不失败）
#   M6_DOCKER_IMAGE    — 覆盖镜像名（默认 auto-os/starry:latest）
#
# 用法：在 Auto-OS 根目录
#   bash scripts/m6-docker-riscvlinux-cargo-check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${M6_SKIP_DOCKER:-}" == "1" ]]; then
    echo "SKIP: M6_SKIP_DOCKER=1"
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: 未安装 docker"
    exit 0
fi

if [[ ! -f "$ROOT/tgoskits/Cargo.toml" ]]; then
    echo "FAIL: 未找到 tgoskits（git submodule update --init tgoskits）" >&2
    exit 1
fi

chmod +x "$ROOT/tests/selfhost/m6/docker-inner-cargo-check.sh" 2>/dev/null || true

IMAGE="${M6_DOCKER_IMAGE:-auto-os/starry:latest}"
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        echo "FAIL: 无法连接 Docker daemon（参考 scripts/reproduce-all.sh：先确保 docker 可用）" >&2
        exit 1
    fi
fi

if ! "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[m6] 本地无镜像 $IMAGE；从仓库 Dockerfile 构建（首次约数分钟）…" >&2
    "$DOCKER" build --platform linux/amd64 --pull --network host \
        -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"
fi

echo "[m6] docker $IMAGE --platform linux/amd64 …"
"$DOCKER" run --rm \
    --platform linux/amd64 \
    -e WORKSPACE=/workspace \
    -v "$ROOT:/workspace" \
    "$IMAGE" \
    bash /workspace/tests/selfhost/m6/docker-inner-cargo-check.sh

echo "[m6] PASS（容器内已打印 ===M6-DOCKER-CARGO-CHECK-PASS===）"
