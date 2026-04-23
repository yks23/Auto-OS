#!/usr/bin/env bash
# reproduce-all.sh — host-side driver: build the auto-os/starry docker image
# (if needed), then run the in-container reproduction script.
#
# After this script the user has:
#   - tgoskits/target/.../release/starryos      (kernel ELF, freshly built)
#   - tests/selfhost/rootfs-selfhost-rust-riscv64.img  (M5 demo rootfs)
#   - .guest-runs/riscv64-m5/results.txt        (M5 demo guest serial log)
#   - if --m6 is passed: tests/selfhost/rootfs-selfbuild-riscv64.img and a
#     guest log for the in-guest selfbuild attempt as well.
#
# Host requirements: docker only. Everything else is in the image.
#
# Docker 平台（docker build/run 的 --platform，与 Dockerfile TARGETARCH 一致）：
# - 默认：宿主 uname -m 为 arm64 / aarch64 → linux/arm64（Dockerfile 内 gnu 交叉链）
# - 其他宿主 → linux/amd64（arceos musl 预编译链）
# 显式覆盖：DOCKER_PLATFORM=linux/amd64 bash scripts/reproduce-all.sh
#
# Env（可选）：
#   AUTO_OS_REPRODUCE_ALLOW_LOW_DOCKER_MEM=1  — Docker VM <9GiB 时仍继续
#   AUTO_OS_DOCKER_NO_CARGO_CACHE=1          — 不挂载持久 cargo registry/git
#   AUTO_OS_DOCKER_CARGO_CACHE=/path         — 缓存目录（默认 仓库/.docker-cargo-registry）
#
# 路径 A / 资源：
# - Docker Desktop VM 内存 < ~9 GiB 时默认退出（整仓 cargo 易 OOM）；覆盖：
#     AUTO_OS_REPRODUCE_ALLOW_LOW_DOCKER_MEM=1 bash scripts/reproduce-all.sh ...
# - 持久化 crates.io / git 依赖缓存（避免每次 --rm 重复下载），默认挂载到仓库下
#   .docker-cargo-registry/{registry,git}；关闭：AUTO_OS_DOCKER_NO_CARGO_CACHE=1
#   自定义目录：AUTO_OS_DOCKER_CARGO_CACHE=/path/to/dir

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
if [[ -z "$DOCKER_PLATFORM" ]]; then
    if [[ "$(uname -m)" == arm64 || "$(uname -m)" == aarch64 ]]; then
        DOCKER_PLATFORM=linux/arm64
    else
        DOCKER_PLATFORM=linux/amd64
    fi
fi
PLATFORM_ARGS=(--platform "$DOCKER_PLATFORM")

IMAGE="${IMAGE:-auto-os/starry}"
WITH_M6=0
SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --m6)         WITH_M6=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --image=*)    IMAGE="${arg#--image=}" ;;
        --help|-h)
            sed -n '1,45p' "$0" ; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fatal() { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# Pick `docker` or `sudo docker`
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        fatal "cannot reach docker daemon. Run 'sudo bash scripts/setup-env.sh' first."
    fi
fi

# Docker VM memory (tgoskits release build + axplat 解析在 arm64 上建议 ≥10 GiB)
_docker_mem="$($DOCKER info -f '{{.MemTotal}}' 2>/dev/null || echo 0)"
if [[ "$_docker_mem" =~ ^[0-9]+$ ]] && ((_docker_mem > 0)); then
    _min_mem=$((9 * 1024 * 1024 * 1024))
    if ((_docker_mem < _min_mem)); then
        _gib="$(awk -v b="$_docker_mem" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"
        if [[ "${AUTO_OS_REPRODUCE_ALLOW_LOW_DOCKER_MEM:-}" == "1" ]]; then
            log "warning: Docker Total Memory ~${_gib} GiB (< 9 GiB). Recommend Docker Desktop → Resources → Memory (10–12 GiB). Continuing (AUTO_OS_REPRODUCE_ALLOW_LOW_DOCKER_MEM=1)."
        else
            fatal "Docker Total Memory ~${_gib} GiB is below 9 GiB — reproduce is likely to OOM or thrash. Increase Docker Desktop → Resources → Memory to ~10–12 GiB, or set AUTO_OS_REPRODUCE_ALLOW_LOW_DOCKER_MEM=1 to override."
        fi
    fi
fi
unset _docker_mem _min_mem _gib

# ---------------------------------------------- step 1: image
if (( ! SKIP_BUILD )); then
    log "step 1/3  build docker image '$IMAGE' (${DOCKER_PLATFORM}; ~3-5 min first time)"
    $DOCKER build "${PLATFORM_ARGS[@]}" --pull --network host -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"
fi
log "image ready: $($DOCKER images "$IMAGE" --format '{{.ID}} {{.Size}}')"

# ---------------------------------------------- step 2: submodule
log "step 2/3  init tgoskits submodule (yks23/tgoskits selfhost-m5 + F-eps)"
git submodule update --init tgoskits

# ---------------------------------------------- step 3: run inside container
log "step 3/3  enter container, run reproduce-in-container.sh"
EXTRA=""
(( WITH_M6 )) && EXTRA="--m6"

DOCKER_CARGO_MOUNTS=()
if [[ "${AUTO_OS_DOCKER_NO_CARGO_CACHE:-}" != "1" ]]; then
    CARGO_CACHE_HOST="${AUTO_OS_DOCKER_CARGO_CACHE:-$ROOT/.docker-cargo-registry}"
    mkdir -p "$CARGO_CACHE_HOST/registry" "$CARGO_CACHE_HOST/git"
    DOCKER_CARGO_MOUNTS=(
        -v "$CARGO_CACHE_HOST/registry:/usr/local/cargo/registry"
        -v "$CARGO_CACHE_HOST/git:/usr/local/cargo/git"
    )
    log "cargo registry cache: $CARGO_CACHE_HOST (disable: AUTO_OS_DOCKER_NO_CARGO_CACHE=1)"
fi

$DOCKER run --rm "${PLATFORM_ARGS[@]}" --privileged --network host \
    -e GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
    -v "$ROOT:/work" -w /work \
    "${DOCKER_CARGO_MOUNTS[@]}" \
    "$IMAGE" \
    bash scripts/reproduce-in-container.sh $EXTRA

log "done. See:"
echo "    .guest-runs/riscv64-m5/results.txt   (M5: cargo build hello world inside starry)"
if (( WITH_M6 )); then
    echo "    .guest-runs/riscv64-m6/results.txt   (M6: starry sources + nightly toolchain inside starry guest)"
fi
exit 0
