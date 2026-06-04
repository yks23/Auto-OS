# StarryOS M6 full guest build reproduction guide

This guide records the reproducible path for compiling `starryos` inside a
StarryOS RISC-V guest. It is intentionally separate from raw logs and disk
images: reviewers should be able to reproduce the environment and understand
what evidence proves success without downloading `.guest-runs/` artifacts.

Date of the current baseline: 2026-05-17.

## Goal

Build the final StarryOS ELF inside the guest:

```text
/opt/tgoskits/.m6-work/target/riscv64gc-unknown-none-elf/release/starryos
```

The build runs under QEMU with the StarryOS kernel as the guest OS. The guest
then runs Alpine musl `rustc`/`cargo` from `/opt/alpine-rust` and builds the
same `tgoskits` workspace for `riscv64gc-unknown-none-elf`.

## Layers and ownership

| Layer | What it owns | Important paths |
| --- | --- | --- |
| Host | Docker image/rootfs preparation and QEMU launch | `scripts/demo-m6-selfbuild.sh`, `tests/selfhost/build-selfbuild-rootfs.sh` |
| QEMU | RISC-V machine model and vCPU count | `-machine virt`, `-smp N`, `-accel tcg,thread=single|multi` |
| Guest StarryOS | Linux-compatible syscalls, ext4/tmpfs, process and scheduler behavior | `tgoskits/os/StarryOS` |
| Guest toolchain | `rustc`, `cargo`, `rust-src`, linker | `/opt/alpine-rust`, `/usr/bin/ld.lld` |
| Guest workspace | The actual StarryOS build | `/opt/tgoskits`, `/opt/tgoskits/.m6-work/target` |

The PR-facing OS result is the guest successfully running enough Linux/Rust
userspace to compile StarryOS itself. The Docker and script pieces exist to make
that OS result repeatable.

## Fast setup

Build or reuse the Docker image once:

```bash
docker build -t auto-os/starry -f Dockerfile .
```

Build or reuse the M6 rootfs:

```bash
bash tests/selfhost/build-selfbuild-rootfs.sh
```

When iterating, avoid rebuilding the whole rootfs. The rootfs is a raw ext4
image, so local hotfixes can be injected with:

```bash
bash scripts/hotfix-m6-rootfs-lld.sh .guest-runs/rootfs-selfbuild-full-smp8.img
```

The current fast-feedback path uses:

- tmpfs for the guest `target/` directory: `M6_USE_TMPFS_WORK=1`
- checkpointed target tarball: `M6_TARGET_CHECKPOINT=1`
- lower Rust debug info: `M6_RUSTFLAGS_COMMON='-C debuginfo=0'`
- low cargo verbosity: `M6_CARGO_VV=0`
- useful heartbeats instead of verbose logs: `M6_GUEST_HEARTBEAT_SEC=60`
- bare-metal linker fallback: `/usr/bin/ld.lld` when `rust-lld` is absent

## Stable single-core baseline

Use this first. It is slow, but it is the correctness baseline for later SMP
speed comparisons:

```bash
M6_QEMU_SMP=1 \
M6_MAX_CPU_NUM=1 \
M6_QEMU_MEM=7G \
M6_TCG_THREAD=single \
CARGO_BUILD_JOBS=1 \
RAYON_NUM_THREADS=1 \
M6_USE_TMPFS_WORK=1 \
M6_WORK_TMPFS_SIZE=3584m \
M6_TARGET_CHECKPOINT=1 \
M6_COPY_TOOLCHAIN_EXEC=1 \
M6_RUSTFLAGS_COMMON='-C debuginfo=0' \
M6_SYSCALL_STATS_INTERVAL_SEC=0 \
M6_CARGO_VV=0 \
M6_RESULT=.guest-runs/riscv64-m6/results-full-smp1-j1-up-native-qemu-tmpfs-checkpoint-pass3-lld.txt \
bash scripts/demo-m6-selfbuild.sh
```

Equivalent native QEMU shape:

```bash
qemu-system-riscv64 \
  -nographic -machine virt -bios default \
  -smp 1 -m 7G -accel tcg,thread=single \
  -kernel .guest-runs/riscv64-m6/starry-up1.bin \
  -cpu rv64 -monitor none -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file=.guest-runs/rootfs-selfbuild-full-smp8.img,file.locking=off \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0
```

## Success evidence

A complete build must show all three facts:

```bash
rg -n 'starryos pass2 finished rc=0|===M6-SELFBUILD-PASS===|Finished' \
  .guest-runs/riscv64-m6/results-full-smp1-j1-up-native-qemu-tmpfs-checkpoint-pass3-lld.txt
```

Expected successful markers:

```text
[4] starryos pass2 finished rc=0
===M6-SELFBUILD-PASS===
Finished `release` profile [optimized] ...
```

The guest target should also contain:

```text
/opt/tgoskits/.m6-work/target/riscv64gc-unknown-none-elf/release/starryos
```

If the build uses tmpfs, the target directory is preserved through:

```text
/opt/tgoskits/.m6-checkpoints/target.tar
```

When a run fails, the failure trap should still save the checkpoint before
exiting. That turns late failures into resumable runs.

## Current time estimate

The current single-core run is in `[4] starryos-pass2`. At the latest sampled
point it had reached crates around `ax-driver-base` / `riscv_goldfish` after
about 58 minutes of wall time.

The previous single-core `starry-kernel` baselines reached the comparable
`ax-driver-base` region around guest time 2570-2615s and finished at 4868-5323s.
The current run reached the same region around guest time 3425s, so it is
roughly 1.3x slower at that checkpoint.

Practical estimate from that comparison:

```text
remaining: about 45-70 minutes
total single-core pass2: about 105-130 minutes
```

This is an estimate, not a success claim. The final proof is the success marker
and the `starryos` ELF above.

## Multi-core speed validation

Do not compare a cold 1-core build against a warm 8-core build. Use the same
rootfs state and the same checkpoint boundary.

Recommended sequence:

1. Finish the 1-core baseline and save `/opt/tgoskits/.m6-checkpoints/target.tar`.
2. Copy the rootfs before each SMP run so only one QEMU instance writes it.
3. Run 2 cores with 2 cargo jobs.
4. Run 8 cores with 8 cargo jobs.
5. Compare elapsed time for the same phase, preferably from the same checkpoint
   to `===M6-SELFBUILD-PASS===`.

2-core command:

```bash
cp .guest-runs/rootfs-selfbuild-full-smp8.img .guest-runs/rootfs-selfbuild-bench-smp2.img

M6_QEMU_SMP=2 \
M6_MAX_CPU_NUM=2 \
M6_QEMU_MEM=7G \
M6_TCG_THREAD=multi \
CARGO_BUILD_JOBS=2 \
RAYON_NUM_THREADS=2 \
M6_RESULT=.guest-runs/riscv64-m6/results-full-smp2-j2-mttcg.txt \
ROOTFS=.guest-runs/rootfs-selfbuild-bench-smp2.img \
bash scripts/demo-m6-selfbuild.sh
```

8-core command:

```bash
cp .guest-runs/rootfs-selfbuild-full-smp8.img .guest-runs/rootfs-selfbuild-bench-smp8.img

M6_QEMU_SMP=8 \
M6_MAX_CPU_NUM=8 \
M6_QEMU_MEM=7G \
M6_TCG_THREAD=multi \
CARGO_BUILD_JOBS=8 \
RAYON_NUM_THREADS=8 \
M6_RESULT=.guest-runs/riscv64-m6/results-full-smp8-j8-mttcg.txt \
ROOTFS=.guest-runs/rootfs-selfbuild-bench-smp8.img \
bash scripts/demo-m6-selfbuild.sh
```

Expected proof of real SMP acceleration:

```text
speedup = single_core_elapsed / smp_elapsed
target: 8-core elapsed <= single_core_elapsed / 4
```

If SMP panics with an address-space mutex reentry assertion, that is an OS
kernel bug rather than a Docker problem. The right fix is to shorten the
address-space lock lifetime in the page-fault path so file/COW population does
not run while holding a reentrant-faultable process address-space lock.

## Known noisy but non-fatal syscalls

During Rust builds the guest currently logs many lines like:

```text
sys_rseq registration is unsupported; returning ENOSYS
Unimplemented syscall: riscv_hwprobe
```

These do not currently stop cargo. They do make the serial log large and can
slow feedback. For benchmark runs, prefer rate-limiting or lowering these logs
once the syscall behavior is understood.

## What to include in a reviewer report

For each run, record:

```text
date/time
host CPU and memory
QEMU command line
guest vCPU count
CARGO_BUILD_JOBS
RAYON_NUM_THREADS
rootfs image path
log path
start marker
finish marker
elapsed time
artifact path or checkpoint path
failure marker, if any
```

Keep raw rootfs images, target directories, and huge logs out of git. Submit
the guide, scripts, and concise result summaries; provide artifact paths in the
local workspace for acceptance checks.
