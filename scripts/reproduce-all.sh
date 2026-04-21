#!/usr/bin/env bash
# reproduce-all.sh — 一键从 repo 根目录走到 "M5 cargo build" PASS。
#
# 做什么：
#   0. 环境检测（check-env.sh）
#   1. tgoskits 子模块初始化 / 同步到 Auto-OS 锁定的 commit
#      （这个 commit 里已经集成了 T1-T10 + F-alpha/beta/gamma/delta + M1.5）
#   2. 把 F-ε (patches/F-eps/*.patch) 应用到 tgoskits 工作树
#      （F-ε 是本轮的 vfork/posix_spawn 修复，还没进 submodule commit）
#   3. 编 starry kernel（riscv64-qemu-virt）
#   4. 造 guest rootfs (PROFILE=rust，含 rustc 1.95 + cargo 1.95)
#   5. 跑 M5 demo：guest 内 rustc hello.rs + cargo build --release
#
# 只读 flag：
#   --skip-env              跳过环境检测（你已确认通过）
#   --skip-rootfs           跳过 rootfs 重造（用已有的 .img）
#   --arch=ARCH             目前只支持 riscv64（默认）
#   --help
#
# 产物：
#   tgoskits/target/riscv64gc-unknown-none-elf/release/starryos
#   tests/selfhost/rootfs-selfhost-rust-riscv64.img
#   .guest-runs/riscv64-m5/results.txt         (guest 串口完整日志)
#   标准输出末尾打印 "===M5-DEMO-PASS==="   → 成功。
#
# 运行时间（参考 Ubuntu 24.04, 16C, 16G, x86_64 host）：
#   kernel build   ~30 s
#   rootfs build   ~3-5 min（第一次 apk fetch 比较慢）
#   M5 demo        ~1-2 min（QEMU 里跑 rustc + cargo build）

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# -------------------------------------------------------- arg parsing
SKIP_ENV=0
SKIP_ROOTFS=0
ARCH=riscv64
for arg in "$@"; do
    case "$arg" in
        --skip-env)      SKIP_ENV=1 ;;
        --skip-rootfs)   SKIP_ROOTFS=1 ;;
        --arch=*)        ARCH="${arg#--arch=}" ;;
        --help|-h)
            sed -n '1,40p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [[ "$ARCH" != "riscv64" ]]; then
    echo "error: ARCH=$ARCH not yet supported (x86_64 upstream still panics in axplat e820)" >&2
    exit 1
fi

log()   { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fatal() { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------- step 0: env check
if (( ! SKIP_ENV )); then
    log "step 0/5  environment check"
    if ! bash "$SCRIPT_DIR/check-env.sh"; then
        fatal "environment check failed. Run 'sudo bash scripts/setup-env.sh' first, or re-run with --skip-env to ignore."
    fi
fi

# ---------------------------------------------- step 1: submodule sync
log "step 1/5  tgoskits submodule → Auto-OS pinned commit"
if [[ ! -d tgoskits/.git && ! -f tgoskits/.git ]]; then
    git submodule update --init tgoskits
fi
SUBMOD_SHA_WANT="$(git ls-tree HEAD tgoskits | awk '{print $3}')"
# Always start from a clean, pinned tree — discard any stale apply attempts.
(
    cd tgoskits
    git reset --hard "$SUBMOD_SHA_WANT" >/dev/null
    git clean -fd >/dev/null 2>&1 || true
)
log "tgoskits @ $(cd tgoskits && git rev-parse --short HEAD)  (= $(echo "$SUBMOD_SHA_WANT" | cut -c1-8))"

# ---------------------------------------------- step 2: apply F-eps
log "step 2/5  apply F-eps (vfork / posix_spawn fix) to tgoskits working tree"
if [[ ! -d patches/F-eps ]]; then
    fatal "patches/F-eps not found — are you on the right branch?"
fi
# F-eps is a raw unified diff (not git format-patch); use `git apply`.
(
    cd tgoskits
    for p in "$ROOT"/patches/F-eps/*.patch; do
        log "    applying $(basename "$p")"
        if git apply --check --reverse "$p" 2>/dev/null; then
            log "    (already applied, skipping)"
            continue
        fi
        if ! git apply --check "$p" 2>/dev/null; then
            fatal "F-eps patch $p cannot apply to current tgoskits tree (did Auto-OS's pinned commit change?)"
        fi
        git apply "$p"
    done
)

# ---------------------------------------------- step 3: build kernel
log "step 3/5  build StarryOS kernel (ARCH=$ARCH)"
# Make sure musl-cross is on PATH so objcopy works downstream
if [[ -d /opt/riscv64-linux-musl-cross/bin ]]; then
    export PATH="/opt/riscv64-linux-musl-cross/bin:$PATH"
fi
# Keep log level warn by default; flip to info only if caller overrides.
: "${AX_LOG:=warn}"
AX_LOG="$AX_LOG" bash "$SCRIPT_DIR/build.sh" ARCH="$ARCH"
KERNEL_ELF="$ROOT/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
[[ -f "$KERNEL_ELF" ]] || fatal "kernel ELF not produced: $KERNEL_ELF"
log "kernel ELF: $(ls -lh "$KERNEL_ELF" | awk '{print $5}')"

# ---------------------------------------------- step 4: build rust rootfs
ROOTFS="$ROOT/tests/selfhost/rootfs-selfhost-rust-riscv64.img"
if (( SKIP_ROOTFS )) && [[ -f "$ROOTFS" ]]; then
    log "step 4/5  rust rootfs — reuse existing $(ls -lh "$ROOTFS" | awk '{print $5}')"
else
    if [[ -f "$ROOTFS" ]]; then
        log "step 4/5  rust rootfs — already present, reusing (add --skip-rootfs to silence, or delete file to force rebuild)"
    else
        log "step 4/5  build rust rootfs (PROFILE=rust, ~700 MB, takes a few minutes)"
        sudo bash "$ROOT/tests/selfhost/build-selfhost-rootfs.sh" ARCH="$ARCH" PROFILE=rust
        [[ -f "$ROOTFS" ]] || fatal "rootfs image not produced: $ROOTFS"
    fi
fi
log "rootfs: $(ls -lh "$ROOTFS" | awk '{print $5}')"

# ---------------------------------------------- step 5: M5 demo
log "step 5/5  run M5 demo (rustc + cargo build inside starry guest)"
bash "$SCRIPT_DIR/demo-m5-rust.sh"

RESULT="$ROOT/.guest-runs/riscv64-m5/results.txt"
if [[ -f "$RESULT" ]] && grep -q "===M5-DEMO-PASS===" "$RESULT"; then
    echo
    echo "================================================================"
    printf "  \033[1;32m✓ M5 DEMO PASSED\033[0m\n"
    echo "  guest cargo build produced & ran its own RISC-V rust binary"
    echo "================================================================"
    echo
    echo "Highlights from the guest serial log:"
    grep -aE "rustc|cargo|Hello from|Finished|add_squares|sum =|M5-DEMO-PASS" "$RESULT" \
        | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g; s/^/    /' | tail -20
    echo
    echo "Full log: $RESULT"
    exit 0
else
    fatal "M5 demo did NOT end with ===M5-DEMO-PASS===. See $RESULT"
fi
