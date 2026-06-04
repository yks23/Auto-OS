# StarryOS Live Demo Commands

This directory contains small wrapper scripts for the final presentation. They
are meant to be run by hand, on stage, from the Auto-OS workspace.

## What already exists

- Guest-built StarryOS kernel ELF:
  `/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-guestbuilt-aarch64-hvf-j8.elf`
- Existing rootfs:
  `/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img`

The demo directory intentionally keeps five entry scripts. The scripts are
self-contained wrappers: they prepare the boot image when needed, copy a clean
rootfs using APFS clone when available, inject `/opt/hvf-auto.sh`, run QEMU/HVF
with `-cpu max`, and print explicit PASS markers.

## Five-script demo order

Run from the repository root:

```bash
cd /Users/txc/code/Auto-OS
```

Before running the long paths, each script can do a local environment check:

```bash
bash showtime-2/final/live-demo/01-build-starryos --check
bash showtime-2/final/live-demo/02-guest-build-starryos --check
bash showtime-2/final/live-demo/03-test-kernel-result --check
bash showtime-2/final/live-demo/04-try-kernel --check
bash showtime-2/final/live-demo/05-speed-ratios --check
```

1. Build StarryOS on the host as the reference baseline:

```bash
bash showtime-2/final/live-demo/01-build-starryos
```

Default setting: `PROFILE=aligned-fast ARCH=aarch64 SMP=1 JOBS=8`. This uses
the same AArch64/HVF feature set as the report (`gic-v3`, `cntv-timer`, SMP
config, no-LTO/opt0/cgu256) and produces a bootable kernel for the following
test/demo scripts. Set `SMP=8` only for the multi-core performance path; set
`PROFILE=xtask` only when you specifically want the upstream xtask build path.
The default command produces:

- `showtime-2/final/live-demo/out/starryos-host-aarch64-smp1.elf`
- `showtime-2/final/live-demo/out/starryos-host-aarch64-smp1.bin`

2. Build StarryOS inside StarryOS guest:

```bash
bash showtime-2/final/live-demo/02-guest-build-starryos
```

This boots the prepared StarryOS kernel, runs guest `cargo build`, and extracts:

- `showtime-2/final/live-demo/out/starryos-live-rebuilt.elf`
- `showtime-2/final/live-demo/out/starryos-live-rebuilt.bin`

Default setting: `QEMU_SMP=8`, `CARGO_BUILD_JOBS=8`,
`RAYON_NUM_THREADS=8`. The script prints
`===02-GUEST-BUILD-STARRYOS-PASS===` after extracting the rebuilt kernel. It
removes the temporary working rootfs by default; set `KEEP_ROOTFS=1` only when
debugging the guest filesystem after the run.

3. Test the kernel produced by the guest build:

```bash
bash showtime-2/final/live-demo/03-test-kernel-result
```

The test boots the kernel, enters StarryOS userland, runs `uname`, `nproc`, and
`ls -la /`, then prints `===TEST-KERNEL-RESULT-PASS===` if the kernel is usable.
By default it chooses `starryos-live-rebuilt.bin` if step 2 has produced one,
otherwise the stable `starryos-host-aarch64-smp1.bin` from step 1, otherwise the
prebuilt guest kernel. It infers `QEMU_SMP=1` for `smp1` kernels and `8` for the
multi-core kernels.

4. Try the kernel interactively:

```bash
bash showtime-2/final/live-demo/04-try-kernel
```

Inside StarryOS, useful commands:

```sh
ls -la /
nproc
cat /proc/cpuinfo
ls -la /opt/tgoskits
```

Exit QEMU with `Ctrl-A`, then `X`.

5. Print or rerun the speed-ratio evidence:

```bash
bash showtime-2/final/live-demo/05-speed-ratios
```

Default mode parses the existing evidence logs and writes
`showtime-2/final/live-demo/out/05-speed-ratios-summary.txt`. Use explicit
rerun flags only when time permits:

```bash
DEMO_TASK_COUNT=1000 bash showtime-2/final/live-demo/05-speed-ratios --run-demo
bash showtime-2/final/live-demo/05-speed-ratios --run-guest
bash showtime-2/final/live-demo/05-speed-ratios --run-host
```

Only these five scripts should be used in the final presentation.

## What the speed numbers mean

- `29s` host aligned reference j8: same StarryOS source, same AArch64/SMP8
  kernel config, same no-LTO/opt0/cgu256, slab/no-dynamic-debug profile used
  for the guest fast path; cargo/rustc runs on macOS host instead of inside the
  StarryOS guest. It builds the same kind of StarryOS kernel, but does not use
  guest filesystem/syscalls/scheduler. The same profile with
  `CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1` is `85s`, so host aligned compile
  reference speedup is `85s / 29s = 2.93x`.
- `331s` guest best: StarryOS guest on AArch64/HVF, booted with a StarryOS
  kernel and running `cargo build` inside the guest; `SMP=8`, `JOBS=8`,
  source/target in guest `/tmp`, `release_lto=false`, `opt-level=0`,
  `codegen-units=256`, `FAST_ALLOC_SLAB_ONLY=1`, and
  `FAST_SELFBUILD_NO_DYNAMIC_DEBUG=1`.
- `951s -> 331s = 2.87x`: guest-to-guest end-to-end tuning improvement from
  slow baseline to tuned best. This is not the strict jobs-only speedup.
- `422s -> 341s = 1.24x`: strict guest jobs-only comparison under the same
  optional-ddebug profile.
- `05-speed-ratios` prints the three requested 1-way vs 8-way comparisons:
  demo fork/exec benchmark, actual StarryOS guest compile, and macOS host
  aligned compile. For the report-compatible demo/guest numbers, QEMU/HVF stays
  at `SMP=8`; the compared variable is cargo/demo job parallelism `1 -> 8`.
- `642s -> 427s = 1.50x`: LTO/codegen/link serial-tail reduction from the
  default 8-core guest release profile to no-LTO plus opt0/cgu256. This is not
  a separately measured pure link-only benchmark.
