# T1-T5 Patch 集成冲突解决记录

5 个 Phase 1 patches 单独 apply 都干净，但合并 apply 时有 2 处已知冲突。
本目录的 `*.merge` 文件是 Director 手工解决后的最终版本，
`scripts/integration-build.sh` 用它们自动还原集成态。

## T1 ↔ T2

### 文件 `kernel/src/syscall/task/execve.rs`

**冲突点 1**：T1 加了 `String` 与 `Poll` 的 import；T2 加了 `c_int` 与 `close_file_like`。

**解决**：合并两边的 import：
```rust
use alloc::{string::{String, ToString}, sync::Arc, vec::Vec};
use core::ffi::{c_char, c_int};
use core::task::Poll;
...
use crate::{
    config::USER_HEAP_BASE,
    file::{FD_TABLE, close_file_like, resolve_at},
    ...
};
```

### 文件 `kernel/src/task/ops.rs`

**冲突点 2**：T1 在 do_exit 中加 `thread_group_wait.wake()`；T2 在 do_exit 加 flock+record_lock 释放。

**解决**：合并，先 wake 再释放锁：
```rust
let last_thread = process.exit_thread(curr.id().as_u64() as Pid, exit_code);
thr.proc_data.thread_group_wait.wake();   // T1
if last_thread {
    let pid = process.pid();
    flock::release_all_for_pid(pid);       // T2
    record_lock::release_posix_for_pid(pid); // T2
    process.exit();
    ...
}
```

## T1 ↔ T5

### 文件 `kernel/src/syscall/task/execve.rs`

**冲突点 3**：T1 加 `ProcessData` / `kill_thread_for_execve_de_thread`；T5 加 `USER_STACK_SIZE` / `rlim_is_infinite`。

**解决**：合并 import，并把 T5 的 `stack_bytes` 计算放到 T1 重构后的 `apply_execve_image` 函数内（而不是原 `sys_execve`）。

参见 `T1-T5-execve.merge` 完整文件。

## 集成构建

```bash
bash scripts/integration-build.sh           # 双架构
bash scripts/integration-build.sh ARCH=riscv64
```

## 长期方案

冲突是结构性的：T1/T2/T5 都要改 execve.rs。后续 Phase 2 之前应当：
1. 合 selfhost-dev 到 main 后让 PIN 升级
2. 后续 T6+ 重新 rebase 到包含已合并 T1+T2+T5 的 selfhost-dev

或者把 T1+T2+T5 的 patch set 合并成一个集成 patch（更适合 long-running 集成分支）。
