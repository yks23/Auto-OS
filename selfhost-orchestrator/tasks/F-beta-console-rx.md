# F-β：starry console RX 路径修复（与 F-α 并行）

## 你的角色：D1 (Kernel Core) — 与 F-α 是同岗位但独立 worktree

## 工作仓 / PR
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` 的 `selfhost-dev`（Director 代开 PR）
- 交付物：`patches/F-beta/0001-...patch` + `docs/F-beta-debug.md`

## 上下文文件（必读）

- `docs/STARRYOS-STATUS.md` — starry 现状
- `docs/M1.5-results.md` — 第二轮报告，详细描述 stdin 阻塞
- `tgoskits/os/StarryOS/scripts/ci-test.py` — starry 自己的 CI 怎么走串口

## 问题精确描述

starry kernel 在 riscv-virt QEMU 上：
- **TX 路径（kernel → host 串口）**：✅ 工作。boot log + init.sh echo 全打出来
- **RX 路径（host 串口 → kernel → BusyBox stdin）**：❌ 不工作

实测：
- Python `socket.create_connection(("localhost", 4444))` 连上 QEMU 串口
- `s.sendall(b"sh /opt/run-tests.sh\r\n")` 调用成功
- guest 端 BusyBox shell 完全没收到这些字节，永远等 stdin
- 即使发回车也没用

观察到的 prompt 后表象（results.txt 摘录）：
```
root@starry:/root #
[6n               ← starry 输出了 CPR query (\x1b[6n) 等 host 回应
sh /opt/run-tests.sh   ← Python 发的命令，但 BusyBox 没收到
```

可能原因：
1. UART RX 中断没注册或 IRQ 没路由
2. `/dev/console` 的 read path 没正确接到 axhal RX queue
3. `axhal::console::getchar()` 是 polling 但没触发 user-space task wakeup
4. line discipline 与 BusyBox isatty/cfmakeraw 不兼容

## 你必须做的事

### 阶段 1：定位 TX vs RX 不对称的位置

1. 看 `tgoskits/os/StarryOS/kernel/src/pseudofs/dev/tty/` 整个目录
2. 看 `tgoskits/os/arceos/modules/axhal/src/platform/...` 找 console driver
3. 找到 starry 哪个文件实现 `/dev/console` 的 read syscall
4. 看 read 是否走 wait queue，wait queue 是否被 RX IRQ 唤醒

### 阶段 2：写最小测试

写一个 C 程序 `test_stdin_byte.c`：
```c
int main() {
    char c;
    write(1, "send-a-byte> ", 13);
    int n = read(0, &c, 1);
    printf("got %d bytes, byte=0x%02x\n", n, c);
}
```

让 init.sh 直接 exec 它（不通过 sh）。host Python 发一个字节，看 guest 是否打印 `got 1 bytes`。

### 阶段 3：根据 RX 路径定位修

可能 fix 方向（按嫌疑度）：
1. 注册 UART RX IRQ handler，把字节塞进 `/dev/console` 的 ring buffer
2. 让 `sys_read(0, ...)` 走 ax_io::Read trait 阻塞等待 ring buffer
3. 在 RX IRQ handler 里 wake 等待 console read 的 task

可能要改的文件：
- `tgoskits/os/arceos/modules/axhal/src/platform/riscv64_qemu_virt/`（或 axplat-riscv64-qemu-virt）
- `tgoskits/os/StarryOS/kernel/src/pseudofs/dev/tty/`
- `tgoskits/os/arceos/modules/ax_io/`

### 阶段 4：验证

1. integration-build OK
2. test_stdin_byte 实测 host 发一字节 guest 能收到
3. **真测**：让 BusyBox shell 接 `echo abc\n` → guest 端能 `cat` 到 abc

### 阶段 5：写诊断文档

`docs/F-beta-debug.md`：
- starry RX 路径的完整调用链（你画出来）
- 哪一步断了
- 你的 fix
- 验证结果

## 工具已就位

同 F-α：
- `scripts/integration-build.sh` / `run-tests-in-guest.sh` / `qemu-run-kernel.sh`
- musl-cross 在 `/opt/`，PATH 已配
- QEMU 8.2

## 可能你需要新加 helper

写一个 `scripts/qemu-interactive.sh ARCH=riscv64`：启动 QEMU 后开 nc 让你能交互发字节。这是测 RX 的关键工具，可以写到 PR 里。

## 提交策略

- **不要**改 patches/T1..T5、patches/M1.5
- **可以**改 axhal / axplat / pseudofs/dev/tty / ax_io
- **可以**写 `scripts/qemu-interactive.sh`
- 用 `scripts/extract-patches.sh F-beta` 提你的 commit

## Commit 拆分

1. `test(selfhost/F-beta): add stdin RX byte-level test`
2. `feat(scripts): add qemu-interactive helper for RX testing`
3. `feat(starry/<subsystem>): fix console RX - <one-line root cause>`
4. `docs(F-beta): RX path analysis and fix`

## 输出 JSON

```json
{
  "task_id": "F-beta",
  "auto_os_branch": "cursor/fbeta-console-rx-7c9d",
  "patches": [...],
  "tests": ["tests/selfhost/test_stdin_byte.c"],
  "auto_os_commits": [...],
  "rx_works_now": true|false,
  "root_cause_file": "...",
  "fix_summary": "...",
  "build_riscv64": "PASS|FAIL",
  "build_x86_64": "PASS|FAIL",
  "blocked_by": [],
  "decisions_needed": []
}
```

## 硬约束

- 必须 QEMU 内实测 RX 字节透传
- 优先修 riscv64（最低门槛），x86_64 可在 PR 里说明"待 follow-up"
- 与 F-α subagent **没有依赖关系**：你们独立 worktree，最后 Director 合
- 卡 2 小时无进展写卡住报告
