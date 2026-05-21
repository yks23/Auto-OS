# TGOSKit PR Tracking

这个文件记录本地需要持续跟进的 TGOSKit PR 状态。已合入或已批准的 PR 继续归档到同目录下的 `pr-*.txt`。

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

2026-05-21

- later update:
  - `upstream/dev = 5b41966df`
  - New PR candidates are prepared on clean `upstream/dev` worktrees, not on the
    old fork-dev submodule checkout:
    - `fix/riscv-hwprobe-dev` pushed to `yks23/tgoskits` @ `cde0ec296`
    - `test/tmpfs-rename-exec-elf` pushed to `yks23/tgoskits` @ `96df21fd5`
    - `fix/starry-cpu-topology-sysfs` pushed to `yks23/tgoskits` @ `f9396549c`
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
| #693 | vfork child-stack clone | `fix/starry-vfork-posix-spawn` | OPEN/UNSTABLE；多项 container check cancelled，board job 失败 | `test-vfork` | 失败点在 aarch64 board：`dash` SIGSEGV 后 `axfs-ng::HighLevelFile::sync` 在 atomic context 锁 page cache；需判断是否已有上游修复或另拆 FS/exit cleanup 修复 |
| #800 | direct device full transfer | `fix/dev-zero-full-transfer` @ `6b109364a` | PR created; checks not reported yet | `cargo fmt --check`; `git diff --check`; C syntax check; Docker `cargo check -p ax-fs-ng --target riscv64gc-unknown-none-elf --release`; StarryOS `test-dev-zero-full-transfer` PASS; direct `dd & dd & wait` PASS | 等 GitHub Actions 触发并变绿；若 CI 不自动触发，手动 rerun 或检查 workflow 条件 |
| TBD | StarryOS SMP cargo build progress | `fix/starry-smp-cargo-build` @ `44f0fd9d5` | 本地已提交；push 被当前 DNS 阻断：`Could not resolve host: github.com` | `cargo fmt --check`; `git diff --check`; Docker direct `cargo build -p starryos --target riscv64gc-unknown-none-elf --features ax-feat/defplat,ax-feat/smp,qemu --release` 2m27s PASS; manual QEMU smoke: `smp = 4`, `online cpus: 4`, `TEST PASSED`, `===SMP-HEARTBEAT-RC:0===` | 网络恢复后 `git push -u origin fix/starry-smp-cargo-build`，再开 base `dev` PR 并等 Actions |
| TBD | RISC-V hwprobe compatibility | `fix/riscv-hwprobe-dev` @ `cde0ec296` | pushed to `yks23/tgoskits`; PR not created because local `gh` token is invalid | `git diff --check upstream/dev..HEAD` PASS; `cargo fmt --check` PASS; grouped `qemu-smp1/bugfix/bug-riscv-hwprobe` test added; full QEMU/clippy still pending | Run package check/grouped test when not competing with M6; then open base `dev` PR and wait Actions |
| TBD | tmpfs rename exec ELF regression | `test/tmpfs-rename-exec-elf` @ `96df21fd5` | pushed to `yks23/tgoskits`; PR not created because local `gh` token is invalid | `sh -n busybox-tests.sh` PASS; `git diff --check` PASS; adds BusyBox tmpfs copy -> rename -> ELF magic -> exec regression; upstream dev already has `DirNode::rename()` `user_data` migration shape | Run qemu-smp1 busybox group, then open a test-only FS regression PR or attach to tmpfs fix if CI reproduces |
| TBD | SMP CPU topology exposure | `fix/starry-cpu-topology-sysfs` @ `f9396549c` | pushed to `yks23/tgoskits`; PR not created because local `gh` token is invalid | `git diff --check` PASS; `cargo fmt --check --manifest-path os/StarryOS/starryos/Cargo.toml` PASS; CMake config for qemu-smp4 regression PASS; Rust `cargo check` blocked by local network/offline crate availability | Run qemu-smp4 affinity/topology grouped test, then open base `dev` PR and wait Actions |
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
| SMP CPU topology mismatch | StarryOS procfs/sysfs/sysconf/affinity | pushed as `fix/starry-cpu-topology-sysfs` on latest `upstream/dev` | qemu-smp4 affinity regression should prove sysconf, `/proc/cpuinfo`, `/sys/devices/system/cpu/online`, and affinity round-trip |
| tmpfs renamed ELF readback | StarryOS tmpfs/page-cache/exec | pushed as `test/tmpfs-rename-exec-elf`; upstream dev already has a likely `DirNode::rename()` user_data migration fix | busybox regression copies ELF to tmpfs temp path, renames final path, verifies ELF magic, then executes final path |
| user-copy cold page fault | StarryOS user memory access | branch `fix/starry-usercopy-cold-page` pre-populates user slices before no-fault copy and pre-populates null-terminated user string pages before volatile reads, so normal cold anonymous pages do not enter the IRQ-off page-fault path | `bug-usercopy-cold-page`: `getcwd` and `read` write into untouched anonymous pages; `open` reads an empty path from an untouched anonymous page and returns `ENOENT` |
| munmap/aspace lock contention | StarryOS VM / syscall mm | after applying the user-copy PR shape, M6 reaches `compiler_builtins/core/proc-macro2` then fails with waiter=`access.rs:311:33`, owner=`syscall/mm/mmap.rs:276:56` | add a focused `mmap/munmap + concurrent syscall user-buffer` reproducer or stronger caller logging; split as a separate PR only after root cause is stable |
