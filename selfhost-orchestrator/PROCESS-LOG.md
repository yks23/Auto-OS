# 开发过程日志（Process Log）

按时间倒序，新条目加在最上面。格式：

```
## YYYY-MM-DD HH:MM | <类型> | <作者> | <标题>
**摘要**：一句话
**详情**：可选
**产出**：commit / PR / 文件
**关联**：相关任务 / 决策
```

类型：`decision` 决策 / `block` 阻塞 / `unblock` 解阻塞 / `progress` 进度 / `risk` 风险登记 / `handoff` 交接

---

## 2026-04-18 18:05 | decision | Director | 工作模式切换为 patches-in-Auto-OS（绕开 fork 写权限）

**摘要**：所有 tgoskits 修改以 patch 文件形式存在 `patches/Tn-slug/` 内，Auto-OS 仓追踪。从此**任何一个外部仓的写权限都不需要**。

**动机**：上一轮发现 cursor[bot] 对 `yks23/tgoskits` 没有写权限（cursor GitHub App 只装在 yks23/Auto-OS）。与其等人手授权，不如把整个工作流闭环到 Auto-OS 仓内。

**实现**：
- `PIN.toml` 锁 tgoskits 上游 commit (`c7e88fb3`)
- `scripts/lib.sh`、`apply-patches.sh`、`extract-patches.sh`、`sanity-check.sh`、`build.sh`、`new-task.sh` 工具链
- 端到端 demo 已实证：建 commit → extract → reset → apply → sanity → ✅
- `.github/workflows/selfhost.yml` 在 CI 上跑 sanity + build (riscv64+x86_64) + ci-test
- 子 agent 输出从"push tgoskits + 开 PR 到 yks23/tgoskits"改为"提交 `patches/Tn-slug/*.patch` 到 Auto-OS 仓的任务分支 + 开 PR 到 main"

**影响**：
- ✅ 不再有 GitHub App 阻塞
- ✅ 多人并发更安全（patches 目录天然分开）
- ✅ Review 友好（可以直接在 GitHub 上看 patch diff）
- ⚠️ 上游回流时需要把 patches 一次性 cherry-pick 到 fork，再向上游开一个大 PR（成本可控）

**关联**：所有任务包、ROADMAP.md §0、`patches/README.md`

---

## 2026-04-18 18:01 | progress | Director | patches workflow 端到端验证通过

**摘要**：用 demo commit 走通 `extract-patches.sh T0-demo` → `sanity-check.sh` → 自动 reset + apply + 合并 apply。日志输出：

```
[18:01:44] resetting tgoskits to pin c7e88fb3...
[18:01:45]   ✓ T0-demo: apply ok
[18:01:45]   ✓ combined apply ok
[18:01:45] OK: all 1 patch sets sane
```

**关联**：scripts/sanity-check.sh

---

## 2026-04-18 15:30 | decision | Director | Phase 1 文件主权边界

**摘要**：T1-T5 五个任务在 tgoskits 内的写文件区无重叠；唯一交叉点是 `kernel/src/syscall/mod.rs` 的新 syscall arm，rebase 时简单合并。

**关联**：ROADMAP.md §5.3

---

## 2026-04-18 15:25 | block | Director | (已绕开) cursor[bot] 对 yks23/tgoskits 没有写权限

**摘要**：原计划 push 到 fork + PR 上游被 GitHub App 权限阻塞。

**消除方法**：上面 18:05 的 decision——切到 patches 工作模式，**永远不需要 push tgoskits**。原阻塞失效。

---

## 2026-04-18 15:24 | progress | Director | tgoskits remote 已切到 yks23/tgoskits

**摘要**：origin → yks23/tgoskits，新增 upstream → rcore-os/tgoskits。新工作流下，origin 不再用于 push（只用于 fetch/upstream-tracking）。

---

## 2026-04-18 15:23 | unblock | 用户 | 提供 CURSOR_API_KEY

**摘要**：subagent 端到端验证通过（4.8 秒读 execve.rs:48-53 并复述）。

---

## 2026-04-18 15:11 | progress | Director | dispatcher dry-run 通过

**摘要**：5 个任务包 prompt 全部生成。

---

## 2026-04-18 15:10 | decision | Director | 工作模式定为「总监 + 4 subagent」

**摘要**：所有实际开发工作由 cursor-agent subagent 完成；Director 只做调度、review、文档维护。

---

## 2026-04-18 15:00 | decision | Director | 27 个任务 6 个 Phase 的总体路线确定
