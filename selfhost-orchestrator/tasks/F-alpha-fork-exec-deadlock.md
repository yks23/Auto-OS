# F-α：starry fork+execve+wait4 死锁修复（最高优先，阻塞 M1.5）

## 你的角色：D1 (Kernel Core)

## 工作仓 / PR
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` 的 `selfhost-dev` 分支（Director 代开 PR）
- 交付物：`patches/F-alpha/0001-...patch` + 测试用例 + `docs/F-alpha-debug.md`

## 上下文文件（必读）

- `docs/STARRYOS-STATUS.md` — starry 现状评估
- `docs/M1.5-results.md` — M1.5 第二轮报告，详细记录死锁现象
- `patches/M1.5/0001-feat-starry-init-auto-run-opt-run-tests.sh-hook-for-.patch` — 已有的 init.sh 自动 run 测试 hook（你可以复用）

## 问题精确描述

实测在 starry kernel 内（PIN c7e88fb3 + T1-T5 集成）：

```sh
# starry init.sh 修改后跑这段：
echo "===A==="          # ✅ 工作（builtin）
pwd                      # ✅ 工作（builtin）
ls /                     # ❌ 死锁（external = fork+execve+wait4）
echo "===B==="           # 永远到不了
```

死锁现象：
- guest 串口输出停在 `===A===`、`===B===` 之前
- host 等 60 秒后必须 `pkill -9 qemu` 才能退
- starry kernel 没有 panic，只是任务都不前进

**这不是 T1 改过的多线程 execve 路径**：sh fork 出来的 child 是单线程，T1 fix 不在这条路径上。

## 你必须做的事

### 阶段 1：bisect 死锁在 fork / execve / wait4 哪一步

写最小测试 `tests/selfhost/test_fork_exec_bisect.c`：

```c
// 三个独立的子测试，每个都 musl 静态编译
// 跑法：init.sh exec 它，单独二进制不依赖 sh

// step 1: 只 fork
int main_step1() {
    pid_t p = fork();
    if (p == 0) _exit(42);
    int ws;
    pid_t r = waitpid(p, &ws, 0);
    printf("[BISECT-1] fork-only: r=%d ws=%d (PASS if r==%d ws_status==42)\n",
           r, ws, p);
}

// step 2: fork + exec (no wait)
int main_step2() {
    pid_t p = fork();
    if (p == 0) {
        char *argv[] = {"/bin/echo", "hi", NULL};
        execve("/bin/echo", argv, NULL);
        _exit(99); // 不该到这
    }
    sleep(2); // 不 wait，看 child 是否能跑完
    printf("[BISECT-2] fork-exec-no-wait: parent alive after 2s\n");
}

// step 3: fork + exec + wait
int main_step3() {
    pid_t p = fork();
    if (p == 0) {
        execve("/bin/true", (char*[]){"/bin/true", NULL}, NULL);
        _exit(99);
    }
    int ws;
    pid_t r = waitpid(p, &ws, 0);
    printf("[BISECT-3] fork-exec-wait: r=%d ws=%d\n", r, ws);
}
```

把三个 main 编成三个独立的二进制 `test_bisect_1` / `_2` / `_3`。

改 init.sh 让它依次跑这三个二进制（不通过 sh fork，直接 init 启动→第一个二进制→…）。

### 阶段 2：根据 bisect 结果定位

**情况 A**：step 1 (fork+wait4) 死锁 → 问题在 starry 的 task 退出 reaping 路径
- 看 `kernel/src/task/ops.rs:do_exit_thread`
- 看 `kernel/src/syscall/task/wait.rs:sys_waitpid` 的 wait queue 唤醒
- 看 `Process::child_exit_event` 是否被正确 `wake()`

**情况 B**：step 1 OK 但 step 2/3 (fork+execve) 死锁 → 问题在 ELF loader 或 child 启动
- 看 `kernel/src/mm/loader.rs:load_user_app`
- 看 `kernel/src/syscall/task/execve.rs:apply_execve_image`
- 检查 child 的 task 是否被加进 ax-task run queue
- 检查 user stack 映射是否在 ELF 加载后还有效

**情况 C**：step 1 + step 2 OK 但 step 3 (有 wait) 死锁 → 问题在 wait4 与 execve 后 child 退出的 race
- 看 child execve 完成后是否还能正确 send SIGCHLD 给 parent
- 看 parent 是否在 child 已退出后才进 wait queue（lost wakeup）

### 阶段 3：修

按 bisect 结果定位代码，写 fix patch。**最小改动原则**：能 1 行修就别改 50 行。

### 阶段 4：验证

1. `bash scripts/integration-build.sh ARCH=riscv64`：build 通过
2. 用你的 `test_bisect_*` 三个二进制跑 init.sh 模式：三个 BISECT 行都打出来
3. **再让 `ls /` 在 starry sh 里能跑通**：这是真验证（Director 已经准备了重跑 framework）

### 阶段 5：写诊断文档

`docs/F-alpha-debug.md`：
- 你 bisect 的步骤
- 找到的 root cause（具体 .rs 文件 + 行号）
- 你的 fix 思路
- 验证结果（三个 BISECT + ls / 都通过的串口截图/日志）

## 工具已就位

- `scripts/integration-build.sh ARCH=riscv64` — 一键 apply T1-T5 + build
- `scripts/run-tests-in-guest.sh ARCH=riscv64 TIMEOUT=600` — 跑 guest（init.sh 已 hook 自动 run /opt/run-tests.sh）
- `scripts/qemu-run-kernel.sh ARCH=riscv64 KERNEL=...` — 单独启 QEMU
- `tgoskits/os/StarryOS/starryos/src/init.sh` — 你可以改这个让它直接 exec 你的 bisect 二进制（不通过 sh）

QEMU + musl-cross 都装好。`/opt/{x86_64,riscv64}-linux-musl-cross/bin` 在 PATH 里。

## 提交策略

- **不要**改 `patches/T1..T5`（不是你的范围）
- **不要**改 `patches/M1.5/0001-init-hook.patch`（已经定型）
- **可以**改 `tgoskits/os/StarryOS/starryos/src/init.sh`（提到 patches/F-alpha/）
- **可以**改 `kernel/src/task/`、`kernel/src/syscall/task/`、`kernel/src/mm/loader.rs`（提到 patches/F-alpha/）
- 用 `scripts/extract-patches.sh F-alpha` 把你的 commits 提到 `patches/F-alpha/`

## Commit 拆分

1. `test(selfhost/F-alpha): add fork+exec+wait bisect tests`
2. `feat(starry/<subsystem>): fix fork+exec+wait deadlock - <root-cause>`
3. `docs(F-alpha): root cause analysis and fix verification`

## 输出 JSON

最后输出：

```json
{
  "task_id": "F-alpha",
  "auto_os_branch": "cursor/falpha-fork-exec-deadlock-7c9d",
  "patches": ["patches/F-alpha/0001-...patch"],
  "tests": ["tests/selfhost/test_fork_exec_bisect.c"],
  "auto_os_commits": ["sha1", "..."],
  "bisect_result": "step1_fail | step2_fail | step3_fail | all_ok_after_fix",
  "root_cause_file": "kernel/src/.../xxx.rs",
  "root_cause_line": 123,
  "fix_summary": "一句话 root cause + 一句话 fix",
  "guest_ls_works": true|false,
  "build_riscv64": "PASS|FAIL",
  "build_x86_64": "PASS|FAIL",
  "blocked_by": [],
  "decisions_needed": []
}
```

## 硬约束

- **必须真在 QEMU 内验证**，不能只 build 通过
- **必须 bisect 到具体 root cause**，不能"猜"——每个修都要有 evidence
- 卡住超过 2 小时无进展就停下来写"卡住报告"给 Director，不要无限死磕
- 善用 starry 自己的 `LOG=debug` 看 boot 日志（在 axconfig.toml 改）
