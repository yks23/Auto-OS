# PR Review 理由

以下 4 个 PR 均基于 `rcore-os/tgoskits` 的 `fixbug-based-dev` 分支，修复的是**已实现但逻辑错误**的 bug，不是未实现的 feature。

---

## PR 1: fix(membarrier): use atomic fence instead of compiler_fence

**分支**: `fix/membarrier-atomic-fence`  
**文件**: `os/StarryOS/kernel/src/syscall/sync/membarrier.rs`  
**改动**: 1 行

### Bug 描述

`sys_membarrier` 的非 QUERY 路径使用了 `compiler_fence(Ordering::SeqCst)`。`compiler_fence` 仅阻止编译器重排指令，**不会生成任何 CPU 内存屏障指令**（如 riscv64 的 `fence iorw,iorw`、x86_64 的 `mfence`、aarch64 的 `dmb ish`）。

### 为什么是 bug 不是"没实现"

membarrier 系统调用已经完整实现了（有 QUERY 返回支持的命令、有 flags 校验、有 match 分发），只是在执行屏障的那一步**选错了原语**。就像一个函数逻辑写对了但最后 `return` 了错误的值。

### 影响

在多核（`SMP=2+`）场景下，用户态的 RCU、hazard pointer、jemalloc 等依赖 `membarrier(2)` 保证跨核内存可见性的同步库，可能出现**极难复现的数据竞争**。单核场景下无影响（编译器屏障在单核上足够）。

### 修复

```diff
-use core::sync::atomic::{Ordering, compiler_fence};
+use core::sync::atomic::{Ordering, fence};

-            compiler_fence(Ordering::SeqCst);
+            fence(Ordering::SeqCst);
```

`core::sync::atomic::fence(SeqCst)` 会在每个目标架构上生成正确的硬件屏障指令。

### 验证方法

```c
// 调用 membarrier(MEMBARRIER_CMD_GLOBAL) 应在反汇编中可见硬件 fence 指令
syscall(SYS_membarrier, MEMBARRIER_CMD_GLOBAL, 0, 0);
// riscv64: 应生成 fence iorw,iorw（而非无指令）
```

---

## PR 2: fix(signal): make skip-next-signal-check per-thread

**分支**: `fix/signal-per-thread-skip`  
**文件**: `os/StarryOS/kernel/src/task/mod.rs`, `os/StarryOS/kernel/src/task/signal.rs`  
**改动**: 删 1 个全局变量，加 1 个 Thread 字段，改 2 个函数

### Bug 描述

`rt_sigreturn` 系统调用通过 `block_next_signal()` 设置一个标志，表示"当前线程回到用户态循环时跳过一次信号检查"。这个标志存储在 **全局静态变量** `BLOCK_NEXT_SIGNAL_CHECK: AtomicBool` 中。

### 为什么是 bug 不是"没实现"

信号跳过机制已经完整实现了（`block_next_signal` 设置、`unblock_next_signal` 消费、在 `task/user.rs` 的主循环中检查）。问题不是"没有"这个机制，而是这个机制的**作用域错误**——本应是 per-thread 的状态，却用了全局变量。

### 影响

多核场景下的竞态：
1. CPU-0 上的线程 A 调用 `rt_sigreturn` → `block_next_signal()` 设为 `true`
2. CPU-1 上的线程 B 在用户态循环中 `unblock_next_signal()` 读到 `true`
3. 线程 B 错误地跳过了自己的信号检查（可能丢失信号）
4. 线程 A 的信号检查没被跳过（本来应该跳过的，可能导致信号处理异常）

### 修复

```diff
 pub struct Thread {
+    pub skip_next_signal_check: AtomicBool,
 }

-static BLOCK_NEXT_SIGNAL_CHECK: AtomicBool = AtomicBool::new(false);
-
 pub fn block_next_signal() {
-    BLOCK_NEXT_SIGNAL_CHECK.store(true, Ordering::SeqCst);
+    current().as_thread().skip_next_signal_check.store(true, Ordering::SeqCst);
 }
```

### 验证方法

```c
// 两个线程各自注册不同的信号处理函数，各自 raise + sigreturn
// 修复前：线程 A 的 block 可能被线程 B 消费，导致信号丢失
// 修复后：各线程独立，互不干扰
```

---

## PR 3: fix(signal): suspend on SIGSTOP instead of exiting

**分支**: `fix/sigstop-suspend-not-kill`  
**文件**: `os/StarryOS/kernel/src/task/signal.rs`  
**改动**: 3 行

### Bug 描述

`check_signals` 函数中 `SignalOSAction::Stop` 分支（处理 SIGSTOP/SIGTSTP/SIGTTIN/SIGTTOU）执行的是 `do_exit(1, true)`，**直接杀死了进程**。Linux 的标准行为是暂停进程，等待 SIGCONT 恢复。

### 为什么是 bug 不是"没实现"

Stop 信号的处理分支已经存在于 `check_signals` 的 match 中，代码已经走到了这个分支——只是分支体里的行为**完全错误**。注释 `// TODO: implement stop` 说明开发者知道这里是错的，但写了一个临时的 `do_exit` 占位。这不是"没实现"，而是**错误的占位实现进入了代码库且一直没被替换**。

### 影响

- 用户在 shell 中按 `Ctrl+Z` 发送 `SIGTSTP` → 前台进程被杀死（而非暂停）
- `kill -STOP <pid>` 杀死目标进程（而非暂停）
- shell 的 `bg`、`fg`、`jobs` 命令完全无法使用
- 任何依赖 job control 的程序行为异常

### 修复

```diff
 SignalOSAction::Stop => {
-    // TODO: implement stop
-    do_exit(1, true);
+    while !thr.pending_exit() && !thr.signal.pending().has(Signo::SIGCONT) {
+        yield_now();
+    }
 }
```

收到 Stop 信号后，线程进入循环等待，直到收到 SIGCONT（或被其他信号终止）。

### 验证方法

```c
pid_t pid = fork();
if (pid == 0) { while(1) pause(); }

kill(pid, SIGSTOP);
int status;
waitpid(pid, &status, WUNTRACED);
assert(WIFSTOPPED(status));            // 子进程应被暂停
assert(WSTOPSIG(status) == SIGSTOP);   // 停止信号是 SIGSTOP

kill(pid, SIGCONT);                    // 恢复
kill(pid, SIGTERM);                    // 终止
waitpid(pid, &status, 0);
assert(WIFSIGNALED(status));           // 子进程被终止

// 修复前：第一个 waitpid 永远等不到（子进程已死）
// 修复后：完整的 stop → continue → terminate 流程正常工作
```

---

## PR 4: fix(net): return peer address from accept4

**分支**: `fix/accept-peer-addr`  
**文件**: `os/StarryOS/kernel/src/syscall/net/socket.rs`  
**改动**: 1 行

### Bug 描述

`sys_accept4` 第 128 行：

```rust
let remote_addr = socket.local_addr()?;  // ← 错误：取了本地地址
```

变量名叫 `remote_addr`，后续写给用户的 `addr` 参数（`accept(2)` 的第二个参数，用于返回对端地址），但实际取的是 `local_addr()`——即**监听端的本地地址**。

### 为什么是 bug 不是"没实现"

accept4 已经完整实现了（socket 查找、accept 调用、nonblocking 设置、fd 分配、地址写回用户空间），只是在取地址的那一步**调错了方法**。这是一个典型的笔误/API 混淆 bug。

### 影响

```c
struct sockaddr_in peer;
socklen_t len = sizeof(peer);
int client_fd = accept(server_fd, (struct sockaddr*)&peer, &len);
// 修复前：peer.sin_addr 是服务端自己的地址（如 0.0.0.0:8080）
// 修复后：peer.sin_addr 是客户端的地址（如 10.0.2.15:54321）
```

所有需要知道"谁连过来了"的网络程序（日志、访问控制、反向代理）都会拿到错误的地址。`getpeername(client_fd)` 返回正确地址而 `accept` 返回错误地址，两者不一致。

### 修复

```diff
-    let remote_addr = socket.local_addr()?;
+    let remote_addr = socket.peer_addr()?;
```

### 验证方法

```c
// 服务端 bind 127.0.0.1:12345，客户端 connect
struct sockaddr_in accepted_addr;
int client = accept(server, (struct sockaddr*)&accepted_addr, &len);

struct sockaddr_in peer_addr;
getpeername(client, (struct sockaddr*)&peer_addr, &len);

// 修复后两者应相等：
assert(accepted_addr.sin_addr.s_addr == peer_addr.sin_addr.s_addr);
assert(accepted_addr.sin_port == peer_addr.sin_port);
```
