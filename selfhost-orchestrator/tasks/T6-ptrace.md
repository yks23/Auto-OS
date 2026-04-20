# T6：ptrace 子集（gdb / strace 基础）

## 你的角色：D1 (Kernel Core)

## 目标
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` selfhost-dev
- 交付物：patches/T6/ + tests/selfhost/test_ptrace_*.c + sentinel

## 背景

starry kernel **完全没有 ptrace**（`mod.rs` 里 `Sysno::ptrace` 落入 `_` arm 返回 ENOSYS）。这阻塞 gdb / strace / GCC 的某些 sanity check。

## 范围（最小子集）

实现以下 ptrace requests：

| Request | 必须 | 备注 |
|---|---|---|
| `PTRACE_TRACEME` | ✅ | child 把自己标记成被跟踪 |
| `PTRACE_ATTACH` | ✅ | parent attach 到指定 pid |
| `PTRACE_DETACH` | ✅ | release |
| `PTRACE_CONT` | ✅ | 让 stopped child 继续 |
| `PTRACE_PEEKDATA` | ✅ | 读 child 内存 1 word |
| `PTRACE_POKEDATA` | ✅ | 写 child 内存 1 word |
| `PTRACE_GETREGS` | ✅ | 拿 user_regs_struct |
| `PTRACE_SETREGS` | 推荐 | 写寄存器 |
| `PTRACE_SINGLESTEP` | 推荐 | 单步 |
| `PTRACE_SYSCALL` | 推荐 | strace 必须 |
| `PTRACE_KILL` | 可选 | 等价 SIGKILL |
| `PTRACE_GETSIGINFO` | 推荐 | 拿停止信号信息 |

## 设计要点

- `Thread` 加 `traced_by: Option<Pid>` 字段
- 被 trace 的进程在 syscall entry/exit + 收到信号时 set state = `Stopped` + send `SIGCHLD` 到 tracer
- tracer 的 `waitpid(WUNTRACED|WSTOPPED)` 必须收到 stopped 通知
- `PTRACE_PEEKDATA/POKEDATA` 要走 child 的 aspace 读写（不是 current's）
- `PTRACE_GETREGS` 用架构特定 register layout（x86_64 的 `user_regs_struct` 17 fields，riscv64 不同）

## 实现位置（建议）

- 新增 `kernel/src/syscall/task/ptrace.rs`
- `kernel/src/syscall/mod.rs` 加 `Sysno::ptrace => sys_ptrace(...)`
- `kernel/src/task/mod.rs` 给 Thread 加 `traced_by` 与 `ptrace_state`
- `kernel/src/syscall/task/wait.rs` 让 waitpid 处理 PTRACE stopped 状态
- `kernel/src/task/signal.rs` signal delivery 时如有 tracer 先停 + 通知

## 测试

`tests/selfhost/test_ptrace_*.c`（必须 4 个，不 hang 的）：

| 文件 | 验证 |
|---|---|
| `test_ptrace_traceme.c` | child TRACEME → execve → parent waitpid 收到 SIGTRAP |
| `test_ptrace_peek_poke.c` | PEEKDATA 读到 child cmdline 字串；POKEDATA 改后再 PEEK 看到改变 |
| `test_ptrace_getregs.c` | child stopped 后 GETREGS 拿 PC，PC 在 child 的 .text 段 |
| `test_ptrace_cont_exit.c` | CONT child 后 child 正常 exit，parent waitpid WEXITED |

## 完成信号

写 `selfhost-orchestrator/done/T6.done`：

```json
{
  "task_id": "T6",
  "status": "PASS|PARTIAL|FAIL|BLOCKED",
  "patches": ["patches/T6/0001-...patch"],
  "tests": ["tests/selfhost/test_ptrace_*.c"],
  "auto_os_branch": "cursor/t6-ptrace-7c9d",
  "auto_os_commits": [...],
  "build_riscv64": "PASS|FAIL",
  "build_x86_64": "PASS|FAIL",
  "tests_in_guest": "<n>/4 PASS",
  "blocked_by": [],
  "decisions_needed": []
}
```

## 硬约束

- 卡 2 小时写 BLOCKED sentinel
- 失败也必须写 sentinel
- 不要改 patches/T1-T5/F-alpha/F-beta/M1.5
- 不要改 scripts/
