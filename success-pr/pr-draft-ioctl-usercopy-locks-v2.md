# fix(starry): avoid usercopy while holding ioctl locks

## Summary

- 修复 pipe `FIONREAD` 在持有 pipe buffer lock 时直接写用户指针的问题。
- 先在锁内读取 `occupied_len`，释放锁后再执行 `vm_write()`。
- 新增 StarryOS 回归测例覆盖 tty ioctl 与 pipe `FIONREAD`，确保 ioctl 用户拷贝路径不会在持锁状态下触发 faultable usercopy。

## Root Cause

`Pipe::ioctl(FIONREAD)` 旧代码把 `self.shared.buffer.lock().occupied_len()` 和 `(arg as *mut u32).vm_write(...)` 放在同一条表达式中。Rust 临时值生命周期会让 buffer lock guard 持续到表达式结束，因此 `vm_write()` 可能在仍持有 pipe buffer lock 时访问用户地址。

如果用户页是 cold page、COW page 或需要 fault handling，usercopy 可能 sleep/触发页错误。持内部文件锁进入 faultable usercopy 会增加死锁和 atomic-context 风险；这类问题在真实 ioctl/terminal/pipe workload 中很难直接从栈上看出来。

## Fix

将 pipe `FIONREAD` 拆成两步：

```rust
let occupied_len = self.shared.buffer.lock().occupied_len() as u32;
(arg as *mut u32).vm_write(occupied_len)?;
```

锁只覆盖内部状态读取，用户内存写入在锁释放后进行。

## Why These Areas

- `os/StarryOS/kernel/src/file/pipe.rs` 是 pipe `FIONREAD` 的实现位置。修这里可以直接消除持 pipe lock 做 usercopy 的风险。
- 新测例放在 `test-suit/starryos/normal/test-ioctl-usercopy-locks`，因为它验证的是 ioctl ABI 中“用户指针 copy 不应在内部锁下执行”的通用行为，不属于某一个单独 syscall group。

## Test Plan

Clean PR branch:

```sh
/private/tmp/tgoskits-ioctl-usercopy-v2
branch: fix/ioctl-usercopy-locks-v2
base: upstream/dev e9c421670
commit: dd3c3ed61
```

Local validation:

```sh
git diff --check upstream/dev...HEAD
cargo fmt --check
CARGO_NET_OFFLINE=true cargo check -p starry-kernel \
  --target aarch64-unknown-none-softfloat \
  --no-default-features \
  --features 'dev-log,ext4,ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/smp'
zig cc -target riscv64-linux-musl -Wall -Wextra -Werror \
  test-suit/starryos/normal/test-ioctl-usercopy-locks/c/src/main.c \
  -o /tmp/test-ioctl-usercopy-locks-riscv64
```

Validation result:

- `git diff --check` PASS
- `cargo fmt --check` PASS
- `starry-kernel` AArch64 check PASS
- C regression source Linux/musl syntax check PASS via `zig cc`

## Test-suite

新增：

```text
test-suit/starryos/normal/test-ioctl-usercopy-locks/
```

测例覆盖：

- tty `TCGETS`
- tty `TCGETS2`
- tty `TIOCGWINSZ`
- pipe `FIONREAD`

预期 PASS marker：

```text
TEST PASSED
```

## Remaining Risk

- 当前 PR 只修 pipe `FIONREAD` 的持锁 usercopy。其他 ioctl 实现若存在类似模式，应后续按同样原则逐个拆分，避免把多处风险混成一个大 PR。
