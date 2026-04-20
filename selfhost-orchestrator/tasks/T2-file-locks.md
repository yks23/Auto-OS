# T2：flock + fcntl 记录锁真实实现

## 目标仓库
- **工作仓**：`https://github.com/yks23/Auto-OS`（你 push 到这里）
- **tgoskits 子模块**：只读，pin 在 PIN.toml 指定的 commit；**不 push tgoskits**
- **PR 目标**：`yks23/Auto-OS` 的 `main` 分支
- **交付物**：`patches/Tn-slug/*.patch` + `tests/selfhost/test_*.c`
- **你的工作分支**：`cursor/selfhost-file-locks-7c9d`

## 当前缺陷
`tgoskits/os/StarryOS/kernel/src/syscall/fs/fd_ops.rs`：

```rust
// 245-249
F_SETLK | F_SETLKW => Ok(0),
F_OFD_SETLK | F_OFD_SETLKW => Ok(0),
F_GETLK | F_OFD_GETLK => { ... l_type = F_UNLCK; Ok(0) }

// 308
pub fn sys_flock(_fd, _op) -> AxResult<isize> { Ok(0) }

// ~302  未知 cmd 兜底
_ => { warn!("unsupported fcntl ..."); Ok(0) }
```

**假成功**对 cargo / dpkg / SQLite 是灾难——并发写时不会真的互斥。

## 验收标准

### A. BSD `flock`

新增 `tgoskits/os/StarryOS/kernel/src/file/flock.rs`：

1. 按 inode 标识 `(dev_id, inode_id)` 维护锁表；锁表用 `SpinNoIrq<HashMap<...>>`。
2. 每个 inode 有 state：`Unlocked` / `Shared(Vec<owner_fd>)` / `Exclusive(owner_fd)`。
3. 支持 `LOCK_SH`、`LOCK_EX`、`LOCK_UN`、`LOCK_NB`。
4. `LOCK_NB` 冲突时返回 `EWOULDBLOCK`；阻塞模式用 wait queue。
5. 关闭 fd 时自动释放该 fd 的 flock（在 `FileLike::Drop` 或 `close` 路径调用）。
6. 进程被 SIGKILL 退出时随 fd 关闭一同释放（无需特殊处理）。

### B. POSIX `fcntl(F_SETLK/F_SETLKW/F_GETLK)` + OFD 锁

新增 `tgoskits/os/StarryOS/kernel/src/file/record_lock.rs`：

1. 按 inode 维护"锁段列表"，每段 `{start, end, type:R/W, owner: PID 或 OFD}`。
2. 同一 owner 重叠区间合并；不同 owner 的 R+R 共存，R+W 或 W+W 冲突。
3. `F_SETLK`：冲突立刻返回 `EAGAIN`。
4. `F_SETLKW`：冲突时阻塞，可被信号中断（返回 `EINTR`）。
5. `F_GETLK`：返回冲突的第一个段，否则置 `l_type = F_UNLCK`。
6. **OFD 锁**：owner 是 file description（即 open file struct 指针/id），跨 fork 共享，跨 dup 共享；与 POSIX 进程锁分开维护。
7. 进程退出时遍历释放该进程的所有 POSIX record lock；OFD 锁随 file description 引用计数到 0 时释放。

### C. fcntl 杂项

- 未知 `cmd` 改返回 `EINVAL`，**不再** `Ok(0)`。
- `F_SETLEASE / F_GETLEASE` 暂用 `EINVAL` 即可。
- `F_SETOWN / F_GETOWN / F_SETSIG / F_GETSIG` 至少正确存取（异步 IO 的 owner），不需要真触发 SIGIO。

### D. 测试

新增 C 测试在现有用户态测试目录：

- `test_flock_excl.c`：两个进程 fork，子拿 `LOCK_EX`，父用 `LOCK_NB|LOCK_EX` 必须返回 EWOULDBLOCK；子 unlock 后父能拿到。
- `test_fcntl_setlk_overlap.c`：进程 A 锁 [0, 100) 的 W；进程 B `F_GETLK` [50, 200) 应当看到冲突。
- `test_fcntl_ofd.c`：父 `F_OFD_SETLK` 后 `fork`，子的同一 fd 看到的 OFD 锁应当被识别为"自己的"（OFD 跨 fork 共享）。
- `test_flock_close_release.c`：close fd 后锁立即释放。

### E. 构建

`make ARCH=riscv64 build && make ARCH=x86_64 build` 不报错；现有 CI 通过。

## 提交策略

按 commit 拆：
1. `feat(file): add BSD flock implementation`
2. `feat(file): add POSIX record lock + OFD lock implementation`
3. `fix(syscall): wire flock/fcntl to real lock implementations and return EINVAL for unknown cmds`
4. `test(starry): add file lock test cases`

PR 标题：`feat(starry): real flock + fcntl record locks for self-hosting`，目标 `yks23/Auto-OS` 的 `main` 分支。

---

## 🧪 测试填充责任（强制）

**重要更新（Director, 2026-04-18）**：本任务 PR #2 已经把测试**骨架**写好了
（ 全部 main 默认 `pass()`，含 TODO Plan）。
你必须在你的 PR 里**填满**与 T2 相关的所有骨架文件，让 main 真正
验证对应 syscall 的行为。

### 你必须填充的骨架文件

见 `selfhost-orchestrator/DETAILED-TEST-MATRIX.md` 的 §T2：flock + fcntl 记录锁 章节。

**对每个测试**：
1. 打开 `tests/selfhost/test_xxx.c`（或 .sh）
2. 把 main 里 `/* TODO(T2): ... */` 注释保留作为 plan 文档
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

测试代码与 patches/T2-*/ 内的实现代码必须在**同一个 PR** 内提交。
review 时会要求测试 PASS 才合并。本机 `make ARCH=...` 编测试可能
因 musl-gcc 缺失 SKIP，那就在 PR 里说明，CI 上验证。

### Commit 拆分建议

1. `feat(patches/T2): <实现>`
2. `test(selfhost/T2): fill in skeleton test_<xxx>.c`（每填一组测试可以一个 commit）
3. （可选）`docs(T2): note any deviation from DETAILED-TEST-MATRIX`

