#!/usr/bin/env bash
# setup-env.sh — install docker on the host. That's the entire dependency.
#
# All actual build / run dependencies (rust nightly, qemu, musl-cross, binfmt,
# tgoskits sources, ...) live inside the Docker image — see Dockerfile and
# scripts/reproduce-all.sh.
#
# Usage:
#   sudo bash scripts/setup-env.sh

set -euo pipefail

SUDO=""
if [[ $(id -u) -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "error: not root and no sudo" >&2
        exit 1
    fi
fi
log() { printf '[setup-env] %s\n' "$*"; }

if command -v docker >/dev/null 2>&1; then
    log "docker is already installed: $(docker --version)"
else
    if command -v apt-get >/dev/null 2>&1; then
        log "installing docker.io via apt-get"
        $SUDO apt-get update -y
        $SUDO apt-get install -y docker.io
    elif command -v dnf >/dev/null 2>&1; then
        log "installing docker via dnf"
        $SUDO dnf install -y docker
    else
        log "error: only apt-get and dnf are auto-handled."
        log "       please install docker manually:"
        log "       https://docs.docker.com/engine/install/"
        exit 1
    fi
fi

# Make sure dockerd is running. Try systemd first, fall back to launching it
# directly (cloud-agent / nested containers without systemd).
if $SUDO docker info >/dev/null 2>&1; then
    log "docker daemon is up and running"
elif command -v systemctl >/dev/null 2>&1 && $SUDO systemctl start docker 2>/dev/null; then
    log "started docker via systemd"
else
    log "no systemd — launching dockerd manually in the background"
    log "  (cloud-agent / nested containers; uses --storage-driver=vfs --iptables=false)"
    $SUDO dockerd --iptables=false --bridge=none --ip6tables=false \
        --storage-driver=vfs >/tmp/dockerd.log 2>&1 &
    sleep 5
    $SUDO docker info >/dev/null 2>&1 || {
        log "ERROR: dockerd refused to start. See /tmp/dockerd.log"
        exit 1
    }
fi

log "done. Verify with: bash scripts/check-env.sh"
