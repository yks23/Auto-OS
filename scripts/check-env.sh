#!/usr/bin/env bash
# check-env.sh — verify the host has docker so reproduce-all.sh can run.
#
# That's it. Everything else (rust nightly, musl-cross, qemu, binfmt, …) lives
# inside the Dockerfile-built image, so the user does not have to install it.

set -u

PASS=0; WARN=0; FAIL=0
row() {
    local status="$1"; local name="$2"; local detail="$3"
    case "$status" in
        PASS) printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$detail"; PASS=$((PASS+1));;
        WARN) printf "  \033[33mWARN\033[0m  %-32s %s\n" "$name" "$detail"; WARN=$((WARN+1));;
        FAIL) printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "$detail"; FAIL=$((FAIL+1));;
    esac
}
have() { command -v "$1" >/dev/null 2>&1; }
ver()  { "$@" 2>&1 | head -n 1 | tr -d '\r'; }

echo "================================================================"
echo "  StarryOS self-host — host environment check"
echo "  (everything build-related lives inside the Docker image)"
echo "================================================================"

echo
echo "[1/3] host OS"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    row PASS "os-release"           "${PRETTY_NAME:-unknown}"
fi
row PASS "arch"                     "$(uname -m)"

echo
echo "[2/3] required tools"
if have docker; then
    row PASS "docker"               "$(ver docker --version)"
else
    row FAIL "docker"               "not found — install: https://docs.docker.com/engine/install/"
fi
if have git; then
    row PASS "git"                  "$(ver git --version)"
else
    row FAIL "git"                  "not found"
fi
if have curl; then
    row PASS "curl"                 "$(ver curl --version)"
else
    row WARN "curl"                 "not found (only needed if downloading prebuilt rootfs)"
fi

# Docker daemon reachable?
if have docker; then
    if docker info >/dev/null 2>&1; then
        row PASS "docker daemon"        "reachable"
    elif sudo -n docker info >/dev/null 2>&1; then
        row PASS "docker daemon"        "reachable via sudo"
    else
        row FAIL "docker daemon"        "not running (try: sudo systemctl start docker)"
    fi
fi

echo
echo "[3/3] repo layout"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in Dockerfile docker/register-binfmt.sh scripts/reproduce-all.sh scripts/build.sh tests/selfhost/build-selfbuild-rootfs.sh; do
    if [[ -e "$ROOT/$f" ]]; then row PASS "$f"                   "present"
    else                          row FAIL "$f"                   "missing — wrong branch?"
    fi
done
if [[ -d "$ROOT/tgoskits/.git" || -f "$ROOT/tgoskits/.git" ]]; then
    SUBMOD_SHA="$(cd "$ROOT/tgoskits" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    row PASS "tgoskits submodule"       "checkout at $SUBMOD_SHA"
else
    row WARN "tgoskits submodule"       "not initialised — reproduce-all.sh will init it"
fi

echo
echo "================================================================"
echo "  Summary: ${PASS} PASS, ${WARN} WARN, ${FAIL} FAIL"
echo "================================================================"

if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "Install docker (only requirement) and re-run."
    exit 1
fi
exit 0
