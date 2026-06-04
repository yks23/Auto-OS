# fix(starry): prepopulate cold user pages before copy

## Summary

- 修复 StarryOS `vm_read_slice` / `vm_write_slice` 在用户缓冲区是 untouched anonymous page 时可能错误返回 `EFAULT` 的问题。
- 在执行 `user_copy` 前，先检查并 populate 覆盖用户 slice 的页，避免内核 copy 路径第一次触碰 cold page 时失败。
- 对 nul-terminated 用户字符串读取也按页 populate，避免 `getcwd` / path-like copy 在 cold page 上被误判。
- 保留最新 `dev` 中的线程上下文防护：非用户线程上下文仍拒绝 user memory copy，不回退成 panic 或锁递归。
- 新增 StarryOS bugfix 回归测例 `/usr/bin/bug-usercopy-cold-page`。

## Root Cause

Rust/Cargo workload 会大量使用刚 `mmap` 或匿名分配、但尚未被用户态实际触碰的缓冲区。旧 usercopy 路径只做地址范围和权限检查，然后直接进入 `user_copy` / volatile string read。对于尚未实际分配物理页的 cold anonymous page，第一次触碰可能发生在内核 copy 路径中，导致本应由用户页错误处理/按需分配完成的访问被放大成 `EFAULT`。

这会影响类似 `read(fd, cold_page, len)`、`getcwd(cold_page, len)` 这类 Linux 用户态常见用法。Linux 语义下，只要用户缓冲区地址合法且有对应权限，内核写入用户页时应允许 demand paging 发生，而不是要求用户态先手动写一遍该页。

## Fix

- 新增 `prepare_user_memory()`，在 `VmIo::read/write` 进入 `user_copy` 前：
  - 校验用户地址范围；
  - 确认当前 task 是用户线程上下文；
  - 检查 address space 权限；
  - 对覆盖的 4K 页执行 `populate_area()`。
- `check_null_terminated()` 按页 populate 后再 volatile read 字符，避免字符串读路径在 cold page 上失败。
- 保留 `access_user_memory()` 包裹真实 `user_copy`，这样 race/COW 等后续 fault 仍走现有 faultable user memory 机制。

## Why These Areas

- `os/StarryOS/kernel/src/mm/access.rs` 是所有 `starry_vm::{vm_read_slice, vm_write_slice, vm_load_until_nul}` 的统一入口。修这里能覆盖 syscall 参数 copy、文件读写返回用户缓冲区、路径字符串读取等真实用户态 ABI。
- `qemu-smp1/bugfix` 是已有 StarryOS syscall/ABI 回归集合；这个问题是单核即可复现的 Linux ABI bug，不需要放到性能或 SMP 专用 group。

## Test Plan

Clean PR branch:

```sh
/private/tmp/tgoskits-usercopy-cold-v2
branch: fix/starry-usercopy-cold-page-v2
base: upstream/dev e9c421670
commits: 1520cd791, 8cf9df12a
```

Local validation:

```sh
git diff --check upstream/dev...HEAD
cargo fmt --check
CARGO_NET_OFFLINE=true cargo check -p starry-kernel \
  --target aarch64-unknown-none-softfloat \
  --no-default-features \
  --features 'dev-log,ext4,ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/smp'
cc -std=c11 -Wall -Wextra -Werror \
  test-suit/starryos/normal/qemu-smp1/bugfix/bug-usercopy-cold-page/c/src/main.c \
  -o /tmp/bug-usercopy-cold-page-host
```

Validation result:

- `git diff --check` PASS
- `cargo fmt --check` PASS
- `starry-kernel` AArch64 check PASS
- C regression source host syntax check PASS

## Test-suite

新增：

```text
test-suit/starryos/normal/qemu-smp1/bugfix/bug-usercopy-cold-page/
```

测例覆盖：

- `getcwd()` 写入 untouched anonymous page。
- `read(/dev/zero)` 写入 untouched anonymous page。

预期输出：

```text
PASS: getcwd writes to untouched anonymous page
PASS: read writes to untouched anonymous page
```

## Remaining Risk

- 这个 PR 只改变合法用户页的预填充时机，不放宽 `check_access()` / `can_access_range()` 权限判断。
- 它保留非线程上下文防护，因此不会重新引入 teardown/kernel-task usercopy panic 风险。
