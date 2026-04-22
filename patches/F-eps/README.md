# F-ε — Real `vfork` / `posix_spawn` semantics for StarryOS

**目标 milestone**：M5 (`cargo build hello.rs` in guest).

## 问题

原 `do_clone` 把 `CLONE_VFORK` 当退化 fork：

```rust
if flags.contains(CloneFlags::VFORK) {
    flags.remove(CloneFlags::VM);   // ← bug
}
```

后果：
1. **musl `posix_spawn`**（child 用 mmap 出来的独立 stack）：clone 退化成 full fork → child 的 stack pointer 在 child 的复制 aspace 里没映射 → child SIGSEGV。
2. **真 vfork(2)**（child 用 parent 的 stack）：父子在**共享** aspace 上 race；child 的 `execve` 调 `uspace.clear()` 把 parent 的 mappings 全擦了 → parent 一返回用户态就 SEGV。
3. 修了上面两个之后还有第三个：execve 切了硬件 SATP 但**没改 task ctx 里的 satp**，scheduler `switch_to(parent)` 时认为 satp 没变就跳过 satp 写 → parent 实际跑在 child 的新 PT 上 → page fault at 0xe4。

整条 cargo / rustc / posix_spawn 链路全部依赖这条 bug 修。

## 修法

| 文件 | 改动 |
|---|---|
| `os/StarryOS/kernel/src/syscall/task/clone.rs` | 识别 `CLONE_VFORK`，**保留** `CLONE_VM`；bare-vfork (stack=0) 时父亲 block 在 `PollSet`，posix_spawn 风格 (stack≠0) 父亲不阻塞，由 musl 用 CLOEXEC pipe 同步。 |
| `os/StarryOS/kernel/src/task/mod.rs` | `Thread` 加 `vfork_done: spin::Mutex<Option<Arc<PollSet>>>` 槽，`release_vfork_parent()` helper；`ProcessData::replace_aspace()` 给 vfork detach 用的 unsafe helper。 |
| `os/StarryOS/kernel/src/task/ops.rs` | `do_exit` 也调 `release_vfork_parent()`（child `_exit` 应释放父亲）。 |
| `os/StarryOS/kernel/src/syscall/task/execve.rs` | 进入 execve 时若 `Arc::strong_count(&proc_data.aspace) > 1`，建 `new_user_aspace_empty()` + `copy_from_kernel()`，**unsafe 替换** `proc_data.aspace`，写硬件 satp + flush_tlb，**同步**写 `current().ctx.satp = new_pt_root`。`apply_execve_image` 末尾调 `release_vfork_parent()`。 |
| `os/arceos/modules/axtask/src/task.rs` | 暴露 `pub unsafe fn ctx_mut_raw(&self) -> *mut TaskContext`，让 starry-kernel 的 execve 能 fix-up saved task context。 |

## 验证

```
test_clone_vm        : T1 clone(VM|VFORK|SIGCHLD,stack)  → returns, no parent SEGV
test_vfork_exec      : vfork()+execve(/bin/true)         → PASS
                       posix_spawn(/bin/true)            → PASS
demo-m5-rust.sh      : rustc hello.rs                    → exit=0, "1..=10 sum = 55"
                       cargo --offline build --release   → "Finished `release` profile"
                       hellocargo binary runs            → "add_squares(3, 4) = 25"
```

## 适用范围

适用于 riscv64 + x86_64 (两者都是单一 SATP/CR3 给 user+kernel)。aarch64/loongarch64 因为有独立 user PT 寄存器，理论上也兼容（detach 走的是同一份 `copy_from_kernel`，arch 已 cfg-out）。

## 应用

```bash
bash scripts/apply-patches.sh
```
（patches/integration-build.sh 应自动 pick up patches/F-eps/）
