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

## Active PRs

| PR | Topic | Branch | CI state | Local evidence | Next action |
| --- | --- | --- | --- | --- | --- |
| #692 | robust futex cleanup | `fix/starry-robust-futex-cleanup` | OPEN/CLEAN；container 与 required host checks 绿，skipped 为矩阵限制 | `test-futex-robust-list` | 可请求 review/合入；继续观察是否有人工 review 要求 |
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
| mutex unlock ordering | `axsync::Mutex` / SMP scheduler path | v28 guest build passed the old `quote` mutex self-owner panic and reached later kernel deps; QEMU alive but serial log currently stalled in `starry-kernel-lib` | SMP lock stress plus M6 guest cargo log without mutex self-owner panic; if v28 stalls out, extract a responsiveness/scheduler regression |
| FUTEX_PRIVATE_FLAG | StarryOS futex syscall | private worktree experiment exists | private/shared futex wait-wake and pthread smoke |
| SMP guest cargo build regression | StarryOS test-suite | not yet extracted | small parallel cargo workload under `qemu-smp4` |
| checkpoint tar readback | filesystem regression | candidate only | tar/readback/hash minimal FS test |
