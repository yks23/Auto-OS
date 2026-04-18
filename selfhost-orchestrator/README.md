# StarryOS Self-Host Orchestrator

把"在 StarryOS 上跑通 x86_64 / riscv64 自我编译"的工作拆给多个 cursor-agent 并发推进。

## 目录结构

```
selfhost-orchestrator/
├── README.md             # 本文件
├── dispatcher.py         # 调度脚本：fan-out → cursor-agent
├── tasks/                # 每个任务一个 .md prompt
│   ├── T1-execve-mt.md
│   ├── T2-file-locks.md
│   ├── T3-ipv6-socket.md
│   ├── T4-mount-ext4-9p.md
│   └── T5-resource-limits.md
└── logs/                 # 每个任务 run 的输出（含 session id）
```

## 调度模型

总监（人/总 agent）→ Dispatcher → 每个任务在独立的 git worktree + 独立的 cursor-agent
session 中并发执行，最终各自向 `rcore-os/tgoskits` 的 `dev` 分支提 PR。

```
                      Dispatcher
                          │
        ┌──────┬──────────┼──────────┬──────┐
        ▼      ▼          ▼          ▼      ▼
       T1     T2         T3         T4     T5
   execve  file-lock   ipv6      mount  resource
        │      │          │          │      │
        ▼      ▼          ▼          ▼      ▼
       PR     PR         PR         PR     PR  → rcore-os/tgoskits dev
```

## 用法

```bash
# 1. 准备：在 Cursor Dashboard 设置 secret CURSOR_API_KEY
# 2. dry-run（不真的派发，只打印每条 cursor-agent 命令）
python3 selfhost-orchestrator/dispatcher.py --dry-run

# 3. 真派发 + 后台运行所有任务，每个任务自己开 worktree
python3 selfhost-orchestrator/dispatcher.py --execute

# 4. 派发单个任务
python3 selfhost-orchestrator/dispatcher.py --execute --only T1

# 5. 查看每个任务进展
ls selfhost-orchestrator/logs/
```

## 任务包索引

| ID | 标题 | 目标分支 | 优先级 | 估算行数 |
|----|------|---------|-------|---------|
| T1 | 多线程 execve 真实修复 | `cursor/selfhost-execve-mt-7c9d` | 🔴 必须 | 100-200 |
| T2 | flock + fcntl 记录锁实现 | `cursor/selfhost-file-locks-7c9d` | 🔴 必须 | 500-700 |
| T3 | AF_INET6 socket 支持 | `cursor/selfhost-ipv6-7c9d` | 🔴 必须 | 100-300 |
| T4 | mount 放开 ext4 + 9p | `cursor/selfhost-mount-fs-7c9d` | 🔴 必须 | 200-2000 |
| T5 | 用户栈 / QEMU 内存 / FD 上限 | `cursor/selfhost-resource-limits-7c9d` | 🔴 必须 | 100-200 |
