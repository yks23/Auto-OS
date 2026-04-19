# T9：缺失 syscall（waitid / openat2 / personality / setpriority(全PID) / getresuid）

## 你的角色：D2 (Resource & Build)

## 目标
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` selfhost-dev
- 交付物：patches/T9/ + tests/selfhost/test_*.c + sentinel

## 背景

starry kernel 的 `kernel/src/syscall/mod.rs` 落入 `_` arm 返回 ENOSYS 的关键 syscall：

| Syscall | 用途 | 必须 |
|---|---|---|
| `waitid` | 比 wait4 更灵活，部分 libc 优先用 | ✅ |
| `openat2` | 现代 cargo / rustc 优先用 | ✅ |
| `personality` | gcc / configure 探测时调 | ✅ |
| `setpriority`（全 PID） | nice / renice | ✅ |
| `getresuid` / `getresgid` | 权限检查 | ✅ |
| `clock_settime` | NTP / `date -s` | 推荐 |
| `recvmmsg` / `sendmmsg` | 网络批量收发 | 推荐 |
| `pidfd_open` 已有 / `pidfd_getfd` 推荐 | 容器工具 | 可选 |

## 实现

### waitid (95)
- 复用 `sys_wait4` 的内部 logic
- 接 P_PID / P_PGID / P_ALL；options WEXITED / WSTOPPED / WCONTINUED / WNOHANG / WNOWAIT
- 写 `siginfo_t`（si_pid / si_uid / si_signo=SIGCHLD / si_code = CLD_EXITED|CLD_KILLED|CLD_DUMPED）

### openat2 (437)
- 接 `struct open_how`（flags / mode / resolve）
- 至少支持 RESOLVE_BENEATH（防 ../ 越界）
- 其他 RESOLVE_* 可暂返回 EINVAL

### personality (135)
- 加 `ProcessData::personality: u32`，默认 PER_LINUX (0)
- arg=0xFFFFFFFF 是 query：返回当前值
- 否则 set 后返回旧值

### setpriority (140) 全 PID 支持
- 现状只支持 pid=0；改成支持 PRIO_PROCESS + 任意 pid
- 存到 ProcessData（已有 nice 字段或加）

### getresuid (118) / getresgid (148)
- ProcessData 已有 ruid/euid/suid（T5 加的），三个值返回

## 测试（5 个）

| 文件 | 验证 |
|---|---|
| `test_waitid_pexited.c` | child _exit(42)；waitid(P_PID, child, &si, WEXITED)；si.si_status==42 |
| `test_openat2_basic.c` | open_how{flags=O_RDONLY}; openat2(AT_FDCWD, "/etc/hostname", &how, sizeof how) ≥0 |
| `test_personality_get.c` | personality(0xFFFFFFFF) 返回 0 (PER_LINUX) |
| `test_setpriority_other_pid.c` | fork → child sleep；parent setpriority(PRIO_PROCESS, child, 10)；getpriority 看到新值 |
| `test_getresuid_basic.c` | getresuid(&r,&e,&s)；三个都 == 0（root） |

测试**避免 pipe+dup2+execve**完整组合。

## 完成信号

写 `selfhost-orchestrator/done/T9.done`：

```json
{
  "task_id": "T9",
  "status": "PASS|PARTIAL|FAIL|BLOCKED",
  "patches": ["patches/T9/0001-...patch"],
  "tests": ["tests/selfhost/test_*.c"],
  "auto_os_branch": "cursor/t9-missing-syscalls-7c9d",
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
- 失败也写
- 不改 patches/T1-T5/F-alpha/F-beta/M1.5/F-gamma 等
