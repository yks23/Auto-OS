# M6 Guest Self-build Result

## One-line Result

StarryOS successfully built a StarryOS kernel inside the StarryOS guest on the single-vCPU RISC-V QEMU path.

## What Was Run

- outer host: macOS development machine
- emulator: `/opt/homebrew/bin/qemu-system-riscv64`
- QEMU version: `10.2.2`
- guest target: `riscv64-qemu-virt`
- CPU mode: `-smp 1`
- TCG mode: `-accel tcg,thread=single`
- guest memory: `7G`
- build mode: guest `cargo build --release`
- rootfs image: `.guest-runs/rootfs-selfbuild-full-smp8.img`
- launch kernel: `.guest-runs/riscv64-m6/starry-up1.bin`

## Evidence

Full serial log copied into showtime:

```text
showtime/single-cpu/logs/m6-selfbuild-guest-pass.log
```

Key success lines:

```text
Finished `release` profile [optimized] target(s) in 132m 59s
[4] starryos pass2 finished rc=0 (attempts=1)
===M6-SELFBUILD-PASS===
  starry kernel ELF was just produced INSIDE the starry guest!
```

Produced artifacts:

```text
showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.elf
showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
showtime/single-cpu/binaries/riscv64-qemu-virt/SHA256SUMS
```

Boot smoke log:

```text
showtime/single-cpu/logs/boot-host-qemu.log
```

Checksums:

```text
0ae612a47d959e3ca13d45db3c291f5ec8c34a791a870babe8607e3c863b1245  starryos-singlecpu.elf
d5a8dfb2b181ec7cd44485228c41556a4d2bcadcba7910eff37c3008d51261a3  starryos-singlecpu.bin
2ed79158e165b6a9a24dc71e3391108693eede958a690c289bf00aa297d5abaa  m6-selfbuild-guest-pass.log
da4a06edcb5bb8f55f27c4c6a2dfaee33b8f1f542073d5cf266b53183a8a1d6f  boot-host-qemu.log
```

## What This Proves

- The guest StarryOS environment can run enough of the Rust toolchain and filesystem workload to compile the StarryOS kernel.
- The successful result is from a single-vCPU, single-threaded TCG correctness baseline, so it is a stable comparison point for later SMP runs.
- The final kernel artifact was produced inside the guest, not copied in from the host build directory.
- The extracted guest-built `starryos-singlecpu.bin` can boot under QEMU far enough to enter StarryOS userland/M6 init and print `===M6-SELFBUILD-PASS===` in resume mode.

## What It Does Not Yet Prove

- This is not an interactive shell/`ls /` smoke yet; it is a non-interactive boot smoke using the M6 rootfs init path.
- It does not prove multi-core speedup; multi-core remains a separate line under `../../multi-cpu/`.
- It does not prove the checkpoint tar writeback path is fully correct.

## Filesystem Readback Issue

The build succeeded, but host-side extraction found a consistency problem while reading the checkpoint tarball:

```text
/opt/tgoskits/.m6-checkpoints/target.tar
```

Observed behavior:

- Direct read from the original rootfs failed with `Input/output error`.
- `debugfs` showed duplicate or overlapping extents for `target.tar`.
- `e2fsck -fy` on a copy of the rootfs reported duplicate extent mapping and multiply-claimed blocks.
- After repairing only the copied image, the final `starryos` ELF could be extracted and converted to `.bin`.

Interpretation:

- The compile result is valid.
- The checkpoint/writeback path should become a separate StarryOS filesystem regression investigation.
- Future runs should copy the final ELF/bin out before writing a large checkpoint tar, or at least verify the checkpoint with a readback step immediately.

Large evidence kept outside showtime:

```text
.guest-runs/rootfs-selfbuild-full-smp8.img
.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
.guest-runs/riscv64-m6/guest-extract/target.tar.from-fsck
```
