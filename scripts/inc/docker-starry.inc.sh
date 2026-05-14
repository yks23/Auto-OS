#!/usr/bin/env bash
# shellcheck shell=bash
# 供 guest-onecrate / 快速矩阵等脚本 source：统一 Starry 实验用 Docker 镜像、平台与预检。
#
# 环境变量（可选）：
#   DOCKER_STARRY_IMAGE   默认 auto-os/starry:latest
#   DOCKER_PLATFORM       默认 linux/amd64（与常见 CI/镜像一致；Apple Silicon 宿主建议显式指定）
#   GUEST_ONECRATE_SKIP_DOCKER_PREFLIGHT=1  跳过预检（仅当你确定 Docker 健康时使用）

: "${DOCKER_STARRY_IMAGE:=auto-os/starry:latest}"
# On macOS arm64, the linux/amd64 emulation layer (Rosetta/QEMU) can have issues
# with runc/container operations. The existing image is linux/amd64 so we still
# use it, but callers should prefer the macOS native QEMU path when possible.
if [[ -z "${DOCKER_PLATFORM:-}" ]]; then
  DOCKER_PLATFORM="linux/amd64"
  export DOCKER_PLATFORM
fi

docker_starry_preflight() {
  if [[ "${GUEST_ONECRATE_SKIP_DOCKER_PREFLIGHT:-0}" == "1" ]]; then
    echo "[docker-starry] preflight skipped (GUEST_ONECRATE_SKIP_DOCKER_PREFLIGHT=1)" >&2
    return 0
  fi
  local err
  err="$(mktemp)"
  if ! docker run --rm --platform "${DOCKER_PLATFORM}" "${DOCKER_STARRY_IMAGE}" true 2>"${err}"; then
    echo "[docker-starry] preflight FAILED: docker run --rm ${DOCKER_STARRY_IMAGE} true" >&2
    cat "${err}" >&2 || true
    if grep -qE 'blob sha256:|input/output error|No space left on device' "${err}" 2>/dev/null; then
      echo "[docker-starry] hint: Docker Desktop 存储损坏或磁盘满。请 Troubleshoot -> Clean/Purge data 或释放磁盘后重试。" >&2
    fi
    rm -f "${err}"
    return 125
  fi
  rm -f "${err}"
  echo "[docker-starry] preflight ok image=${DOCKER_STARRY_IMAGE} platform=${DOCKER_PLATFORM}" >&2
  return 0
}
