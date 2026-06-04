#!/bin/sh
# 容器入口：仅 exec 传入命令。
#
# 不在此处调用 register-binfmt：在 --privileged 下它会写宿主/VM 的 binfmt_misc，
# 若规则与当前架构交互异常，会导致紧接着的 exec bash 出现 “Exec format error”。
# binfmt 改由 scripts/reproduce-in-container.sh（及 rootfs 脚本）在需要 chroot/qemu-user 时再注册。
set -e
exec "$@"
