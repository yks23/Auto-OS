#!/usr/bin/env bash
# Starry 静态检查（真实 cargo，无 stub）：在 **auto-os/starry:latest** 容器内执行。
# Fail-fast：`--docker-inner` 内先 `cargo fmt --check`，再 axplat/linker/clippy/check。
#
# ## rustfmt 范围
# 对整个 **tgoskits** workspace 跑 `cargo fmt --check`（与 os/StarryOS 子树相比，
# 全 workspace 更易在 CI 中保持单一 fmt 真值源）。若日后 fmt 噪音过大，可改为
# 仅 `os/StarryOS` 路径下子 crate 的 `cargo fmt --manifest-path=…` 并更新本注释。
#
# ## clippy / cargo check
# - 目标：`riscv64gc-unknown-none-elf`
# - 包：`starry-kernel`、`starryos`
# - 先生成 `.axconfig.toml` 与 linker pass（与 `tests/selfhost/m6/docker-inner-cargo-check.sh` 同源），
#   再 `cargo clippy` / `cargo check`。
# - Clippy：优先 `RUSTFLAGS=… cargo clippy … -- -D warnings`。若上游尚未清零
#   warnings，设置 `CI_STARRY_CLIPPY_NO_DENY_WARNINGS=1` 则改为 `-- -W clippy::all`
#   （不因 warning 失败退出，脚本仍打印 clippy 输出供迭代）。
#
# 用法（仓库根）：
#   bash scripts/ci-starry-static.sh
#
# 环境变量：
#   CI_STARRY_SKIP_DOCKER=1  — 跳过（成功退出 0，供本地无 Docker 时占位）
#   CI_STARRY_DOCKER_IMAGE   — 默认 auto-os/starry:latest
#   CI_STARRY_CLIPPY_NO_DENY_WARNINGS=1 — clippy 不使用 -D warnings
#   CI_STARRY_DOCKER_PLATFORM — 可选，如 linux/amd64；**默认不设置**，用本机已存在的
#     镜像变体（Apple Silicon 上常为 arm64，与 Dockerfile 说明一致）。强制 amd64 时再设。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${CI_STARRY_DOCKER_IMAGE:-auto-os/starry:latest}"

if [[ "${1:-}" == "--docker-inner" ]]; then
  shift || true
  TG="/work/tgoskits"
  cd "$TG"
  echo "[ci-starry-static:inner] cargo fmt --check (workspace $TG)"
  cargo fmt --check

  if [[ -d /usr/lib/llvm-18/lib ]]; then
    export LIBCLANG_PATH=/usr/lib/llvm-18/lib
  elif [[ -d /usr/lib/llvm-19/lib ]]; then
    export LIBCLANG_PATH=/usr/lib/llvm-19/lib
  else
    _clang_so="$(find /usr/lib -name 'libclang.so.*' -type f 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "${_clang_so}" ]]; then
      export LIBCLANG_PATH="$(dirname "${_clang_so}")"
    fi
  fi
  [[ -n "${LIBCLANG_PATH:-}" ]] || {
    echo "FAIL: LIBCLANG_PATH 未设置" >&2
    exit 1
  }
  echo "[ci-starry-static:inner] LIBCLANG_PATH=$LIBCLANG_PATH"

  export CARGO_NET_GIT_FETCH_WITH_CLI=true
  export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

  ARCH=riscv64
  PLAT_PACKAGE=ax-plat-riscv64-qemu-virt
  RUST_TARGET=riscv64gc-unknown-none-elf
  STARRY_FEATURES=starryos/qemu

  cd "$TG/os/StarryOS"
  PLAT_CONFIG="$(cargo axplat info -C starryos -c "$PLAT_PACKAGE" 2>/dev/null | tail -1)"
  [[ -n "$PLAT_CONFIG" && -f "$PLAT_CONFIG" ]] || {
    echo "FAIL: 无法解析 PLAT_CONFIG: $PLAT_CONFIG" >&2
    exit 1
  }
  PLAT_NAME="$(awk -F'"' '$1 ~ /^platform[[:space:]]*=/ {print $2}' "$PLAT_CONFIG" | head -1)"
  [[ -n "$PLAT_NAME" ]] || {
    echo "FAIL: 无法从 $PLAT_CONFIG 读取 platform" >&2
    exit 1
  }

  ax-config-gen \
    "$(pwd)/make/defconfig.toml" "$PLAT_CONFIG" \
    -w "arch=\"$ARCH\"" \
    -w "platform=\"$PLAT_NAME\"" \
    -o .axconfig.toml

  export AX_ARCH="$ARCH"
  export AX_PLATFORM="$PLAT_NAME"
  export AX_MODE=release
  export AX_LOG="${AX_LOG:-warn}"
  export AX_TARGET="$RUST_TARGET"
  export AX_IP=10.0.2.15
  export AX_GW=10.0.2.2
  export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"

  cd "$TG"
  TARGET_DIR="$TG/target"
  LD_SCRIPT="$TARGET_DIR/$RUST_TARGET/release/linker_${PLAT_NAME}.lds"

  echo "[ci-starry-static:inner] pass 1/2: 生成 linker_${PLAT_NAME}.lds"
  RUSTFLAGS="${RUSTFLAGS:-}" cargo build -p starryos \
    --target "$RUST_TARGET" --release \
    --features "$STARRY_FEATURES" 2>/dev/null || true
  [[ -f "$LD_SCRIPT" ]] || {
    echo "FAIL: 未生成链接脚本: $LD_SCRIPT" >&2
    exit 1
  }

  _clip_extra=()
  if [[ "${CI_STARRY_CLIPPY_NO_DENY_WARNINGS:-}" == "1" ]]; then
    echo "[ci-starry-static:inner] clippy: -W clippy::all（CI_STARRY_CLIPPY_NO_DENY_WARNINGS=1）"
    _clip_extra=(-- -W clippy::all)
  else
    echo "[ci-starry-static:inner] clippy: -D warnings（设 CI_STARRY_CLIPPY_NO_DENY_WARNINGS=1 可降级）"
    _clip_extra=(-- -D warnings)
  fi

  RUSTFLAGS="-C link-arg=-T$LD_SCRIPT -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
    cargo clippy -p starry-kernel -p starryos \
    --target "$RUST_TARGET" --release \
    --features "$STARRY_FEATURES" \
    "${_clip_extra[@]}"

  echo "[ci-starry-static:inner] cargo check -p starry-kernel -p starryos"
  RUSTFLAGS="-C link-arg=-T$LD_SCRIPT -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
    cargo check -p starry-kernel -p starryos \
    --target "$RUST_TARGET" --release \
    --features "$STARRY_FEATURES"

  echo "[ci-starry-static:inner] OK"
  exit 0
fi

if [[ "${CI_STARRY_SKIP_DOCKER:-}" == "1" ]]; then
  echo "SKIP: CI_STARRY_SKIP_DOCKER=1"
  exit 0
fi

if [[ ! -f "$ROOT/tgoskits/Cargo.toml" ]]; then
  echo "FAIL: 缺少 tgoskits（git submodule update --init tgoskits）" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL: 未安装 docker" >&2
  exit 1
fi

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    echo "FAIL: 无法连接 Docker daemon" >&2
    exit 1
  fi
fi

if ! "${DOCKER[@]}" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[ci-starry-static] 构建镜像 $IMAGE …" >&2
  # 默认不加 --pull，避免镜像仓库/镜像代理 429；需要强制更新时：CI_STARRY_DOCKER_BUILD_PULL=1
  _pull=(--pull=never)
  if [[ "${CI_STARRY_DOCKER_BUILD_PULL:-}" == "1" ]]; then
    _pull=(--pull)
  fi
  # shellcheck disable=SC2086
  "${DOCKER[@]}" build \
    ${CI_STARRY_DOCKER_PLATFORM:+--platform "${CI_STARRY_DOCKER_PLATFORM}"} \
    "${_pull[@]}" --network host \
    -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"
fi

echo "[ci-starry-static] 在 ${IMAGE} 内执行 fmt + clippy + check …" >&2
# shellcheck disable=SC2086
"${DOCKER[@]}" run --rm \
  ${CI_STARRY_DOCKER_PLATFORM:+--platform "${CI_STARRY_DOCKER_PLATFORM}"} \
  -e "CI_STARRY_CLIPPY_NO_DENY_WARNINGS=${CI_STARRY_CLIPPY_NO_DENY_WARNINGS:-}" \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  bash /work/scripts/ci-starry-static.sh --docker-inner

echo "[ci-starry-static] PASS"
exit 0
