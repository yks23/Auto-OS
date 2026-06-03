# TGOSKit PR Tracking

这个文件记录本地需要持续跟进的 TGOSKit PR 状态。已合入或已批准的 PR 继续归档到同目录下的 `pr-*.txt`。

## Live Audit 2026-05-30 01:25 CST

- #984 `docs(starry): add macOS HVF self-build app` 是当前复现内容 PR。已在临时 worktree `/private/tmp/tgoskits-macos-selfbuild-app` 将 `app/starry-macos-selfbuild` rebase 到最新 `upstream/dev@f0a27a0a4`，并 force-with-lease 推送到 `yks23/tgoskits@app/starry-macos-selfbuild`，新 HEAD 为 `be5c1230a`。
- #984 本地检查：`git diff --check upstream/dev...HEAD` PASS；`bash -n apps/starry/macos-selfbuild/check_rootfs.sh apps/starry/macos-selfbuild/guest-selfbuild.sh apps/starry/macos-selfbuild/prepare_rootfs.sh apps/starry/macos-selfbuild/run_selfbuild.sh` PASS；未提交 rootfs/kernel/log/showtime 大文件。
- #984 旧 CI 失败点：2026-05-27 的 run 中 `Test starry loongarch64 qemu / run_container` 失败，导致矩阵后续项取消；PR diff 是 `apps/starry` 下复现说明和 runner，未修改内核代码。已通过推送新 rebase commit 触发最新 dev 基线 CI。GitHub API 当前间歇 EOF/reset，后续由 `automations/pr-healer/run.sh` 继续跟踪新 CI。
- Harness 整理：新增 `automations/dev-sync/`，记录每天 09:00 同步 TGOSKit dev 的本地脚本；更新 `automations/pr-healer/`，修复 launchd 环境下 `gh` PATH 和 auto-fix 工作目录问题，auto-fix 现在使用 TGOSKit 专用 worktree。

## Live Audit 2026-05-26 03:58 CST

本次用 `gh pr view` / `gh pr checks` 重新核对 `rcore-os/tgoskits` 上的 PR 状态：

- 已合入 `dev`：#692 robust futex cleanup、#693 vfork parent blocking、#694 IPv4-mapped IPv6 socket、#695 rsext4 inode bitmap、#800 direct device full transfer、#842 SMP CPU topology、#843 RISC-V hwprobe、#844 tmpfs rename exec regression、#878 teardown usercopy/futex context、#879 RawMutex competitive wakeup、#885 file syscall thread snapshot。
- 仍 open 且 CI 绿：#889 `fix(aarch64): boot HVF SMP StarryOS`，`mergeable=MERGEABLE`，`mergeStateStatus=CLEAN`，已有 approve，等待 merge。
- 仍 open 且 CI 绿但 review blocked：#926 `fix(axtask): kick remote CPUs on SMP wakeups`，`mergeable=MERGEABLE`，`mergeStateStatus=BLOCKED`，`reviewDecision=CHANGES_REQUESTED`。唯一实质 review 点是 future wake 抢占后 wait queue 可能重复入队；远端分支已包含 `4b43d220c fix(axtask): guard wait queue re-enqueue`，在 `blocked_resched()` 中用 `if !curr.in_wait_queue()` 防止 stale waiter。后续 review 已 approve，但旧 changes-requested 仍未解除；下一步是回复/请求 ZR233 re-review/dismiss，而不是修 CI 或解决冲突。
- 当前性能侧新增 OS 发现：rsext4 普通 write/create/link/unlink/rename 路径每次都 `sync_to_disk()`，导致 ext4 小文件并行写入严重串行化。本地 HVF SMP8 实验补丁把普通 mutation 改为延迟到显式 `sync/fsync/flush` 落盘；短基准从 `j1/j2/j4/j8 = 21.5/21.2/43.5/47.5s` 改进到 `5.6/5.0/11.4/14.5s`，`j8` 约 `3.27x`。完整 StarryOS guest build 用只替换 kernel 的控制变量方式已 PASS，`jobs=8 elapsed=511s`；这个结果证明 kernel 可用和 FS 短基准收益成立，但完整 build 慢于当前最好 `331s`，后续拆 clean `dev` PR 时应按文件系统性能/语义收口，不声称 full build 新最快。

注：下面的长表保留每个 PR 的历史推进记录；若历史行仍出现 `Await review` 或旧 CI 叙述，以本次 Live Audit 为准。

## Workflow

- 基线：OS 代码分支提交 PR 前以 `dev` 为目标分支；本地先对齐最新 `origin/dev`，面向 `rcore-os/tgoskits` 时同步检查 `upstream/dev`。
- 提交：本地格式化、clippy/构建、相关 test-suite 通过后再 push 触发 GitHub Actions。
- 合入：Actions 全绿后再标记 ready、请求 review 或让用户批准。
- 文档：每个 PR 保留问题、修复、测试、CI 状态和下一步；合入后生成 `success-pr/pr-<number>.txt`。
- 检查：PR 分支不能相对 `origin/dev` 新增冲突标记；如果 `origin/dev` 自身已有历史标记，作为基线债记录，不混入 OS 功能 PR。

## Dev Baseline Correction

2026-05-19 用户确认 TGOSKit PR 目标应为 `dev`，不是 `main`。已停止把 `main` 作为功能 PR 基线的整理方式。

- `origin/dev = abbb705e6`
- `upstream/dev = 19e43af91`
- `origin/dev...upstream/dev = 43 / 1752`
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `git cherry upstream/dev origin/dev`：42 个非 merge patch 全部为 `-`，说明 fork dev 的功能补丁已被公共 dev 等价吸收，但 fork dev 分支拓扑仍明显落后。
- 已创建并推送 `sync/dev-live` 到 `yks23/tgoskits`，当前镜像 `origin/dev@abbb705e6`。
- 基线债：`origin/dev` 本身的 `docs/tgoskits-dependency.md` 含历史 conflict marker；后续 OS PR 只检查“不新增 marker”，不把该文档清理混入内核功能 PR。

后续策略：如果 PR 提到 fork 内部，以 `origin/dev` 切分支；如果 PR 提到 `rcore-os/tgoskits`，仍以 base branch `dev` 提交，并在功能分支上对齐公共目标 `upstream/dev`，避免把旧 fork dev 的大面积结构差异带进 PR。

### Daily Sync Log

2026-06-03

- fetch：FAILED（两次提权 `git fetch origin dev` / `git fetch upstream dev` 都被自动审批超时拒绝；本次无法确认 GitHub 最新远端状态）
- `origin/dev = abbb705e6`（基于本地缓存引用，可能已过期）
- `upstream/dev = f0a27a0a4`（基于本地缓存引用，可能已过期）
- `sync/dev-live = abbb705e6`（临时 worktree `/private/tmp/tgoskits-sync-dev-live` 仍干净对齐缓存的 `origin/dev`；`git status` / `git diff --check` PASS；push: SKIPPED，未在未确认新远端状态下推送）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1925`（基于本地缓存引用，可能已过期）
- 基线债：缓存的 `origin/dev` 仍包含历史 conflict markers：`docs/tgoskits-dependency.md`（例如 959/960/961/967/972/1024/1025/1163/1164/1165/1172/1177/1297 行）；本次未混入清理
- PR 分支：未新建、未重基、未推送；主 submodule 检出当前仍有用户在做的本地分支 `fix/starry-usercopy-nonthread-efault` 和未提交改动，因此未在主检出执行任何 reset/checkout

2026-06-03 12:25 CST rerun

- fetch：FAILED（再次尝试提权抓取 `origin/dev` / `upstream/dev`，仍被自动审批超时拒绝；本次结论继续基于本地缓存引用）
- `origin/dev = abbb705e6`
- `upstream/dev = b3adb9817`（相对同日更早记录中的 `f0a27a0a4` 已变化，但本次未能确认该变化来自最新远端抓取还是本地已有缓存更新）
- `sync/dev-live = abbb705e6`（在临时 worktree `/private/tmp/tgoskits-sync-dev-live.2s0zb7` 校验，`HEAD` 干净；`git diff --check` PASS；`git diff --check origin/dev...sync/dev-live` PASS）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1964`（基于本地缓存引用）
- 基线债：`origin/dev` 与 `sync/dev-live` 都仍包含历史 conflict markers：`docs/tgoskits-dependency.md` 959/960/961/967/972/1024/1025/1163/1164/1165/1172/1177/1297 等；未新增 marker，也未混入清理
- push：SKIPPED；在无法确认最新远端状态前，不推送 `origin/sync/dev-live`
- PR 分支：未新建、未重基、未推送；继续避免碰主 submodule 检出的用户分支 `fix/starry-usercopy-nonthread-efault`

2026-05-31

- fetch：FAILED（当前运行环境无法连接外网 GitHub：`Failed to connect to 127.0.0.1 port 6789`）；本次未更新 `origin` / `upstream` 引用
- `origin/dev = abbb705e6`（基于本地缓存引用，可能已过期）
- `upstream/dev = f0a27a0a4`（基于本地缓存引用，可能已过期）
- `sync/dev-live = abbb705e6`（已在干净临时 worktree `/private/tmp/tgoskits-sync-dev-live` 本地 reset 对齐 `origin/dev`；push: SKIPPED，同样受网络阻断）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1925`（基于本地缓存引用，可能已过期）

2026-05-28

- fetch：已更新本地引用（`origin` / `upstream`）
- `origin/dev = abbb705e6`（未变化）
- `upstream/dev = a0a71cbdc`（相对 2026-05-26 发生变化）
- `sync/dev-live = abbb705e6`（push: up-to-date；镜像 `origin/dev`）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1901`

2026-05-26

- fetch：已更新本地引用（`origin` / `upstream`）
- `origin/dev = abbb705e6`（未变化）
- `upstream/dev = d66584615`（相对 2026-05-25 发生变化）
- `sync/dev-live = abbb705e6`（push: up-to-date；镜像 `origin/dev`）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1870`

2026-05-25

- fetch：已更新本地引用（`origin` / `upstream`）
- `origin/dev = abbb705e6`（未变化）
- `upstream/dev = 73e21e907`（相对 2026-05-23 发生变化）
- `sync/dev-live = abbb705e6`（push: up-to-date；镜像 `origin/dev`）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1866`

2026-05-23

- fetch：已更新本地引用（`origin` / `upstream`）
- `origin/dev = abbb705e6`（未变化）
- `upstream/dev = b859b5737`（相对 2026-05-22 发生变化）
- `sync/dev-live = abbb705e6`（push: up-to-date；镜像 `origin/dev`）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1809`

2026-05-22

- fetch：已更新本地引用（`origin` / `upstream`）
- `origin/dev = abbb705e6`（未变化）
- `upstream/dev = 5b41966df`（相对 2026-05-21 发生变化）
- `sync/dev-live = abbb705e6`（push: up-to-date；镜像 `origin/dev`）
- `merge-base(origin/dev, upstream/dev) = 2dad8b394`
- `origin/dev...upstream/dev = 43 / 1781`

2026-05-21

- later update:
  - `upstream/dev = 5b41966df`
  - New PR candidates are prepared on clean `upstream/dev` worktrees, not on the
    old fork-dev submodule checkout:
    - #843 `fix/riscv-hwprobe-dev` pushed to `yks23/tgoskits` @ `cde0ec296`
    - #844 `test/tmpfs-rename-exec-elf` pushed to `yks23/tgoskits` @ `96df21fd5`
    - #842 `fix/starry-cpu-topology-sysfs` pushed to `yks23/tgoskits` @ `7774b3e13`
  - Current M6 lane uses the hwprobe/futex diagnostic kernel and an ext4 target
    directory; it has passed the tmpfs early build-script `Exec format error`
    point and is still running in `starry-kernel-lib`.

- fetch：已更新本地引用（`origin` / `upstream`）
- `origin/dev = abbb705e6`
- `upstream/dev = 5c08d32ca`
- `sync/dev-live = abbb705e6`（push: up-to-date）
- `origin/dev...upstream/dev = 43 / 1768`
- 规则执行记录：`ppoll` 用户缓冲区 race 已按 OS bug PR 候选检查；上游 `dev` 已包含 `8d5eb20d4 fix(starry): copy ppoll fds before blocking`，并已有 `test-suit/starryos/normal/qemu-smp1/bugfix/bug-poll-wait-user-buffer-race`，因此不重复提交本地旧候选分支。

2026-05-20

- fetch：已更新本地引用（`origin` / `upstream`）
- `origin/dev = abbb705e6`
- `upstream/dev = 19e43af91`
- `sync/dev-live = abbb705e6`（push: up-to-date）
- `origin/dev...upstream/dev = 43 / 1752`（未变化）

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
| `sync/dev-live` | `origin/dev@abbb705e6` | none | pushed to `yks23/tgoskits`; mirrors current fork dev | Rolling dev-baseline branch for PR preparation after the baseline correction. Not a feature PR. |
| `sync/dev-main-20260519` | `origin/dev@abbb705e6` | `upstream/main@11ffb5585` | pushed to `yks23/tgoskits`; merge commit `dfb8eaaac`; no unresolved conflicts | Bridge branch for inspecting/syncing old fork dev with public main. Not suitable as a normal OS feature PR because the remaining diff is broad: 123 files, mainly `drivers/`, `test-suit/`, `components/`, and `scripts/`. |

## Active PRs

| PR | Topic | Branch | CI state | Local evidence | Next action |
| --- | --- | --- | --- | --- | --- |
| #692 | robust futex cleanup | `fix/starry-robust-futex-cleanup` | 已在 fetched `upstream/dev` 观察到 `7119a62fe ... (#692)`；尚未出现在 `upstream/main` | `test-futex-robust-list` | 不再从 fork dev 整体提交；等待上游 dev->main 或按 main 单独 cherry-pick 需求处理 |
| TBD | robust futex unreadable head tolerance | `fix/starry-robust-futex-bad-head` @ `25344b461` | pushed to `yks23/tgoskits`; GitHub API currently unreachable from local `gh` (`error connecting to api.github.com`) | `git diff --check upstream/dev..HEAD` PASS; `cargo fmt --check --manifest-path os/StarryOS/starryos/Cargo.toml` PASS; previous local cache `cargo check -p starry-kernel --target riscv64gc-unknown-none-elf` PASS before upstream dependency refresh; x86_64 `syscall` case built kernel in 30.61s but QEMU rootfs missing locally | Create base `dev` PR when GitHub API is reachable; CI should run `test-futex-robust-list`; this is a narrow follow-up to #692 for unreadable robust-list head pointer |
| #693 | vfork parent blocking | `fix/starry-vfork-posix-spawn` @ `4503b5fb3` | pushed 2026-05-23 CST；PR title/body updated to `fix(starry): preserve vfork parent blocking`；Actions run `26305672447`：riscv64/x86_64/aarch64 Starry QEMU、clippy、format、sync-lint 已过；仅 `Test starry loongarch64 qemu / run_container` fail，日志显示 `apk-curl` 下载 Alpine index 1200s timeout，非 vfork case；PR 仍显示 `reviewDecision=CHANGES_REQUESTED` | `git diff --check HEAD^..HEAD` PASS; `cargo fmt --check` PASS; `test-vfork` now expects all `CLONE_VFORK` children, including private child-stack cases, to block parent until exec/exit; loongarch busybox/non-network suites通过到 43/44，失败点是网络 apk/curl；local macOS `cargo xtask clippy --package starry-kernel` blocked by existing `ax-percpu` / Mach-O section baseline | 需要 maintainer/admin rerun failed loongarch job，或由我追加 no-op commit 触发新 CI；然后请求 reviewer 重新检查 semantic blocker |
| #800 | direct device full transfer | `fix/dev-zero-full-transfer` @ `6aeb2566e` | 2026-05-23 已在独立 worktree 重放到最新 `rcore-os/tgoskits dev` 并 force-with-lease 推送；open PR 已从 `mergeStateStatus=DIRTY/BLOCKED` 变为 `CLEAN`，冲突已消；旧 `reviewDecision=CHANGES_REQUESTED` 已消；CI run `26308003915` 全 PASS；已评论状态：<https://github.com/rcore-os/tgoskits/pull/800#issuecomment-4522444116> | `cargo fmt` PASS; `cargo clippy -p ax-fs-ng --target riscv64gc-unknown-none-elf -- -D warnings` PASS; `cargo xtask starry test qemu --arch {riscv64,x86_64,aarch64,loongarch64} --test-group normal --test-case bugfix --list` PASS; test-suite moved to `normal/qemu-smp1/bugfix/test-dev-zero-full-transfer`; local host `cargo xtask clippy --package ax-fs-ng` blocked by baseline Mach-O/percpu issue; GitHub Actions PASS | 等维护者 review/merge；当前不再是冲突、CI blocker 或旧 review blocker |
| TBD | StarryOS SMP cargo build progress | `fix/starry-smp-cargo-build` @ `44f0fd9d5` | 本地已提交；push 被当前 DNS 阻断：`Could not resolve host: github.com` | `cargo fmt --check`; `git diff --check`; Docker direct `cargo build -p starryos --target riscv64gc-unknown-none-elf --features ax-feat/defplat,ax-feat/smp,qemu --release` 2m27s PASS; manual QEMU smoke: `smp = 4`, `online cpus: 4`, `TEST PASSED`, `===SMP-HEARTBEAT-RC:0===` | 网络恢复后 `git push -u origin fix/starry-smp-cargo-build`，再开 base `dev` PR 并等 Actions |
| #843 | RISC-V hwprobe compatibility | `fix/riscv-hwprobe-dev` @ `cde0ec296` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/843>; 2026-05-23 CST `isDraft=false`, `mergeStateStatus=CLEAN`, `mergeable=MERGEABLE`; Actions 20 pass / 0 fail | `git diff --check upstream/dev..HEAD` PASS; `cargo fmt --check` PASS; grouped `qemu-smp1/bugfix/bug-riscv-hwprobe` test added; M6 integration kernel removes `Unimplemented syscall: riscv_hwprobe` spam | Await review/approval |
| #844 | tmpfs rename exec ELF regression | `test/tmpfs-rename-exec-elf` @ `96df21fd5` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/844>; 2026-05-23 CST `isDraft=false`, `mergeStateStatus=CLEAN`, `mergeable=MERGEABLE`; Actions 20 pass / 0 fail | `sh -n busybox-tests.sh` PASS; `git diff --check` PASS; adds BusyBox tmpfs copy -> rename -> ELF magic -> exec regression; upstream dev already has `DirNode::rename()` `user_data` migration shape | Await review/approval; if future CI regresses, decide whether extra kernel fix is needed |
| #842 | SMP CPU topology exposure | `fix/starry-cpu-topology-sysfs` @ `7774b3e13` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/842>; 2026-05-23 CST `isDraft=false`, `mergeStateStatus=CLEAN`, `mergeable=MERGEABLE`; Actions 20 pass / 0 fail | `git diff --check` PASS; `cargo fmt --all -- --check` PASS after format fix; qemu-smp4 topology regression covers sysconf/cpuinfo/sysfs/affinity | Await review/approval |
| #878 | teardown usercopy/futex context | `fix/starry-teardown-usercopy-futex` @ `4ea538d62` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/878>; 2026-05-23 CST `isDraft=false`, `mergeStateStatus=CLEAN`, `mergeable=MERGEABLE`; CI rollup shows container/qemu/self-hosted jobs SUCCESS with expected matrix SKIPPED jobs | `git diff --check upstream/dev...HEAD` PASS; `cargo fmt --check` PASS; existing robust futex/mt-execve tests cover teardown ABI; PR body saved in `success-pr/pr-draft-starry-teardown-usercopy-futex.md`; macOS `cargo xtask clippy --package starry-kernel` blocked by baseline Mach-O/percpu section errors | Await user/maintainer review and approval; if review asks for a narrower teardown regression, add it as a follow-up commit |
| #879 | RawMutex competitive wakeup | `fix/axsync-rawmutex-competitive-wakeup` @ `86ae26dd2` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/879>; 2026-05-23 CST `isDraft=false`, `mergeStateStatus=CLEAN`, `mergeable=MERGEABLE`; CI rollup shows container/qemu/self-hosted jobs SUCCESS with expected matrix SKIPPED jobs | `git diff --check upstream/dev...HEAD` PASS; `cargo fmt --check` PASS; new `test-suit/starryos/normal/qemu-smp4/test-rawmutex-handoff`; PR body saved in `success-pr/pr-draft-axsync-rawmutex-competitive-wakeup.md`; macOS `cargo xtask clippy --package ax-sync` blocked by baseline Mach-O/percpu section errors | Await user/maintainer review and approval; keep an eye on fairness/performance feedback from RawMutex competitive wake semantics |
| #885 | file syscall thread context snapshot | `fix/starry-syscall-thread-snapshot` @ `5313aec45` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/885>; based on latest `upstream/dev`; initial CI mostly passed but `starry riscv64 qemu` failed in the new test because `CLONE_THREAD` returned `ENOENT`; pushed test-only fix `5313aec45` to use waitable clone workers; second CI run `26310481991` 全 PASS；`mergeStateStatus=CLEAN`；已从 draft 标为 ready | `git diff --check` PASS; `cargo fmt --all --check` PASS; `cargo check -p starry-kernel --target riscv64gc-unknown-none-elf` PASS; `zig cc -target riscv64-linux-musl ... test-openat-umask-smp/c/src/main.c` PASS; `cargo xtask starry test qemu --arch riscv64 -g normal -c test-openat-umask-smp --list` PASS; local qemu run blocked because macOS lacks `debugfs` and Docker CLI hung without output; GitHub Actions 全 PASS; #885 kernel passed guest synthetic cargo leaf16 and leaf64; full M6 j8 reached real starry-kernel cargo but failed with guest rustc SIGSEGV under RISC-V MTTCG, no kernel panic | Await review/approval; do not claim this proves MTTCG cargo correctness, only that file-creation syscalls now use the syscall-entry thread consistently |
| #889 | aarch64 HVF SMP boot | `fix/aarch64-hvf-smp-boot` @ `e0126a1d4` | PR open: <https://github.com/rcore-os/tgoskits/pull/889>; base `dev`; `mergeable=MERGEABLE`, `mergeStateStatus=CLEAN`; GitHub Actions run `26319432299` 全部 SUCCESS 或预期 SKIPPED；已有 approve | `git diff --check` PASS; `cargo fmt --check` PASS; `cargo xtask clippy --package arm-gic-driver` PASS; `cargo xtask clippy --package ax-plat-aarch64-qemu-virt` PASS; aarch64-target `cargo clippy -p ax-runtime ...` PASS; `cargo xtask starry test qemu --arch aarch64 --test-group aarch64-hvf -c test-aarch64-hvf-smp8-smoke` PASS, QEMU run about 2.86s | 等维护者 merge；合入后作为 Apple Silicon/HVF 8-core 快反馈底座 |
| #984 | macOS HVF StarryOS self-build app docs | `app/starry-macos-selfbuild` @ `be5c1230a` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/984>; base `dev`; 2026-05-30 已 rebase 到 `upstream/dev@f0a27a0a4` 并推送，旧 CI 的 LoongArch container failure 已通过新 push 触发重跑；GitHub API 当前间歇 EOF/reset，待 pr-healer 继续跟踪新 rollup | `git diff --check upstream/dev...HEAD` PASS; `bash -n apps/starry/macos-selfbuild/check_rootfs.sh apps/starry/macos-selfbuild/guest-selfbuild.sh apps/starry/macos-selfbuild/prepare_rootfs.sh apps/starry/macos-selfbuild/run_selfbuild.sh` PASS; `merge-base --is-ancestor upstream/dev HEAD` PASS; PR 只提交 `apps/starry` 复现入口、配置模板和 README/RESULTS，不提交 rootfs/kernel/log/showtime 大文件；历史补充已区分默认复现、tuned local profile、host reference 和 speedup ratios | 等新 CI 完成；如果仍失败，优先用 `automations/pr-healer/run.sh` 获取失败 job/log，确认是否与本 PR diff 相关，再补最小修复或请求 maintainer rerun |
| TBD | stable directory offsets for tmpfs/rsext4 | local patch in `tgoskits` and `/private/tmp/tgoskits-hvf-opt`; test added as `bug-dir-cookie-unlink-rmdir` | not pushed; needs clean `upstream/dev` feature branch and full focused QEMU run | Before fix: SMP8 probe `FILE_COUNT=100` failed in tmpfs with `Directory not empty`; tmpfs-only fix moved failure to ext4; final raw-offset fix passed `FILE_COUNT=1500 EXEC_COUNT=300` with `smp=8`, log `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-probe-smp8-dir-cookie-rawoffset-rm-1500-20260523T194941.log`; rename-cookie follow-up kernel `/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-hvf-smp8-dir-cookie-rename-hvfopt-20260523.bin` passed `FILE_COUNT=1500 RENAME_COUNT=512 EXEC_COUNT=300`, log `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-probe-smp8-dir-cookie-rename-rm-1500-ren512-20260523T202446.log`; build `cargo xtask starry build --arch aarch64 -c /tmp/build-aarch64-hvf-smp8-mem4g.toml --smp 8` PASS; C syntax and bugfix list checks PASS | Split onto clean `upstream/dev`, run focused StarryOS regression for `getdents64` + unlink + rmdir on tmpfs/ext4 plus cross-directory tmpfs rename, then push base `dev` PR |
| #926 | axtask SMP wakeup progress after 8-core self-build tail | `fix/axtask-smp-wakeup-progress` @ `7a0b56574` | ready PR open: <https://github.com/rcore-os/tgoskits/pull/926>; branch pushed to `yks23/tgoskits`; base `dev`; `mergeable=MERGEABLE`，GitHub Actions 全部完成，format/sync-lint/clippy/std/Starry/ArceOS container QEMU/axvisor/self-hosted board checks SUCCESS 或预期 SKIPPED；后续 review 已 approve，但 ZR233 早先 `CHANGES_REQUESTED` 仍让 GitHub `mergeStateStatus=BLOCKED`; generic wait/file-lock is not the PR; scope is wakeup 专用 runqueue selector, future/wait queue resched, and remote runqueue IPI kick | `cargo fmt --check` PASS; `cargo check -p ax-task --target riscv64gc-unknown-none-elf --features "multitask smp ipi"` PASS; `cargo check -p arceos-wait-queue-remote-wake --target riscv64gc-unknown-none-elf --features ax-std` PASS; `cargo run -p tg-xtask -- arceos test qemu --list --test-group rust --test-case task/wait_queue_remote_wake` PASS; `cargo run -p tg-xtask -- arceos test qemu --arch riscv64 --test-group rust --test-case task/wait_queue_remote_wake --no-symbolize` PASS. Fingerprint wave old evidence: `jobs=1` no monitor `99s` PASS, `jobs=8+tickle` `110s` PASS, but `jobs=8` no monitor/tickle stalled beyond `140s`; wake-local evidence: fingerprint no-monitor/no-tickle PASS, full build `379s` PASS, same-kernel jobs=1 `449s`, jobs=6 `399s`, feature-slim jobs=8 `378s` | 请求 ZR233 re-review/dismiss old changes-requested。Do not claim 4x speedup; claim SMP wakeup progress fix with StarryOS self-build evidence |
| TBD | StarryOS `/proc/stat` monotonic CPU counters | `fix/proc-stat-monotonic-cpu-time` @ `2009098ce`; draft saved in `success-pr/pr-draft-proc-stat-monotonic.md` | pushed to `yks23/tgoskits`; draft PR creation blocked locally because `api.github.com` DNS/API access times out; compare URL: `https://github.com/rcore-os/tgoskits/compare/dev...yks23:tgoskits:fix/proc-stat-monotonic-cpu-time` | Root cause from 8-core self-build monitor: `/proc/stat` recomputed aggregate CPU time from currently-live tasks, so short-lived rustc/build-script children could make aggregate `cpu` counters go backwards after exit. Patch records boot-wide user/system CPU deltas from `TimeManager::tick()` and `poll()`, and `/proc/stat` reads that accumulator. Added `test-suit/starryos/normal/qemu-smp4/test-proc-stat-monotonic`. Validation: `git diff --check` PASS including untracked test via `git add -N`; `cargo fmt --check` PASS; AArch64 `cargo check -p starry-kernel --target aarch64-unknown-none-softfloat --no-default-features --features 'dev-log,ext4,ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/smp'` PASS `0.39s` after cache; host C syntax `cc -std=c11 -Wall -Wextra -Werror .../main.c` PASS; branch exists on origin at `2009098cea4212b544be674872f7285e75ffaa37` | Open base `dev` draft PR when GitHub API/DNS is reachable or via browser compare link; CI should run focused StarryOS qemu-smp4 case. This is observability correctness for CPU utilization, not direct 4x speedup |
| TBD | StarryOS dynamic debug feature gating | `perf/starry-dynamic-debug-feature-gating` @ `d415b1700` | local clean worktree based on `upstream/dev@73e21e907`; not pushed yet because Cargo registry validation is blocked by local index/network freshness for `log 0.4.30` | `git diff --check` PASS; `cargo fmt --check` PASS; `cargo metadata --offline --no-deps` confirms `ddebug.optional = true` and `dynamic_debug` activates `dep:ddebug`; guest fast profile evidence: optional-ddebug `jobs=8` PASS `341s`, same profile `jobs=1` PASS `422s`, same profile with `rustc -Z threads=2/3/4` PASS `331s/338s/349s`; same `threads=2` with `codegen-units=192` PASS but slower at `358s`; 2026-05-25 22:30 cargo tree retry still hit `index.crates.io` DNS failure (`Could not resolve host: index.crates.io`) and was killed to avoid blocking the main run; draft saved in `success-pr/pr-draft-starry-dynamic-debug-feature-gating.md` | Rerun `cargo tree -i ddebug` and AArch64 `cargo check -p starryos ... --no-default-features --features qemu,smp,gic-v3,cntv-timer,ax-feat/ipi` after Cargo index issue clears; then push and open PR targeting `dev`. Next low-risk feature graph candidate: make display/DRM/fb device support optional for self-build-style kernels; net-ng/smoltcp gating is higher risk because AF_UNIX/netlink/socket ABI and `/dev/log` share that layer |
| TBD | StarryOS display feature gating | `perf/starry-display-feature-gating` in `/private/tmp/tgoskits-display-gating-pr` | WIP local patch on `upstream/dev@73e21e907`; not committed or pushed yet because it is a cleanup PR candidate, not the main 4x speedup path | Patch scope: make `ax-display` optional behind `starry-kernel/display`, enable that feature from `starryos/qemu`, compile `/dev/fb0` plus `/dev/dri/card0` only with `display`, and also gate `dev/drm.rs`; `cargo fmt --check` PASS; `git diff --check` PASS; upstream worktree `cargo metadata --offline --no-deps` confirms `ax-display optional: true`; old full guest injection PASS `340s` but log has `python3: not found`, so patch did not apply; runner fixed to shell/sed injection; temp worktree feature-off `cargo tree -i ax-display` and `cargo tree -i ax-driver-display` show both packages absent; feature-off check on rootfs-line temp worktree PASS; upstream/dev worktree feature-off `cargo check -p starry-kernel --target aarch64-unknown-none-softfloat --no-default-features --features 'dev-log,ext4,ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/smp'` PASS `4.25s`; fixed-runner guest display-only gating PASS `348s`; display+DRM gating PASS `338s`; no display crates in either fixed log | Treat as OS feature graph cleanup, not speedup PR: `338s` is slower than best `331s`. Next action: if pushing, add PR body focused on headless self-build/profile cleanup and qemu display behavior preservation. Do not gate IP networking here; AF_UNIX/netlink/socket ABI and `/dev/log` make net-ng a higher-risk separate PR |
| TBD | ax-feat net-ng de-legacy cleanup | local experiment in `/private/tmp/tgoskits-featuregraph-actual`; runner knob `FAST_SELFBUILD_NETNG_DELEGACY=1` | WIP cleanup candidate; not committed or pushed yet because it needs a clean `upstream/dev` worktree and test-suite/PR wording | Patch idea: change `ax-feat/net-ng` so it directly enables `alloc`, `paging`, `ax-driver/virtio-net`, `irq`, `multitask`, and `ax-runtime/net-ng`, instead of enabling legacy `net` and pulling both `ax-net` and `ax-net-ng`; static evidence: `cargo tree -i ax-net` shows legacy `ax-net` absent, `cargo tree -i ax-net-ng` still present, AArch64 `cargo check -p starry-kernel --target aarch64-unknown-none-softfloat --no-default-features --features 'dev-log,ext4,ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/smp'` PASS `4.56s`; guest evidence: full self-build PASS `346s`, crate count `282 -> 281`, log has `FAST-SELFBUILD-NETNG-DELEGACY` and no `Compiling ax-net`; display+DRM gating combined with this cleanup PASS `359s`, crate count `279`, still no `ax-net/ax-display/ax-driver-display` | Treat as OS feature graph hygiene, not speedup PR: `346s` and combined `359s` are slower than best `331s`. Next action: if promoting, create clean branch from `origin/dev`, add a focused test/metadata validation or cargo tree note, and write PR around removing accidental legacy network stack compilation while preserving `ax-net-ng` behavior |
| TBD | user-copy cold page prepopulate | `fix/starry-usercopy-cold-page` @ `179aef0fd` | pushed to `yks23/tgoskits`; draft PR create blocked by `gh` keyring/API access | `cargo fmt`; `cargo fmt --check`; `git diff --check upstream/dev`; host C syntax smoke PASS; added StarryOS bugfix case `/usr/bin/bug-usercopy-cold-page`; diagnostic M6 reruns show the old `clone.rs` owner panic is replaced by a later `munmap` owner blocker after reaching real cargo | 网络/API 恢复后运行 `gh pr create --repo rcore-os/tgoskits --head yks23:fix/starry-usercopy-cold-page --base dev --draft`；CI/Linux 环境补跑完整 StarryOS bugfix group；不要把新的 `munmap/aspace` 问题混进这个 PR |

## Merged Or Approved Archive

| PR | Topic | Local archive |
| --- | --- | --- |
| #694 | IPv4-mapped IPv6 socket | `success-pr/pr-694.txt` |
| #695 | rsext4 inode bitmap | `success-pr/pr-695.txt` |
| upstream dev | poll/ppoll user-buffer race | `8d5eb20d4 fix(starry): copy ppoll fds before blocking`; includes `bug-poll-wait-user-buffer-race` test-suite |
| #255 | archived upstream PR | `success-pr/pr-255.txt` |
| #203 | archived upstream PR | `success-pr/pr-203.txt` |
| #201 | archived upstream PR | `success-pr/pr-201.txt` |
| #200 | archived upstream PR | `success-pr/pr-200.txt` |

## Candidate Queue

| Candidate | Area | Status | Required test evidence |
| --- | --- | --- | --- |
| mutex unlock ordering | `axsync::Mutex` / SMP scheduler path | v28 guest build passed the old `quote` mutex self-owner panic and reached later kernel deps; final result was no PASS/no crash, then serial-log stall in `starry-kernel-lib` | SMP lock stress plus M6 guest cargo log without mutex self-owner panic; extract a separate responsiveness/scheduler regression for long CPU-bound guest rustc phases |
| FUTEX_PRIVATE_FLAG | StarryOS futex syscall | private worktree experiment exists | private/shared futex wait-wake and pthread smoke |
| SMP guest cargo build regression | StarryOS test-suite | extracted as `test-smp-heartbeat` in `fix/starry-smp-cargo-build`; branch commit `44f0fd9d5` | StarryOS heartbeat userland progress under `qemu-riscv64 -smp 4 -accel tcg,thread=single`; next step is CI test runner after push |
| checkpoint tar readback | filesystem regression | candidate only | tar/readback/hash minimal FS test |
| riscv_hwprobe ENOSYS noise | StarryOS syscall ABI | conservative implementation pushed as `fix/riscv-hwprobe-dev`; current M6 hwprobe-kernel run shows no `Unimplemented syscall: riscv_hwprobe` spam | `bug-riscv-hwprobe`: syscall 258 normal keys, unknown key, invalid flags, explicit CPU set/count, bad pointer |
| RawMutex wait in atomic context | `axsync::Mutex` caller path under SMP cargo build | mutex-owner diagnostic reached `lock_api v0.4.14` then failed: waiter=`os/StarryOS/kernel/src/mm/access.rs:269:10`, owner=`os/StarryOS/kernel/src/syscall/task/clone.rs:204:55`; this identified the user-copy cold-page PR candidate | first PR candidate is `fix/starry-usercopy-cold-page`, which removes normal cold user-copy/string faults from the IRQ-off page-fault path |
| SMP CPU topology mismatch | StarryOS procfs/sysfs/sysconf/affinity | ready PR #842 open on latest `upstream/dev`; CI 20 pass / 0 fail | qemu-smp4 affinity regression proves sysconf, `/proc/cpuinfo`, `/sys/devices/system/cpu/online`, and affinity round-trip |
| tmpfs renamed ELF readback | StarryOS tmpfs/page-cache/exec | ready PR #844 open; upstream dev already has a likely `DirNode::rename()` user_data migration fix; CI 20 pass / 0 fail | busybox regression copies ELF to tmpfs temp path, renames final path, verifies ELF magic, then executes final path |
| user-copy cold page fault | StarryOS user memory access | branch `fix/starry-usercopy-cold-page` pre-populates user slices before no-fault copy and pre-populates null-terminated user string pages before volatile reads, so normal cold anonymous pages do not enter the IRQ-off page-fault path | `bug-usercopy-cold-page`: `getcwd` and `read` write into untouched anonymous pages; `open` reads an empty path from an untouched anonymous page and returns `ENOENT` |
| munmap/aspace lock contention | StarryOS VM / syscall mm | after applying the user-copy PR shape, M6 reaches `compiler_builtins/core/proc-macro2` then fails with waiter=`access.rs:311:33`, owner=`syscall/mm/mmap.rs:276:56` | add a focused `mmap/munmap + concurrent syscall user-buffer` reproducer or stronger caller logging; split as a separate PR only after root cause is stable |
| stable directory offsets | tmpfs + rsext4 `getdents64` ABI | local fix validated by HVF SMP8 short probe; follow-up rename-cookie fix passed 1500 file + 512 rename + 300 exec probe; needs clean PR branch | `bug-dir-cookie-unlink-rmdir` should create > one getdents buffer worth of files, read/delete in rm-style loop, assert final `rmdir` on tmpfs/ext4, and cover cross-directory tmpfs rename cookie uniqueness |
| cargo wait/jobserver tail | StarryOS process/pipe/poll/wait/thread/file-lock semantics | `test-cargo-jobserver-wait` now passes in hand-injected SMP8 StarryOS with 13 phases; direct rustc and Cargo mini short chains also PASS; full cargo rerun4 reproduces cargo-only sleep at `259/288` with eventfd/pipe/socket fds and no children | next short test should target complete-build-graph-only state or cargo cache/fingerprint interactions before proposing any OS PR |
