#!/usr/bin/env bash
# 在「正常编译环境」下依次构建 riscv64 与 x86_64 的 StarryOS 内核，并把 ELF 拷到
# .guest-runs/kernels/ 留档（带 UTC 时间戳文件名）。
#
# 推荐在 auto-os/starry 容器内执行（Linux + riscv64-linux-musl 交叉链，lwext4 的 C 部分才能编过）。
# 在 Apple Silicon 宿主机裸跑时，riscv 交叉 gcc 常为 Linux ELF，会出现 cannot execute binary file。
#
# 用法（仓库根）：
#   bash scripts/build-dual-kernels.sh
#   bash scripts/build-dual-kernels.sh --second-pass
#       # 先完整编两轮 first，再 cargo clean -p starryos，再编一轮并归档为 *-after-clean.elf
#   bash scripts/build-dual-kernels.sh --second-pass-only
#       # 假定你已编好 first（cargo 产物已在 target/…/release/starryos），只做 clean + 再编 + 归档 after-clean
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SECOND_PASS=0
SECOND_PASS_ONLY=0
for a in "$@"; do
    case "$a" in
        --second-pass)       SECOND_PASS=1 ;;
        --second-pass-only) SECOND_PASS_ONLY=1 ;;
        *) echo "unknown arg: $a (use --second-pass | --second-pass-only)" >&2; exit 2 ;;
    esac
done
if (( SECOND_PASS && SECOND_PASS_ONLY )); then
    echo "use only one of --second-pass or --second-pass-only" >&2
    exit 2
fi

OUT="$ROOT/.guest-runs/kernels"
mkdir -p "$OUT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MANIFEST="$OUT/MANIFEST-${STAMP}.txt"
SUMMARY="$ROOT/docs/KERNEL-MANIFEST-latest.txt"

log() {
    local m="[build-dual] $*"
    printf '%s\n' "$m" >&2
    printf '%s\n' "$m" >>"$MANIFEST"
}

{
    echo "stamp=$STAMP"
    echo "mode=$(
        if (( SECOND_PASS_ONLY )); then echo second-pass-only
        elif (( SECOND_PASS )); then echo second-pass
        else echo first-only
        fi
    )"
    echo "host=$(uname -srvmo 2>/dev/null || uname -a)"
    echo "git=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo n/a)"
} >"$MANIFEST"
log "manifest -> $MANIFEST"

if [[ "$(uname -s)" == Darwin ]] && ! command -v riscv64-linux-musl-cc >/dev/null 2>&1; then
    log "WARN: 未检测到 riscv64-linux-musl-cc；若在 macOS 宿主机上，riscv 构建可能失败。请用:"
    log "  docker run --rm --platform linux/arm64 -v \"\$PWD:/work\" -w /work auto-os/starry:latest bash scripts/build-dual-kernels.sh"
fi

archive_one() {
    local arch="$1"   # riscv64 | x86_64
    local label="$2" # e.g. first | after-clean
    local rel=""
    case "$arch" in
        riscv64) rel="tgoskits/target/riscv64gc-unknown-none-elf/release/starryos" ;;
        x86_64)  rel="tgoskits/target/x86_64-unknown-none/release/starryos" ;;
        *) echo "bad arch $arch" >&2; exit 2 ;;
    esac
    [[ -f "$ROOT/$rel" ]] || { log "ERROR: missing $rel — build failed"; exit 1; }
    local dst="$OUT/starryos-${arch}-${STAMP}-${label}.elf"
    cp "$ROOT/$rel" "$dst"
    log "archived $rel -> ${dst#$ROOT/}"
    shasum -a 256 "$dst" | tee -a "$MANIFEST" >&2
}

do_builds() {
    local label="$1"
    log "=== ARCH=riscv64 ($label) ==="
    bash "$ROOT/scripts/build.sh" ARCH=riscv64
    archive_one riscv64 "$label"

    log "=== ARCH=x86_64 ($label) ==="
    bash "$ROOT/scripts/build.sh" ARCH=x86_64
    archive_one x86_64 "$label"
}

if (( SECOND_PASS_ONLY )); then
    log "mode=second-pass-only — skip first archive, expect existing target/.../starryos"
    log "=== cargo clean -p starryos (tgoskits workspace) ==="
    ( cd "$ROOT/tgoskits" && cargo clean -p starryos )
    do_builds "after-clean"
elif (( SECOND_PASS )); then
    do_builds "first"
    log "=== cargo clean -p starryos (tgoskits workspace) ==="
    ( cd "$ROOT/tgoskits" && cargo clean -p starryos )
    do_builds "after-clean"
else
    do_builds "first"
fi

cp "$MANIFEST" "$SUMMARY"
log "copied manifest -> docs/KERNEL-MANIFEST-latest.txt (便于提交到 git 留档)"
log "done. 详见 $MANIFEST 与 docs/STARRYOS-KERNEL-BUILD-MATRIX.md"
