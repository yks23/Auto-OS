# Bugfix Summary

本文件把目前和 StarryOS 单核稳定性相关的修复整理成 PR 友好的摘要。状态只描述当前已知情况，不代表 upstream 已合并。

## #692 robust futex cleanup faults

- PR: <https://github.com/rcore-os/tgoskits/pull/692>
- symptom: 进程退出时遍历 robust futex list，如果用户态 robust list entry 或 pending entry 指向坏地址，内核清理路径需要容错，不能把用户态坏指针扩大成 kernel fatal。
- fix direction:
  - `exit_robust_list` 中对 `handle_futex_death` 的失败做 debug 记录后继续退出路径。
  - owner tid 按 `FUTEX_TID_MASK` 比较。
  - `list_op_pending` 清掉低位 marker 后再作为 robust list entry 处理。
  - `sys_futex` 按 `FUTEX_PRIVATE_FLAG` 区分 private/shared key，避免 wait queue 混用。
- CI issue found later:
  - clippy 报 `collapsible_if`，已用 `unwrap_or_else` 形式处理。
  - 原 pending-after-bad-head 测例预期过强：同一 C 测例在 Linux 上也失败。现在拆成“合法 list head 下 pending cleanup”和“坏 list head 不导致线程退出失败”两个 case。
- follow-up fix: 本地已推到远端 `e5b0b1b1565860338e081a973fab014d310394a9`，新 CI run `26011420020` 已启动。
- test case:
  - `test-suit/starryos/normal/qemu-smp1/syscall/test-futex-robust-list/c/src/main.c`
- local verification:
  - Linux 容器原生编译并运行 `test-futex-robust-list`，连续 3 次 `72 pass, 0 fail`
  - `rustfmt --edition 2024 --check os/StarryOS/kernel/src/task/ops.rs os/StarryOS/kernel/src/syscall/sync/futex.rs`
  - `cargo check -p starry-kernel --target x86_64-unknown-none --no-default-features`

## #693 vfork child-stack clone

- PR: <https://github.com/rcore-os/tgoskits/pull/693>
- symptom: 带 child stack 的 clone 路径不应按普通 `vfork` 父进程等待语义处理，否则会影响 `posix_spawn`/shell 类 workload。
- fix direction: 避免对 child-stack clone 使用 vfork wait 语义，并在文档/注释中解释和 Linux 语义差异。
- test case:
  - `test-suit/starryos/normal/qemu-smp1/syscall/test-vfork/c/src/main.c`
- CI note: 旧 run 中大量 container job 被取消，另有 `Test starry self-hosted board orangepi-5-plus / run_host` 失败；需要区分公共 runner 取消、板级测试问题和本 PR diff，再重跑确认。

## #694 IPv4-mapped IPv6 sockets

- PR: <https://github.com/rcore-os/tgoskits/pull/694>
- symptom: IPv6 socket 需要支持 IPv4-mapped address，且 `accept4` 返回 peer address 时需要正确包装成用户态 `sockaddr`。
- fix direction:
  - 地址解析支持 v4-mapped IPv6。
  - accepted peer address 走 `socket_addr_ex_for_user_name` 一类路径，避免返回格式不完整。
- test case:
  - `test-suit/starryos/normal/qemu-smp1/bugfix/bug-af-inet6-v4mapped/c/src/main.c`
- CI note: 旧 run 中 `Test starry x86_64 qemu / run_container` 已通过；`Test starry aarch64 qemu / run_container` 失败，riscv64/loongarch64 有取消项，需要看日志或重跑确认是否为架构/runner 问题。

## #695 rsext4 inode bitmap

- PR: <https://github.com/rcore-os/tgoskits/pull/695>
- symptom: ext4 inode bitmap 未初始化块被复用时需要正确处理，否则可能影响 inode allocation。
- fix direction: 识别并初始化 uninit inode bitmap，然后从该 block group 继续分配 inode，保留已初始化 bitmap 的原扫描行为。
- test case:
  - TODO: 从 rsext4/axfs-ng 现有测试中抽最小复现，或新增 inode allocation regression。
- CI note: 已观察到 CI 全绿，包括 StarryOS/ArceOS 多架构 QEMU container jobs。

## New local issue: checkpoint tar readback duplicate extents

- PR: not opened yet.
- symptom: M6 guest self-build succeeds, but the large checkpoint tar in the StarryOS-written rootfs cannot be read back directly by the Linux host.
- observed file: `/opt/tgoskits/.m6-checkpoints/target.tar`
- evidence:
  - direct host copy failed with `Input/output error`
  - `debugfs` showed duplicate/overlapping extents
  - `e2fsck -fy` on a copied image reported duplicate extent mapping and multiply-claimed blocks
- impact: the final kernel artifacts were recoverable after repairing a copy of the image, so this is a filesystem writeback/readback follow-up rather than a compile failure.
- PR direction:
  - first isolate a small rsext4/axfs-ng regression that creates and rereads a large file or tar-like sequential write
  - then submit an OS/filesystem PR with that focused test
- test case:
  - TODO: minimize from the checkpoint tar workflow; do not submit the full M6 script as the upstream test.
