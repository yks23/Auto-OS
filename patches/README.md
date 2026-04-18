# Patches against tgoskits

本目录的 patch 在 Auto-OS 仓内承载所有对 tgoskits 子模块的修改。

## 为什么用 patch 而不是直接改 submodule？

- **零外部权限**：不需要 `yks23/tgoskits` 的写权限
- **多人并发友好**：每个任务一个子目录，PR 之间天然不冲突
- **review 友好**：在 GitHub 上直接看 patch diff
- **可重放**：reset to pin → apply → build，结果确定
- **可上游**：当上游有写权限时，把 patches 一次性 cherry-pick 到 tgoskits 分支提 PR

## 目录约定

```
patches/
├── README.md                  # 本文件
├── T1-execve-mt/
│   ├── META.toml              # task / base_commit / extracted_at（脚本生成）
│   ├── README.md              # 任务概要 + 自检表
│   └── 0001-fix-...patch      # git format-patch 产物
│   └── 0002-test-....patch
├── T2-file-locks/
│   ├── ...
└── ...
```

## 脚本工具

| 脚本 | 用途 |
|---|---|
| `scripts/new-task.sh Tn-slug` | 初始化 patches/Tn-slug/ |
| `scripts/extract-patches.sh Tn-slug` | 把 tgoskits 当前分支的 commits 提到 patches/Tn-slug/ |
| `scripts/apply-patches.sh [--reset] [Tn ...]` | 把 patches reset+apply 到 tgoskits |
| `scripts/sanity-check.sh` | 验证每个 patch 单独可 apply、合并 apply 不冲突 |
| `scripts/build.sh ARCH=...` | 在 tgoskits/os/StarryOS 内 make build |

## 标准 subagent 工作流

```bash
# 1. （Director 派发后）subagent 进入自己的 worktree
cd .worktrees/T1-execve-mt

# 2. 子模块复位到 PIN
../../scripts/apply-patches.sh --reset

# 3. 在 tgoskits 内开任务分支
cd tgoskits
git checkout -B cursor/selfhost-execve-mt-7c9d $(grep '^commit' ../PIN.toml | cut -d'"' -f2)

# 4. 编辑 + commit（Conventional Commits）
$EDITOR os/StarryOS/kernel/src/syscall/task/execve.rs
git add -A && git commit -m "fix(starry): handle multi-thread execve"
git add -A && git commit -m "test(starry): add multi-thread execve test"

# 5. 提取 patch 到 Auto-OS 仓
cd ..
scripts/extract-patches.sh T1-execve-mt

# 6. 在 Auto-OS 仓 commit + push + 开 PR
git add patches/T1-execve-mt/
git commit -m "feat(patches/T1): multi-thread execve real fix"
git push -u origin cursor/selfhost-execve-mt-7c9d
gh pr create --base main --head cursor/selfhost-execve-mt-7c9d
```

## PIN 升级

`PIN.toml` 决定 base commit。要升级：

1. `cd tgoskits && git fetch upstream dev && git rev-parse upstream/dev`
2. 改 `PIN.toml` 的 `commit` 字段
3. `scripts/apply-patches.sh --reset`，遇到冲突的 patch 在原任务分支上 rebase 后 `extract-patches.sh` 重新生成
4. PR 标题：`chore(pin): bump tgoskits to <new-sha>`
