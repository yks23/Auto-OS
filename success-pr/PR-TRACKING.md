# TGOSKit PR Tracking

这个文件记录本地需要持续跟进的 TGOSKit PR 状态。已合入或已批准的 PR 继续归档到同目录下的 `pr-*.txt`。

## Workflow

- 基线：OS 代码分支在提交 PR 前先合入目标 `origin/main`；面向 `rcore-os/tgoskits` 时同步检查 `upstream/main`。
- 提交：本地格式化、clippy/构建、相关 test-suite 通过后再 push 触发 GitHub Actions。
- 合入：Actions 全绿后再标记 ready、请求 review 或让用户批准。
- 文档：每个 PR 保留问题、修复、测试、CI 状态和下一步；合入后生成 `success-pr/pr-<number>.txt`。

## Upstream Merge Probe

2026-05-19 在临时 worktree `/private/tmp/tgoskits-dev-merge-main` 重新 fetch 后，尝试把 `upstream/main` 合入 fork 的 `origin/dev` 基线。结果不是可直接提交的小合并，已 `merge --abort` 保持 worktree 干净。

冲突分布：

- repo/CI/workspace：`.github/workflows/*`、`Cargo.toml`、`Cargo.lock`、`scripts/repo/repos.csv`、`scripts/test/clippy_crates.csv`
- kernel/user ABI：`components/axcpu`、`components/kspin`、`components/riscv_vcpu`、`components/axvmconfig`
- StarryOS OS 行为：`os/StarryOS/kernel` 下的 fs、pseudofs、syscall、task、rseq
- platform/build：`axhal`、`axdma`、`axplat-dyn`、`riscv64-qemu-virt`、`x86-qemu-q35`、`scripts/axbuild`
- test-suite：`test-suit/starryos` 和 `test-suit/arceos` 部分用例结构

结论：当前不应该做“整体 merge main”式 PR；后续 PR 仍按 OS 功能切分，在每个功能分支上小范围合目标基线并解决相关冲突。

## Dev vs Main Comparison

2026-05-19 再次 fetch `upstream/main`、`upstream/dev`、`origin/main`、`origin/dev` 后：

- `upstream/main = 11ffb5585`
- `upstream/dev = 19e43af91`
- `origin/dev = abbb705e6`
- `origin/dev` 相对 `upstream/main` 有 43 个 commit 不同名提交，其中 42 个非 merge patch 在 `git cherry upstream/main origin/dev` 中全部为 `-`，说明 patch 内容已被上游 main 等价吸收。
- 直接做 `origin/dev -> upstream/main` 的 tree diff 会显示约 2974 个文件变化，这是因为 fork dev 很旧且 upstream main 结构迁移很多，不代表还有 2974 个本地功能需要 PR。

结论：不要从 `origin/dev` 整体开 PR。需要提交时，从 `upstream/dev` 或 `upstream/main` 新建干净功能分支，只 cherry-pick 单个 OS 行为修复和对应 test-suite。

## Sync Branches

| Branch | Base | Merged | Result | Purpose |
| --- | --- | --- | --- | --- |
| `sync/dev-main-20260519` | `origin/dev@abbb705e6` | `upstream/main@11ffb5585` | pushed to `yks23/tgoskits`; merge commit `dfb8eaaac`; no unresolved conflicts | Bridge branch for inspecting/syncing old fork dev with public main. Not suitable as a normal OS feature PR because the remaining diff is broad: 123 files, mainly `drivers/`, `test-suit/`, `components/`, and `scripts/`. |

## Active PRs

| PR | Topic | Branch | CI state | Local evidence | Next action |
| --- | --- | --- | --- | --- | --- |
| #692 | robust futex cleanup | `fix/starry-robust-futex-cleanup` | 已在 fetched `upstream/dev` 观察到 `7119a62fe ... (#692)`；尚未出现在 `upstream/main` | `test-futex-robust-list` | 不再从 fork dev 整体提交；等待上游 dev->main 或按 main 单独 cherry-pick 需求处理 |
| #693 | vfork child-stack clone | `fix/starry-vfork-posix-spawn` | OPEN/UNSTABLE；多项 container check cancelled，board job 失败 | `test-vfork` | 失败点在 aarch64 board：`dash` SIGSEGV 后 `axfs-ng::HighLevelFile::sync` 在 atomic context 锁 page cache；需判断是否已有上游修复或另拆 FS/exit cleanup 修复 |

## Merged Or Approved Archive

| PR | Topic | Local archive |
| --- | --- | --- |
| #694 | IPv4-mapped IPv6 socket | `success-pr/pr-694.txt` |
| #695 | rsext4 inode bitmap | `success-pr/pr-695.txt` |
| #255 | archived upstream PR | `success-pr/pr-255.txt` |
| #203 | archived upstream PR | `success-pr/pr-203.txt` |
| #201 | archived upstream PR | `success-pr/pr-201.txt` |
| #200 | archived upstream PR | `success-pr/pr-200.txt` |

## Candidate Queue

| Candidate | Area | Status | Required test evidence |
| --- | --- | --- | --- |
| mutex unlock ordering | `axsync::Mutex` / SMP scheduler path | v28 guest build passed the old `quote` mutex self-owner panic and reached later kernel deps; final result was no PASS/no crash, then serial-log stall in `starry-kernel-lib` | SMP lock stress plus M6 guest cargo log without mutex self-owner panic; extract a separate responsiveness/scheduler regression for long CPU-bound guest rustc phases |
| FUTEX_PRIVATE_FLAG | StarryOS futex syscall | private worktree experiment exists | private/shared futex wait-wake and pthread smoke |
| SMP guest cargo build regression | StarryOS test-suite | not yet extracted | small parallel cargo workload under `qemu-smp4` |
| checkpoint tar readback | filesystem regression | candidate only | tar/readback/hash minimal FS test |
