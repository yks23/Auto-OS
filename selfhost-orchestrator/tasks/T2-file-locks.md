# T2：flock + fcntl 记录锁真实实现

## 目标仓库
- **fork（你 push 到这里）**：`https://github.com/yks23/tgoskits`
- **upstream（只读基线）**：`https://github.com/rcore-os/tgoskits`
- **基线分支**：`upstream/dev`
- **PR 目标**：`yks23/tgoskits` 的 `selfhost-dev` 分支
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

PR 标题：`feat(starry): real flock + fcntl record locks for self-hosting`，目标 `yks23/tgoskits` 的 `selfhost-dev` 分支。
