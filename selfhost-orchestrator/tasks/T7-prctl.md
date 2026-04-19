# T7：prctl 完善（PDEATHSIG / DUMPABLE / NO_NEW_PRIVS / TID_ADDRESS / CHILD_SUBREAPER）

## 你的角色：D1 (Kernel Core)

## 目标
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` selfhost-dev
- 交付物：patches/T7/ + tests/selfhost/test_prctl_*.c + sentinel

## 背景

starry kernel 的 `sys_prctl` (`kernel/src/syscall/task/ctl.rs`) 现在只支持 `PR_SET_NAME / PR_GET_NAME`，其他选项 `EINVAL`。bash / pip / gcc / make 大量用 `PR_SET_PDEATHSIG`、`PR_SET_NO_NEW_PRIVS`，缺失会导致这些工具警告或失败。

## 范围

实现以下 prctl options（按 Linux uapi 编号）：

| Option | 功能 | 必须 |
|---|---|---|
| `PR_SET_PDEATHSIG` (1) / `PR_GET_PDEATHSIG` (2) | parent death signal，父进程死时给 child 发信号 | ✅ |
| `PR_GET_DUMPABLE` (3) / `PR_SET_DUMPABLE` (4) | core dump 控制 | ✅ |
| `PR_GET_KEEPCAPS` (7) / `PR_SET_KEEPCAPS` (8) | keep capabilities | ✅ no-op 也行 |
| `PR_SET_NO_NEW_PRIVS` (38) / `PR_GET_NO_NEW_PRIVS` (39) | seccomp/sudo bit | ✅ |
| `PR_SET_CHILD_SUBREAPER` (36) / `PR_GET_CHILD_SUBREAPER` (37) | init/build sandbox 用 | ✅ |
| `PR_GET_TID_ADDRESS` (40) | 返回 set_tid_address 设的地址 | ✅ |
| `PR_SET_THP_DISABLE` (41) / `PR_GET_THP_DISABLE` (42) | jemalloc 用 | 推荐 no-op |

## 设计

- `ProcessData` 加字段：`pdeath_signal: Option<i32>`、`dumpable: u32`（默认 1）、`no_new_privs: bool`、`keep_caps: bool`、`child_subreaper: bool`
- `PR_SET_PDEATHSIG` 真实生效：parent `do_exit` 时遍历 children，对设了 PDEATHSIG 的发对应信号
- `PR_GET_TID_ADDRESS` 返回 `Thread::clear_child_tid` 的值

## 测试（5 个）

| 文件 | 验证 |
|---|---|
| `test_prctl_pdeathsig.c` | child SET_PDEATHSIG=SIGUSR1 + sleep；parent _exit；child handler 触发 |
| `test_prctl_dumpable.c` | GET 默认 1；SET 0 后 GET 返回 0；SET 2 ok |
| `test_prctl_no_new_privs.c` | SET 后 GET 返回 1，再 SET 0 返回 EINVAL（PR_SET_NO_NEW_PRIVS 不可清除） |
| `test_prctl_keepcaps.c` | SET / GET 不报错 |
| `test_prctl_get_tid_address.c` | 与 set_tid_address 设的地址一致 |

每个测试**不要用 fork+pipe+execve 完整组合**（F-γ 修之前会 hang），主进程内单独跑就行。

## 完成信号

写 `selfhost-orchestrator/done/T7.done`：

```json
{
  "task_id": "T7",
  "status": "PASS|PARTIAL|FAIL|BLOCKED",
  "patches": ["patches/T7/0001-...patch"],
  "tests": ["tests/selfhost/test_prctl_*.c"],
  "auto_os_branch": "cursor/t7-prctl-7c9d",
  "auto_os_commits": [...],
  "build_riscv64": "PASS|FAIL",
  "build_x86_64": "PASS|FAIL",
  "tests_in_guest": "<n>/5 PASS",
  "blocked_by": [],
  "decisions_needed": []
}
```

## 硬约束

- 卡 2 小时写 BLOCKED sentinel
- 失败也写 sentinel
- 不改 patches/T1-T5/F-alpha/F-beta/M1.5
