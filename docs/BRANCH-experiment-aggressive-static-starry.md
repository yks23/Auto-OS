# 分支 `experiment/aggressive-static-starry`

## 目的

在不影响 `main` 合并节奏的前提下，集中做 **Starry 相关静态检查**（`rustfmt`、`clippy`、`cargo check`，目标 `riscv64gc-unknown-none-elf`），通过 `scripts/ci-starry-static.sh` 在 **`auto-os/starry:latest`** 内复现，便于 aggressive 迭代 clippy/warning 清零。

## 与 main 的关系

- **新建分支**：`git fetch origin && git checkout -b experiment/aggressive-static-starry origin/main`（或从当前开发 HEAD 切出）。
- **同步 main**：优先 `git rebase origin/main`；若团队要求线性历史外合并，可用 `git merge origin/main` 并解决冲突。
- **合回 main**：静态检查在 `main` 上稳定通过后，可将本分支上的脚本与修复 cherry-pick 或开 PR 合并；**不必**整分支快进合并若中间夹杂无关实验。

## 如何跑静态检查

在仓库根（需 Docker；**默认不**传 `docker --platform`，与本机已构建的 `auto-os/starry:latest` 变体一致。纯 x86 CI 上若镜像为 amd64 可显式 `CI_STARRY_DOCKER_PLATFORM=linux/amd64`）：

```bash
bash scripts/ci-starry-static.sh
```

若 `clippy` 仍被 `-D warnings` 阻塞，可暂时：

```bash
CI_STARRY_CLIPPY_NO_DENY_WARNINGS=1 bash scripts/ci-starry-static.sh
```

（脚本头注释说明：清零 warnings 后应去掉该变量，恢复 `-D warnings`。）

## 何时退役该分支

- `ci-starry-static.sh` 已在 `main` 的 CI 或发布流程中默认运行且 **无需** `CI_STARRY_CLIPPY_NO_DENY_WARNINGS` 即可绿；或
- 团队决定改用其他统一 CI 入口（届时可删除本分支或归档文档）。
