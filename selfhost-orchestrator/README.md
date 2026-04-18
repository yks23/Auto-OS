# StarryOS Self-Host Orchestrator

把"在 StarryOS 上跑通 x86_64 / riscv64 自我编译"的工作拆给多个 cursor-agent 并发推进。

## 文档导航

| 文档 | 看什么 |
|---|---|
| [`ROADMAP.md`](./ROADMAP.md) | 6 个 Phase / 27 个任务 / 关键路径图 / 协作规则 |
| [`ROLES.md`](./ROLES.md) | D0-D4 五个岗位的职责 / 工具 / 输入输出 |
| [`TEST-MATRIX.md`](./TEST-MATRIX.md) | 每个 Phase 的验收测试用例 + CI 矩阵 |
| [`PROCESS-LOG.md`](./PROCESS-LOG.md) | 实时开发日志（决策、阻塞、产出） |
| [`tasks/T*.md`](./tasks/) | 每个具体任务包的 prompt（subagent 的合同） |

## 目录结构

```
selfhost-orchestrator/
├── README.md             # 本文件（导航）
├── ROADMAP.md            # 6 阶段路线图
├── ROLES.md              # 4 个开发岗位
├── TEST-MATRIX.md        # 测试矩阵
├── PROCESS-LOG.md        # 过程日志
├── dispatcher.py         # 调度脚本：fan-out → cursor-agent
├── tasks/                # 每个任务一个 .md prompt
│   ├── T1-execve-mt.md
│   ├── T2-file-locks.md
│   ├── T3-ipv6-socket.md
│   ├── T4-mount-ext4-9p.md
│   └── T5-resource-limits.md
└── logs/                 # 每个任务 run 的输出（不入 git）
```

## 工作模式（patches-in-Auto-OS）

**所有工作发生在 `yks23/Auto-OS` 这一个仓里**。tgoskits 子模块永远 read-only，
pin 在 `PIN.toml` 指定的上游 commit；所有内核改动以 patch 文件存在 `patches/Tn-slug/` 目录。

子 agent 工作流：在自己的 git worktree 内修改 tgoskits → `git format-patch` 提取 →
patch 文件 commit 到 Auto-OS 任务分支 → push → 在 Auto-OS 仓开 PR 到 main。

完整规则见 [`../patches/README.md`](../patches/README.md) 与 ROADMAP §0。

```
                      Dispatcher
                          │
        ┌──────┬──────────┼──────────┬──────┐
        ▼      ▼          ▼          ▼      ▼
       T1     T2         T3         T4     T5
   execve  file-lock   ipv6      mount  resource
   (D1)    (D3)        (D3)       (D3)   (D2)
        │      │          │          │      │
        ▼      ▼          ▼          ▼      ▼
   patch文件 + 测试用例    →   Auto-OS PR  →  main
                                  │
                              CI selfhost.yml
                              sanity + build(rv,x86) + ci-test
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
