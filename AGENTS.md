# Project Notes

## Collaboration

The user is the StarryOS / Auto-OS project developer and is comfortable with RISC-V, QEMU, Rust, and OS kernel work. Prefer concise Chinese responses unless the user asks otherwise.

For long-running background tasks such as M6 guest builds, the user prefers automatic monitoring or periodic follow-up. When asked to publish changes, the usual target branch is `dev`.

## Execution Rules for M6 and OS Bugs

- The main delivery goal is a reproducible StarryOS M6 self-build result: StarryOS building StarryOS inside the guest, preferably with SMP/multi-job cargo enabled when correctness permits.
- If an OS-level bug is found while chasing M6 or multi-core compilation, immediately try to turn it into a TGOSKit PR-quality fix: root cause, minimal OS code patch, focused test-suit case, local validation notes, and PR body. Do not leave confirmed OS bugs only as showtime notes.
- If the feedback loop for a run exceeds 2 hours, stop treating the long run as the primary diagnostic. First shorten the loop by using a smaller repro, resume/cache, lower logs, a smaller cargo target, host-side preflight, or direct host QEMU instead of Docker when that removes avoidable overhead.
- If no concrete bug/root cause is visible, add logging or progress markers before rerunning the long path. Prefer high-signal logs: phase, heartbeat, current crate/process, syscall counters, panic/trap PC, guest exit status, and PASS/FAIL markers.
- Use subagents when useful, but keep the critical path local. Good splits are: one agent monitors logs and extracts high-signal status, one agent prepares report/PR evidence, and the main agent fixes the immediate blocker or runs the next validation.
- For reports, distinguish clearly between: confirmed OS fixes, experiment/infrastructure changes, QEMU/TCG limitations, and remaining blockers.

## TGOSKit Upstream and PR Workflow

For OS-level code changes in the `tgoskits` submodule, keep every feature branch close to the PR target baseline:

- The TGOSKit collaboration baseline is `dev`, not `main`. Before starting or updating a TGOSKit PR branch, fetch remotes and base the branch on the latest `origin/dev`.
- TGOSKit PRs must target the `dev` branch. If the public target is `rcore-os/tgoskits`, also compare with `upstream/dev` and record any divergence instead of silently mixing baselines.
- Do not submit local scripts, showtime artifacts, Docker-only workaround files, or broad repo reshuffles as OS fixes. Split PRs by OS behavior: kernel, syscall, filesystem, scheduler, synchronization, device, or test-suite behavior.
- Use temporary worktrees for risky upstream merges or conflict exploration. Abort failed merge attempts unless the conflict resolution is intentionally completed and validated.
- Run local validation before pushing a PR branch: `cargo fmt`, the narrow `cargo xtask clippy --package <crate>` or equivalent package check, and the relevant StarryOS/test-suit case. Documentation-only updates may use a lighter validation path.
- Validate PR branches against `origin/dev` by checking that the branch introduces no new conflict markers. If `origin/dev` already contains unrelated historical markers, record them as baseline debt and do not mix that cleanup into an OS feature PR.
- GitHub Actions can only run after a branch/PR is pushed. Push only after local validation is clean enough to justify CI, then wait for `gh pr checks` to report green before marking the PR ready, asking for approval, or considering it done.
- PR titles use Conventional Commits in English. PR bodies are written in Chinese and must cover problem/root cause, fix summary, why each changed area is used, test-suite evidence, and remaining risk.
- Keep local PR tracking up to date. Merged or approved PRs go under `success-pr/`; active or blocked PRs are tracked in `success-pr/PR-TRACKING.md` with branch, status, CI state, tests, and next action.
- Never store GitHub tokens or other credentials in repo files, PR descriptions, logs, or tracking documents. Use an existing authenticated `gh` session or a transient environment variable only for the command that needs it.

## QEMU RISC-V SMP

When running `qemu-system-riscv64` under TCG with `-smp N` where `N > 1`, include:

```sh
-accel tcg,thread=single
```

QEMU TCG LR/SC is broken under MTTCG on RISC-V: store-conditional can succeed spuriously because cross-hart reservation invalidation is not modeled correctly. This can break guest user-space atomic CAS, including Rust builds inside the guest.

Scripts using `-smp 1` are unaffected. Single-threaded TCG is slower, but required for correctness under QEMU TCG SMP. Real hardware or a correct emulator does not need this workaround.

The LR/SC context-switch fix using `sc.d t0, zero, (sp)` in `context_switch` is still correct for preempted LR/SC pairs within one hart, but it does not fix the cross-hart MTTCG issue.

## M6 Selfbuild

The project goal includes reaching the M6 self-hosting milestone: building StarryOS inside a QEMU TCG simulated StarryOS guest.

Useful M6 defaults and constraints:

- Use `.guest-runs/rootfs-selfbuild-riscv64.img` as the main selfbuild rootfs.
- Run guest cargo builds with `CARGO_BUILD_JOBS=1` and `RAYON_NUM_THREADS=1`; this avoids SMP kernel page faults under heavy I/O.
- Use `CARGO_INCREMENTAL=0` for guest build scripts.
- Use `RUSTC_BOOTSTRAP=1` with `-Z build-std=core,alloc,compiler_builtins` for bare-metal cargo invocations.
- In the guest cc wrapper, prefer Alpine `riscv64-alpine-linux-musl-gcc` / `g++`; Debian gcc and clang have caused failures in this path.
- For rootfs mount injection, if `/opt/alpine-rust/usr/lib/libscudo.so` is a real file, replace it with a symlink to `/lib/libc.musl-riscv64.so.1`; this works around QEMU TCG atomic emulation crashes.
- For M6 selfbuild, the kernel's baked-in `init.sh` delegates through `/opt/guest-onecrate-inner.sh`; replace that file with a small script that execs `/opt/run-tests.sh`.

To restart a full M6 run from the host:

```sh
docker run --rm --privileged \
  -v "$(pwd)":/work -w /work \
  auto-os/starry:latest \
  bash -c 'ROOTFS=/work/.guest-runs/rootfs-selfbuild-riscv64.img M6_QEMU_TIMEOUT_SEC=28800 CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 bash /work/scripts/demo-m6-selfbuild.sh' \
  2>&1 | tee /tmp/m6-full-overnight.log | tail -1
```

Use `M6_RESUME=1` only when an incremental resume is desired.

To check a running M6 log:

```sh
grep -a "Compiling" /tmp/m6-full-overnight.log | tail -10
grep -a "heartbeat phase" /tmp/m6-full-overnight.log | tail -3
grep -a "panic\|trap\|FAIL\|Segmentation" /tmp/m6-full-overnight.log | tail -5
grep -ac "Compiling" /tmp/m6-full-overnight.log
grep -a "qemu_alive" /tmp/m6-full-overnight.log | tail -3
```

If the run prints `===M6-SELFBUILD-PASS===` or `===M6-SELFBUILD-KERNEL-LIB-PASS===`, extract `/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos` from the rootfs into `.guest-runs/riscv64-m6/starry-guest.elf`, then boot-test the guest-built kernel.
