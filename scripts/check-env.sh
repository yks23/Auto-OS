#!/usr/bin/env bash
# check-env.sh — StarryOS self-hosting 复现环境检测
#
# 只读检测脚本：列出所有必需工具 + 实际版本，用 PASS / WARN / FAIL 打分。
# 不会修改任何东西。需要装东西去看 setup-env.sh 或 REPRODUCE.md。
#
# 用法：  bash scripts/check-env.sh
# 退出码：0 = 全 PASS；非 0 = 有 FAIL

set -u

PASS=0; WARN=0; FAIL=0
row() {
    local status="$1"; local name="$2"; local detail="$3"
    case "$status" in
        PASS) printf "  \033[32mPASS\033[0m  %-28s %s\n" "$name" "$detail"; PASS=$((PASS+1));;
        WARN) printf "  \033[33mWARN\033[0m  %-28s %s\n" "$name" "$detail"; WARN=$((WARN+1));;
        FAIL) printf "  \033[31mFAIL\033[0m  %-28s %s\n" "$name" "$detail"; FAIL=$((FAIL+1));;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }
ver()  { "$@" 2>&1 | head -n 1 | tr -d '\r'; }

echo "================================================================"
echo "  StarryOS self-hosting — environment check"
echo "================================================================"

echo
echo "[1/6] host OS & arch"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    row PASS "os-release"       "${PRETTY_NAME:-unknown}"
else
    row WARN "os-release"       "file missing, unknown distro"
fi
row PASS "arch"                 "$(uname -m)"
row PASS "kernel"               "$(uname -r)"

echo
echo "[2/6] host toolchain (build starry + rootfs)"
for t in git curl tar xz sudo chroot make gcc mkfs.ext4 python3; do
    if have "$t"; then row PASS "$t" "$(command -v "$t")"
    else               row FAIL "$t" "not found — install with setup-env.sh"
    fi
done

# rustup / cargo
if have rustup; then
    row PASS "rustup"           "$(ver rustup --version)"
else
    row FAIL "rustup"           "not found — required for kernel cross build"
fi
if have cargo; then
    row PASS "cargo (host)"     "$(ver cargo --version)"
else
    row FAIL "cargo (host)"     "not found"
fi

# tgoskits pins a specific nightly via rust-toolchain.toml; rustup will auto-fetch
# it on first `cargo build`. Check for the pinned channel specifically when we
# can read the file.
ROOT_CHK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINNED_TC=""
for f in \
    "$ROOT_CHK/tgoskits/rust-toolchain.toml" \
    "$ROOT_CHK/tgoskits/rust-toolchain" \
    "$ROOT_CHK/tgoskits/os/StarryOS/rust-toolchain.toml" \
    ; do
    if [[ -r "$f" ]]; then
        PINNED_TC="$(awk -F'"' '/^channel/ {print $2; exit}' "$f" 2>/dev/null)"
        [[ -n "$PINNED_TC" ]] && break
    fi
done
if [[ -n "$PINNED_TC" ]]; then
    if have rustup && rustup toolchain list 2>/dev/null | grep -q "^$PINNED_TC"; then
        row PASS "rust toolchain ($PINNED_TC)"  "installed (pinned by tgoskits)"
        RUSTUP_QUERY="rustup +$PINNED_TC"
    else
        row WARN "rust toolchain ($PINNED_TC)"  "not yet installed — will be auto-fetched on first build"
        RUSTUP_QUERY="rustup"
    fi
else
    RUSTUP_QUERY="rustup"
fi

# riscv64 kernel target — check against the pinned toolchain if we have one
if have rustup && $RUSTUP_QUERY target list --installed 2>/dev/null | grep -q '^riscv64gc-unknown-none-elf$'; then
    row PASS "rust target riscv64gc-unknown-none-elf" "installed"
elif [[ -n "$PINNED_TC" ]]; then
    row WARN "rust target riscv64gc-unknown-none-elf" "not installed — rustup will fetch it on first build"
else
    row FAIL "rust target riscv64gc-unknown-none-elf" "missing — rustup target add riscv64gc-unknown-none-elf"
fi

# llvm-tools / rust-src (needed for build-std + linker script)
if have rustup && $RUSTUP_QUERY component list --installed 2>/dev/null | grep -q '^rust-src'; then
    row PASS "rust component rust-src"       "installed"
else
    row WARN "rust component rust-src"       "missing — will be auto-fetched on first build"
fi
if have rustup && $RUSTUP_QUERY component list --installed 2>/dev/null | grep -q '^llvm-tools'; then
    row PASS "rust component llvm-tools"     "installed"
else
    row WARN "rust component llvm-tools"     "missing — will be auto-fetched on first build"
fi

echo
echo "[3/6] musl cross toolchain (for guest userland binaries)"
MUSL_CROSS_PATH=""
for p in /opt/riscv64-linux-musl-cross/bin riscv64-linux-musl- ; do
    if [[ -d "$p" ]] && [[ -x "$p/riscv64-linux-musl-gcc" ]]; then
        MUSL_CROSS_PATH="$p"
        break
    fi
done
if [[ -n "$MUSL_CROSS_PATH" ]]; then
    row PASS "riscv64-linux-musl-gcc"       "$("$MUSL_CROSS_PATH/riscv64-linux-musl-gcc" --version | head -1)"
    row PASS "riscv64-linux-musl-objcopy"   "$("$MUSL_CROSS_PATH/riscv64-linux-musl-objcopy" --version | head -1)"
elif have riscv64-linux-musl-gcc; then
    row PASS "riscv64-linux-musl-gcc"       "$(ver riscv64-linux-musl-gcc --version)"
else
    row FAIL "riscv64-linux-musl-gcc"       "not found — setup-env.sh will fetch arceos prebuilt"
fi

echo
echo "[4/6] QEMU (for running the guest)"
if have qemu-system-riscv64; then
    row PASS "qemu-system-riscv64"          "$(ver qemu-system-riscv64 --version)"
else
    row FAIL "qemu-system-riscv64"          "not found — apt install qemu-system-misc"
fi
if have qemu-riscv64-static; then
    row PASS "qemu-riscv64-static"          "$(ver qemu-riscv64-static --version)"
else
    row FAIL "qemu-riscv64-static"          "not found — apt install qemu-user-static"
fi
if [[ -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]]; then
    if grep -q enabled /proc/sys/fs/binfmt_misc/qemu-riscv64 2>/dev/null; then
        row PASS "binfmt_misc qemu-riscv64"  "enabled"
    else
        row WARN "binfmt_misc qemu-riscv64"  "registered but disabled"
    fi
else
    row FAIL "binfmt_misc qemu-riscv64"     "not registered — setup-env.sh handles it"
fi

echo
echo "[5/6] repo layout"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/PIN.toml" ]]; then
    row PASS "PIN.toml"                     "$ROOT/PIN.toml"
else
    row FAIL "PIN.toml"                     "missing — repo layout broken"
fi
if [[ -d "$ROOT/tgoskits/.git" || -f "$ROOT/tgoskits/.git" ]]; then
    SUBMOD_SHA="$(cd "$ROOT/tgoskits" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    SUBMOD_URL="$(cd "$ROOT/tgoskits" && git config --get remote.origin.url 2>/dev/null || echo unknown)"
    row PASS "tgoskits submodule"           "checkout at $SUBMOD_SHA"
    if [[ "$SUBMOD_URL" == *"yks23/tgoskits"* ]]; then
        row PASS "tgoskits origin"          "$SUBMOD_URL"
    else
        row WARN "tgoskits origin"          "$SUBMOD_URL  (Auto-OS expects yks23/tgoskits — run: git submodule sync tgoskits && git submodule update --init tgoskits)"
    fi
else
    row FAIL "tgoskits submodule"           "not initialised — git submodule update --init tgoskits"
fi
for d in patches/F-eps patches/T1 patches/F-alpha scripts/demo-m5-rust.sh; do
    if [[ -e "$ROOT/$d" ]]; then row PASS "$d"                   "present"
    else                         row FAIL "$d"                   "missing"
    fi
done

echo
echo "[6/6] disk space / memory"
FREE_G=$(df -BG "$ROOT" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}')
if [[ -n "${FREE_G:-}" ]]; then
    if [[ "$FREE_G" -ge 10 ]]; then row PASS "free disk (repo fs)"  "${FREE_G}G"
    else                            row WARN "free disk (repo fs)"  "${FREE_G}G (need >=10G for rust rootfs)"
    fi
fi
TOTAL_MB=$(awk '/^MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "$TOTAL_MB" -ge 4096 ]]; then row PASS "host RAM"           "${TOTAL_MB} MiB"
else                                row WARN "host RAM"           "${TOTAL_MB} MiB (QEMU M5 demo wants >=2G free)"
fi

echo
echo "================================================================"
echo "  Summary: ${PASS} PASS, ${WARN} WARN, ${FAIL} FAIL"
echo "================================================================"

if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "There are ${FAIL} FAILed checks. Run:"
    echo "    sudo bash scripts/setup-env.sh"
    echo "to auto-install missing pieces, or follow docs/REPRODUCE.md manually."
    exit 1
fi
exit 0
