# Draft PR: user-copy cold page prepopulate

- Branch: `fix/starry-usercopy-cold-page`
- Commit: `86d6d47c9 fix(starry): prepopulate user slices before copy`
- Head: `yks23:fix/starry-usercopy-cold-page`
- Base: `rcore-os/tgoskits:dev`
- Status: branch pushed; `gh pr create` blocked by `api.github.com` connection failure.

## Title

fix(starry): prepopulate user slices before copy

## Body

### 问题与根因

StarryOS 的切片式用户内存拷贝路径会在 `vm_read_slice` / `vm_write_slice` 中直接执行 `user_copy`。如果用户态传入的是合法但尚未实际分配物理页的匿名页，`user_copy` 会在 S-mode 触发缺页。

当前缺页处理需要进入进程地址空间并可能获取 `aspace` 锁；在 trap 路径中 IRQ 已关闭，这会把一次普通的用户缓冲区冷页缺页变成 atomic context 下的睡眠锁路径。M6 多核 guest cargo 构建中观察到类似的 atomic-context 锁竞争风险，冷页用户 buffer 是一个可以独立复现并修复的 OS 行为问题。

### 修复内容

- 在 `VmIo::read` / `VmIo::write` 执行 `user_copy` 前，先在正常 syscall 上下文检查并 `populate_area` 目标用户页。
- `user_copy` 本身改为 no-fault copy：预缺页后若仍发生异常，交给异常表 fixup 返回 `EFAULT`，避免在 IRQ-off trap 路径里再尝试拿 `aspace` 锁。
- 新增 StarryOS RISC-V grouped bugfix case：`/usr/bin/bug-usercopy-cold-page`。

### 各修改位置的使用原因

- `os/StarryOS/kernel/src/mm/access.rs`：这是 `starry_vm::VmIo` 的实现位置，也是 `vm_read_slice` / `vm_write_slice` 进入内核 user-copy 的公共入口。把预缺页放在这里可以覆盖 `read`、`getcwd` 等所有经由切片 user-copy 的 syscall。
- `test-suit/starryos/normal/qemu-smp1/bugfix/bug-usercopy-cold-page`：用 untouched anonymous page 作为用户缓冲区，覆盖“地址合法但物理页尚未建立”的冷页场景。
- `test-suit/starryos/normal/qemu-smp1/bugfix/qemu-riscv64.toml`：把新 case 加入 RISC-V grouped bugfix 队列，便于 CI 和助教复现。

### 测例设计

`bug-usercopy-cold-page` 做两件事：

1. `mmap` 一个匿名可读写页，不先触碰它，然后调用 `getcwd(buf, 4096)`，要求内核能把路径写入冷页。
2. 再 `mmap` 一个匿名冷页，调用 `read("/dev/zero", buf, 128)`，要求普通文件读也能写入冷页。

旧行为容易在 `user_copy` 中触发 S-mode 缺页并进入 IRQ-off 缺页处理；修复后这些页会先在 syscall 上下文被 populate，再进行 no-fault copy。

### Test plan

- `cargo fmt`
- `cargo fmt --check`
- `git diff --check upstream/dev`
- `cc -Wall -Wextra -Werror -c test-suit/starryos/normal/qemu-smp1/bugfix/bug-usercopy-cold-page/c/src/main.c -o /private/tmp/bug-usercopy-cold-page.o`

本地补充验证受环境限制：

- `cargo test -p axbuild discovers_grouped_case_commands_and_sorted_subcases`：当前本机 crates.io DNS/传输失败，无法更新 `sg200x-bsp 0.6.0` registry。
- `cargo xtask starry test qemu --arch riscv64 -g normal -c bugfix -l`：同样受 crates.io registry 更新失败影响。
- `docker run auto-os/starry:latest ...`：当前本机 Docker API 返回 500，无法使用容器缓存环境补测。

### 剩余风险

该修复把冷页 populate 前移到 user-copy 公共入口，能避免冷匿名页在 IRQ-off trap 路径中处理缺页。若用户缓冲区映射到复杂 file-backed 区域，`populate_area` 仍可能触发后端 I/O；这发生在正常 syscall 上下文，语义上比 trap 路径安全，但仍需要 CI 的完整 StarryOS bugfix group 覆盖。
