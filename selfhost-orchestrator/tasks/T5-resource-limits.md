# T5：用户栈 / QEMU 内存 / FD 上限调整

## 目标仓库
- **上游**：`https://github.com/rcore-os/tgoskits`
- **基线分支**：`dev`
- **PR 目标分支**：`dev`
- **你的工作分支**：`cursor/selfhost-resource-limits-7c9d`

## 当前缺陷

| 项 | 现值 | self-hosting 需求 |
|---|---|---|
| `USER_STACK_SIZE` (`kernel/src/config/{x86_64,riscv64}.rs`) | 0x80000 (512 KiB) | ≥ 8 MiB（rustc 主线程默认 8 MiB） |
| `USER_HEAP_SIZE_MAX` 等 brk 上限 | 较小 | ≥ 2 GiB |
| QEMU `MEM` (`Makefile:11`) | 1G | 默认 4G，selfhost 模式 8G |
| QEMU `SMP` | 1 | 默认 4 |
| `AX_FILE_LIMIT` | 通常 1024 | 4096，selfhost 模式 8192 |
| `prlimit64(RLIMIT_STACK)` | 未真实生效 | 必须真实联动 |

## 验收标准

### A. 静态默认值调整

- `kernel/src/config/x86_64.rs` 与 `riscv64.rs`（以及 aarch64/loongarch 同名常量）：`USER_STACK_SIZE` → `0x800000`（8 MiB）。
- `USER_HEAP_SIZE_MAX`（如有此常量；按当前命名）→ 0x80000000（2 GiB）。
- `Makefile`：默认 `MEM := 1G` → `MEM := 4G`，注释保留旧值便于回滚。
- `Makefile`：增加 `SMP ?= 4`，并把 `SMP` 透传到 `make/qemu.mk`。
- `defconfig.toml` 中 `AX_FILE_LIMIT`（或类似 key）→ 4096。

### B. selfhost target

`Makefile` 新增 target：

```make
selfhost: APP_FEATURES := qemu,smp
selfhost: MEM := 8G
selfhost: SMP := 8
selfhost: rootfs
	$(MAKE) -C make run
```

让 `make ARCH=x86_64 selfhost` 直接拉满。

### C. `prlimit64` 真实联动

`tgoskits/os/StarryOS/kernel/src/syscall/task/`（`thread.rs` 或新建 `rlimit.rs`）：

- `RLIMIT_STACK`：`getrlimit` 返回 `USER_STACK_SIZE`；`setrlimit` 后新建线程的栈按新值分配（`pthread_create` → clone with stack）。
- `RLIMIT_AS`：`getrlimit` 返回当前 aspace 上限；`setrlimit` 后 `mmap`/`brk` 到达上限时返回 `ENOMEM`。
- `RLIMIT_DATA`：影响 `brk` 上限。
- `RLIMIT_NOFILE`：`dup`/`open`/`socket` 等到达上限时返回 `EMFILE`，已存在的 fd 不受影响。
- `RLIMIT_NPROC`：clone 到达进程数上限时 `EAGAIN`。
- 每个 `ProcessData` 持有一份 rlimit 表（fork 时继承，exec 时保留）。

### D. 测试

- `test_rlimit_stack.c`：`getrlimit(RLIMIT_STACK)` ≥ 8 MiB；递归函数能成功 alloca 4 MiB。
- `test_rlimit_nofile.c`：`setrlimit(RLIMIT_NOFILE, {32, 32})`，第 32 个 `dup` 必须 `EMFILE`。
- `test_rlimit_inherit_fork.c`：`setrlimit` 后 `fork`，子进程 `getrlimit` 必须看到同一值。

### E. 构建与回归

- `make ARCH=riscv64 build && make ARCH=x86_64 build` 通过。
- 现有 `make rootfs && make run` 仍能进 shell；CI 通过。

## 提交策略

1. `chore(starry/config): bump USER_STACK_SIZE to 8 MiB and heap max to 2 GiB`
2. `chore(starry/build): default QEMU mem=4G smp=4 and add selfhost target`
3. `feat(starry/syscall): make prlimit64 actually enforce RLIMIT_{STACK,AS,DATA,NOFILE,NPROC}`
4. `test(starry/syscall): rlimit enforcement tests`

PR 标题：`feat(starry): bump default resource limits and enforce prlimit64 for self-hosting`。
