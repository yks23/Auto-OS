# T5：用户栈 / QEMU 内存 / FD 上限调整

## 目标仓库
- **工作仓**：`https://github.com/yks23/Auto-OS`（你 push 到这里）
- **tgoskits 子模块**：只读，pin 在 PIN.toml 指定的 commit；**不 push tgoskits**
- **PR 目标**：`yks23/Auto-OS` 的 `main` 分支
- **交付物**：`patches/Tn-slug/*.patch` + `tests/selfhost/test_*.c`
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

---

## 🧪 测试填充责任（强制）

**重要更新（Director, 2026-04-18）**：本任务 PR #2 已经把测试**骨架**写好了
（ 全部 main 默认 `pass()`，含 TODO Plan）。
你必须在你的 PR 里**填满**与 T5 相关的所有骨架文件，让 main 真正
验证对应 syscall 的行为。

### 你必须填充的骨架文件

见 `selfhost-orchestrator/DETAILED-TEST-MATRIX.md` 的 §T5：资源限制（rlimit）+ Makefile 默认值调整 章节。

**对每个测试**：
1. 打开 `tests/selfhost/test_xxx.c`（或 .sh）
2. 把 main 里 `/* TODO(T5): ... */` 注释保留作为 plan 文档
3. **删掉** `pass(); return 0;` 占位
4. 按 DETAILED-TEST-MATRIX 的 Action / Expected return / Expected errno / Side effect 四列实现真正的验证逻辑
5. 用 `fail("...")` 在任意 assert 失败时立即 exit 1
6. 全部 assert 通过才 `pass();`

### 质量硬指标

- 每个 syscall 调用都必须**检查返回值**，失败时 `fail("syscall_name failed: %s", strerror(errno))`
- **errno 必须精确匹配**（不能用 `errno != 0` 这种宽松检查）
- **所有创建的临时文件、子进程、fd 在 fail/pass 前必须清理**（不要污染下一个测试的环境）
- 测试**幂等**：连续跑两次结果一致
- 不要依赖测试间顺序，每个测试自己 setup 自己 teardown

### Spec 引用

骨架文件顶部已经从 TEST-MATRIX.md 复制了 Spec 注释。如果你的实现细节
与 DETAILED-TEST-MATRIX 不一致（例如 errno 选择不同），**优先服从
DETAILED-TEST-MATRIX**，并在 PR 描述里说明理由。

### 测试与实现同 PR 提交

测试代码与 patches/T5-*/ 内的实现代码必须在**同一个 PR** 内提交。
review 时会要求测试 PASS 才合并。本机 `make ARCH=...` 编测试可能
因 musl-gcc 缺失 SKIP，那就在 PR 里说明，CI 上验证。

### Commit 拆分建议

1. `feat(patches/T5): <实现>`
2. `test(selfhost/T5): fill in skeleton test_<xxx>.c`（每填一组测试可以一个 commit）
3. （可选）`docs(T5): note any deviation from DETAILED-TEST-MATRIX`

