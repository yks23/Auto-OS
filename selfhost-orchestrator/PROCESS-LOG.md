# 开发过程日志（Process Log）

按时间倒序记录关键决策、阻塞、产出。新条目加在最上面。

格式：

```
## YYYY-MM-DD HH:MM | <类型> | <作者> | <标题>
**摘要**：一句话
**详情**：可选
**产出**：commit / PR / 文件
**关联**：相关任务 / 决策
```

类型分类：
- `decision` 决策
- `block` 阻塞
- `unblock` 解阻塞
- `progress` 进度
- `risk` 风险登记
- `handoff` 交接

---

## 2026-04-18 15:30 | decision | Director | 5 个 Phase 1 任务的"文件主权"边界确认

**摘要**：Phase 1 的 5 个任务（T1-T5）经过文件级核对，写文件区无重叠，可以并发。

**详情**：
- T1 写 `kernel/src/syscall/task/execve.rs` + 在 `kernel/src/syscall/mod.rs` 仅加 `Sysno::execveat` arm
- T2 新增 `kernel/src/file/{flock,record_lock}.rs`，改 `fd_ops.rs`、`file/mod.rs`（注册新模块）
- T3 改 `kernel/src/syscall/net/{socket,addr,opt}.rs`
- T4 改 `kernel/src/syscall/fs/mount.rs`
- T5 改 `config/*.rs` + `Makefile` + 新增 `kernel/src/syscall/task/rlimit.rs`

唯一交叉点：T1 与 T5 都会改 `kernel/src/syscall/task/mod.rs`（注册新子模块），rebase 时合并即可，不会逻辑冲突。

**关联**：ROADMAP.md §5.3

---

## 2026-04-18 15:25 | block | Director | 🔴 cursor[bot] 对 yks23/tgoskits 没有写权限

**摘要**：当前 cloud agent 的 git 凭证（GitHub App `cursor[bot]` 的 installation token）push `yks23/tgoskits` 时返回 403，整个 Phase 0 卡住。

**详情**：
```
$ git push -u origin selfhost-dev
remote: Permission to yks23/tgoskits.git denied to cursor[bot].
fatal: unable to access 'https://github.com/yks23/tgoskits.git/': The requested URL returned error: 403
```

**消除方法（必须人手做）**：
1. 浏览器打开 https://github.com/apps/cursor-agent/installations/new（或 Cursor Dashboard → Integrations → GitHub App）。
2. 选择把 Cursor 装到 `yks23` 账号下。
3. 在 "Repository access" 里**显式勾上 `yks23/tgoskits`**（或选 "All repositories"）。
4. 完成后告诉 Director，Director 重试 `git push -u origin selfhost-dev`。

**影响**：所有 subagent 任务都依赖这一步，Phase 0 不解，后续 Phase 1-6 全不能跑。

**关联**：ROADMAP.md Phase 0、ROLES.md D0

---

## 2026-04-18 15:24 | progress | Director | tgoskits remote 已切到 yks23/tgoskits

**摘要**：本地 `/workspace/tgoskits` 的 origin 改为 `yks23/tgoskits`，新增 upstream 指向 `rcore-os/tgoskits`。

**详情**：
```
$ git -C tgoskits remote -v
origin    https://...@github.com/yks23/tgoskits.git (fetch/push)
upstream  https://...@github.com/rcore-os/tgoskits.git (fetch/push)
```

`upstream/dev` 已 fetch；本地 `dev` 跟踪 `upstream/dev`。

**关联**：ROADMAP.md Phase 0 第 1 项

---

## 2026-04-18 15:23 | unblock | 用户 | 提供 CURSOR_API_KEY

**摘要**：用户提供的 `crsr_xxx` key 可以认证 cursor-agent CLI，最小连通性测试通过（`echo CONNECTIVITY_OK` 4.8 秒返回）。

**详情**：
- key 保存在 `~/.config/selfhost-orchestrator/env`（chmod 600，不入 git）。
- `dispatcher.py` 已加 `load_local_env()`，启动时自动 source 该文件。
- 真打了一次 cursor-agent 让它读 `kernel/src/syscall/task/execve.rs:48-53` 并复述行为，4.8 秒返回正确结论：subagent 能力验证通过。

**关联**：dispatcher.py:30-55、ROADMAP.md Phase 0

---

## 2026-04-18 15:11 | progress | Director | dispatcher dry-run 通过

**摘要**：5 个任务包 prompt 全部生成（chars 2807/3249/2885/3362/3163），dispatcher --dry-run 通过。

**关联**：selfhost-orchestrator/dispatcher.py、selfhost-orchestrator/tasks/T*.md

---

## 2026-04-18 15:10 | decision | Director | 工作模式定为「总监 + 4 subagent」

**摘要**：根据用户要求，所有实际开发工作由 cursor-agent subagent 完成，Director 只做调度、review、文档维护。

**关联**：ROLES.md

---

## 2026-04-18 15:08 | progress | Director | cursor-agent CLI 安装就绪

**摘要**：`/home/ubuntu/.local/bin/cursor-agent` 安装完毕，版本 `2026.04.17-479fd04`。

**关联**：ROLES.md D0 工具栏

---

## 2026-04-18 15:00 | decision | Director | 27 个任务 6 个 Phase 的总体路线确定

**摘要**：把 self-hosting 工作拆成 27 个小任务，分 6 个 Phase 推进；S0/S1/S2/S3/S4 五个里程碑。

**关联**：ROADMAP.md §1, §3
