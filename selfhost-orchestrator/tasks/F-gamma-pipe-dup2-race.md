# F-γ：pipe + dup2 + execve + waitpid 残留死锁

## 你的角色：D1 (Kernel Core)

## 工作仓 / PR
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` 的 `selfhost-dev` 分支
- 交付物：`patches/F-gamma/` + `tests/selfhost/test_*_bisect.c` + `docs/F-gamma-debug.md` + sentinel

## 上下文（必读）

- `docs/M1.5-final-results.md` — F-α/F-β 后的实测：bisect OK + ls / OK，但 31 测试 hang
- `docs/STARRYOS-STATUS.md` — starry 现状
- `patches/F-alpha/0002-fix-starry-wait-avoid-lost-wakeup-...patch` — F-α 已修的 waitpid lost wakeup
- `patches/F-beta/0001-fix-axplat-riscv64-qemu-virt-console-RX-...patch` — F-β 已修的 console RX

## 问题精确描述

F-α 修了 `sys_waitpid` 的 lost wakeup 后，**最简 fork+execve+wait 通过**：

```c
pid_t p = fork();
if (p == 0) execve("/bin/echo", ...);
waitpid(p, ...);   // ✅ OK
```

**但完整 acceptance test 死锁**：

```c
pipe(pfd);
pid_t p = fork();
if (p == 0) {
    close(pfd[0]);
    dup2(pfd[1], STDOUT_FILENO);
    close(pfd[1]);
    execve("/bin/echo", argv, envp);
}
close(pfd[1]);
read(pfd[0], buf, sizeof buf);   // ← 卡死在这里
waitpid(p, &st, 0);
```

实测：guest 串口看到 `===RUNNING test_execve_basic===` 后再无任何输出，host timeout 杀 QEMU 才退。

## 你必须做的事

### 阶段 1：bisect 三种组合（在 F-α bisect 基础上加）

写 `tests/selfhost/test_pipe_bisect.c`，三阶段（编译 `-DSTAGE=1|2|3`），每阶段独立 musl 二进制：

```c
// STAGE 1: 父子 pipe，子 close + write 一字节，父 read 然后 wait
//   测：pipe write→read→wait 是否死锁（不涉 dup2 不涉 execve）
int main_step1() {
    int pfd[2]; pipe(pfd);
    pid_t p = fork();
    if (p == 0) { close(pfd[0]); write(pfd[1], "x", 1); close(pfd[1]); _exit(0); }
    close(pfd[1]);
    char c; ssize_t n = read(pfd[0], &c, 1);  // ←这一步死锁吗？
    int ws; waitpid(p, &ws, 0);
    printf("[BISECT-PIPE-1] read=%zd c=%c wait_ok\n", n, c);
}

// STAGE 2: 加 dup2，子 dup2(pfd[1], STDOUT) + write(stdout) + exit
int main_step2() {
    int pfd[2]; pipe(pfd);
    pid_t p = fork();
    if (p == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[1]);
        write(STDOUT_FILENO, "y", 1);  // 不 execve，自己写
        _exit(0);
    }
    close(pfd[1]);
    char c; ssize_t n = read(pfd[0], &c, 1);
    int ws; waitpid(p, &ws, 0);
    printf("[BISECT-PIPE-2] read=%zd c=%c\n", n, c);
}

// STAGE 3: 完整：pipe + dup2 + execve(/bin/echo) + read + wait
int main_step3() {
    int pfd[2]; pipe(pfd);
    pid_t p = fork();
    if (p == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[1]);
        execve("/bin/echo", (char*[]){"echo","hi",NULL}, (char*[]){NULL});
        _exit(99);
    }
    close(pfd[1]);
    char buf[64]; ssize_t n = read(pfd[0], buf, sizeof buf - 1);
    int ws; waitpid(p, &ws, 0);
    printf("[BISECT-PIPE-3] read=%zd buf=%.*s ws=0x%x\n", n, (int)n, buf, ws);
}
```

可以参考 F-α 的 `test_fork_exec_bisect.c`，用 `chain_next()` 串联。

### 阶段 2：跑 bisect 看哪一步先 hang

让 init.sh 直接 exec test_pipe_bisect_1 → chain 到 _2 → chain 到 _3。改 init.sh 头部：

```sh
if [ -x /opt/selfhost-tests/test_pipe_bisect_1 ]; then
    exec /opt/selfhost-tests/test_pipe_bisect_1
fi
```

### 阶段 3：根据 bisect 结果定位

- **STAGE-1 hang**（pipe 单纯 write→read→wait）：`kernel/src/file/pipe.rs` 的 read 阻塞 + writer close 时是否 wake reader
- **STAGE-2 hang**（加了 dup2）：`kernel/src/syscall/fs/io.rs` 的 dup2 fd table 路径
- **STAGE-3 hang**（execve 后才 hang）：execve 时是否正确处理 dup2 后的 stdout、是否 close-on-exec 误关闭了 dup2 后的 fd

### 阶段 4：修

可能需要看：
- `tgoskits/os/StarryOS/kernel/src/file/pipe.rs`：写端 close 时是否 wake reader
- `tgoskits/os/StarryOS/kernel/src/syscall/fs/io.rs`：sys_read 的 pipe 阻塞实现
- `tgoskits/os/StarryOS/kernel/src/file/mod.rs`：FileLike Drop / close_file_like
- `tgoskits/os/StarryOS/kernel/src/syscall/task/execve.rs`：execve 的 CLOEXEC + fd table 处理

### 阶段 5：验证

1. `bash scripts/integration-build.sh ARCH=riscv64`：build 通过
2. 三阶段 BISECT-PIPE-1/2/3 都打出来
3. **真验证**：跑 `bash scripts/run-tests-in-guest.sh ARCH=riscv64 TIMEOUT=1500`，**`test_execve_basic` 必须 PASS**（不 hang）
4. 拿到 `===SELFHOST-SUMMARY done===` 行，统计 PASS 数

## 完成信号（必须）

无论结果如何，最后写：
```
selfhost-orchestrator/done/F-gamma.done
```
内容是 final JSON：

```json
{
  "task_id": "F-gamma",
  "status": "PASS|PARTIAL|FAIL|BLOCKED",
  "bisect_pipe_step1": "OK|HANG",
  "bisect_pipe_step2": "OK|HANG",
  "bisect_pipe_step3": "OK|HANG",
  "test_execve_basic_in_guest": "PASS|HANG|FAIL",
  "m15_pass_count": "<整数>/30",
  "root_cause_file": "...",
  "fix_summary": "...",
  "patches": ["patches/F-gamma/0001-...patch"],
  "auto_os_branch": "cursor/fgamma-pipe-race-7c9d",
  "auto_os_commits": [...],
  "blocked_by": [],
  "decisions_needed": []
}
```

git add 时把 sentinel 文件也 add 进去。

## 工具就位
- musl-cross: `/opt/{x86_64,riscv64}-linux-musl-cross/bin`
- QEMU 8.2: `qemu-system-{x86_64,riscv64}`
- `scripts/integration-build.sh ARCH=riscv64` apply T1-T5 + F-α + F-β + 你的 F-γ
- `scripts/run-tests-in-guest.sh ARCH=riscv64 TIMEOUT=1500` 跑 31 测试

## 硬约束

- 必须真在 QEMU 里 bisect（不能只 build）
- 不要改 patches/T1-T5 / patches/F-alpha / patches/F-beta / patches/M1.5
- 失败/卡住也必须写 sentinel
- 卡 2 小时无进展写 BLOCKED sentinel 让 Director 接
