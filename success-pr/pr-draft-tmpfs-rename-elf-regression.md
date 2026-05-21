# test(starry): regress tmpfs rename exec ELF

## 问题

8 核 M6 tmpfs target 路线中，cargo 生成 build script 后立即执行最终路径，出现 `Exec format error (os error 8)`。同一内核和 workload 切到 ext4 target 后已经越过这个早期失败点。

这说明问题更像 tmpfs 文件写入/rename/readback/exec 一致性，而不是通用 ELF loader 或 cargo 配置问题。

## 根因

tmpfs 普通文件内容依赖 page cache。若 page cache 身份和目录项位置绑定，cargo 的“写临时文件 -> rename 成最终可执行文件 -> exec 最终路径”模式可能暴露一个元数据正确但 ELF 内容读回错误的最终路径。

最新 `upstream/dev` 已经有 `DirNode::rename()` 迁移旧 entry `user_data` 的修复形态，因此本 PR 只补 regression，避免重复提交内核修复。

## 修复

- 在 BusyBox grouped tests 中加入 tmpfs renamed ELF regression。
- 测试把 `/bin/busybox` 复制到 tmpfs 临时路径，rename 到最终路径。
- 立刻读取最终路径前 4 字节，要求为 ELF magic `7f454c46`。
- 再执行最终路径，要求输出成功 marker。

## 使用原因

- BusyBox 是 rootfs 内稳定存在的 ELF，测试不依赖额外工具链。
- tmpfs 路径直接覆盖 cargo build-script 的关键文件系统模式。
- 单核 qemu-smp1 即可验证，不需要完整 M6。

## Test plan

- `sh -n test-suit/starryos/normal/qemu-smp1/busybox/sh/busybox-tests.sh`
- `git diff --check upstream/dev..HEAD`

待补：

- `cargo xtask starry test qemu --arch riscv64 --test-group normal --test-case qemu-smp1/busybox`

## 风险

这是 test-only PR，不改变内核行为。风险主要是 BusyBox grouped test 运行时间略增。
