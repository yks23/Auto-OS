# T8：procfs 真数据（self/exe / cpuinfo / meminfo / random/uuid）

## 你的角色：D2 (Resource & Build)

## 目标
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` selfhost-dev
- 交付物：patches/T8/ + tests/selfhost/test_proc_*.{c,sh} + sentinel

## 背景

starry 的 procfs（`kernel/src/pseudofs/proc.rs`）已经有 pid 目录骨架，但不少节点缺失或假数据。rustc 用 `/proc/self/exe` 定位 sysroot，cargo 用 `/proc/cpuinfo` 决定并行度，free / top 用 `/proc/meminfo`。

## 范围

| 节点 | 必须 | 内容 |
|---|---|---|
| `/proc/self/exe` | ✅ | readlink 返回当前进程的 exe 真路径（已有 FIXME，去掉） |
| `/proc/cpuinfo` | ✅ | x86: `processor` + `model name` + `flags`；riscv: `processor` + `isa: rv64gc` + `mmu: sv48` |
| `/proc/meminfo` | ✅ | MemTotal / MemFree / MemAvailable / SwapTotal=0 / SwapFree=0 |
| `/proc/sys/kernel/random/uuid` | ✅ | 每次读返回新 UUID（getrandom 后格式化） |
| `/proc/sys/kernel/random/boot_id` | 推荐 | boot 时一次生成，之后不变 |
| `/proc/loadavg` | 推荐 | "0.00 0.00 0.00 1/1 1" 简单 stub |
| `/proc/uptime` | 推荐 | "<seconds.fraction> <idle.fraction>" |
| `/proc/version` | 推荐 | "Linux version 10.0.0 ..." 与 uname 一致 |
| `/proc/mounts` | 推荐 | 列出 procfs/devfs/tmpfs/ext4 等 mountpoints |
| `/proc/filesystems` | 可选 | 列 ext4 / tmpfs / proc / sysfs |

## 设计

procfs 在 starry 用 `dyn VfsNode` trait。每个动态节点都是一个 `impl VfsNode` 在 `read` 时即时生成内容。

- `/proc/self/exe`：读 `current_thread().proc_data.exe_path`
- `/proc/cpuinfo`：从 `axhal::cpu_num()` 生成 `processor:` 行；架构特定 ISA/flags
- `/proc/meminfo`：用 `ax_alloc::available_bytes()` + `total_bytes()`
- UUID：用 `axhal::misc::random_byte()` 拼 UUID v4 格式

## 测试（5 个）

| 文件 | 验证 |
|---|---|
| `test_proc_self_exe.c` | readlink("/proc/self/exe") == 测试自己的真 path |
| `test_proc_cpuinfo.sh` | grep "processor" 至少 1 行 |
| `test_proc_meminfo.sh` | grep -E "MemTotal\|MemFree\|MemAvailable" 三行都在 |
| `test_proc_random_uuid.sh` | cat 两次得到不同 UUID（v4 格式 8-4-4-4-12 hex） |
| `test_proc_loadavg.sh` | cat 输出格式正确（5 字段） |

测试避免用 fork+pipe+execve（F-γ 之前会 hang），用单进程 read /proc 文件即可。

## 完成信号

写 `selfhost-orchestrator/done/T8.done`：

```json
{
  "task_id": "T8",
  "status": "PASS|PARTIAL|FAIL|BLOCKED",
  "patches": ["patches/T8/0001-...patch"],
  "tests": ["tests/selfhost/test_proc_*.{c,sh}"],
  "auto_os_branch": "cursor/t8-procfs-7c9d",
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
