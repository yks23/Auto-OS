# Single CPU Logs

Current logs:

```text
m6-selfbuild-guest-pass.log
boot-host-qemu.log
boot-host-qemu-guest-built-rerun.log
boot-host-linux-docker-qemu-guest-built.log
boot-compare-reference-host-linux-qemu.log
boot-guest-qemu.log
```

`m6-selfbuild-guest-pass.log` is the complete QEMU serial log for the successful M6 guest self-build run. It includes the final guest cargo build, checkpoint save attempt, and the success marker:

```text
Finished `release` profile [optimized] target(s) in 132m 59s
[4] starryos pass2 finished rc=0 (attempts=1)
===M6-SELFBUILD-PASS===
```

Metadata:

```text
source_commit=Auto-OS 970bc85a6f04e62a3e0da27cb2f45dee8fd8251f / TGOSKit a81a6a7660ff2820631c7fd3dfe6d291ac023e60
binary_sha256=d5a8dfb2b181ec7cd44485228c41556a4d2bcadcba7910eff37c3008d51261a3
elf_sha256=0ae612a47d959e3ca13d45db3c291f5ec8c34a791a870babe8607e3c863b1245
log_sha256=2ed79158e165b6a9a24dc71e3391108693eede958a690c289bf00aa297d5abaa
qemu_version=QEMU emulator version 10.2.2
command=see ../binaries/riscv64-qemu-virt/build-info.md
result=PASS, with separate filesystem readback issue during host extraction
```

Expected follow-up logs:

`boot-host-qemu.log` is a short QEMU boot smoke for the guest-built `starryos-singlecpu.bin`. It used the fsck-repaired rootfs copy in QEMU snapshot mode, reached StarryOS userland/M6 init, found the already-built guest kernel ELF, and printed:

```text
===M6-SELFBUILD-PASS===
  (resume: ELF already on virtio disk)
```

Metadata:

```text
binary_sha256=d5a8dfb2b181ec7cd44485228c41556a4d2bcadcba7910eff37c3008d51261a3
boot_log_sha256=da4a06edcb5bb8f55f27c4c6a2dfaee33b8f1f542073d5cf266b53183a8a1d6f
rootfs=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
rootfs_mode=snapshot
qemu_version=QEMU emulator version 10.2.2
result=PASS boot smoke; no panic/trap/fatal/error pattern found in the captured log
```

`boot-host-qemu-guest-built-rerun.log` is the latest repeat run using the same guest-built kernel artifact:

```text
kernel=showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
kernel_sha256=d5a8dfb2b181ec7cd44485228c41556a4d2bcadcba7910eff37c3008d51261a3
elf=showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.elf
elf_sha256=0ae612a47d959e3ca13d45db3c291f5ec8c34a791a870babe8607e3c863b1245
rootfs=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
rootfs_sha256=86305c74d0060f878635ee4a352138ef39291ca6ab187cfb2b7678a90d964379
rootfs_mode=snapshot
qemu_version=QEMU emulator version 10.2.2
qemu_smp=1
qemu_accel=tcg,thread=single
log_sha256=8511ae983b0cc837aea7ec03847b21e6698826140f0aa719a6c0c45a3178968a
result=PASS boot smoke; reached StarryOS userland and printed ===M6-SELFBUILD-PASS===
```

Important lines from the rerun:

```text
arch = riscv64
platform = riscv64-qemu-virt
smp = 1
parallelism: mode=single-vcpu-single-thread nproc=1 CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1
found /opt/tgoskits/.m6-work/target/riscv64gc-unknown-none-elf/release/starryos — build already complete
===M6-SELFBUILD-PASS===
  (resume: ELF already on virtio disk)
```

Command:

```sh
timeout 180 qemu-system-riscv64 \
  -nographic \
  -machine virt \
  -bios default \
  -smp 1 \
  -m 7G \
  -accel tcg,thread=single \
  -kernel showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin \
  -cpu rv64 \
  -monitor none \
  -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img,file.locking=off,snapshot=on \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  > showtime/single-cpu/logs/boot-host-qemu-guest-built-rerun.log 2>&1
```

`boot-host-linux-docker-qemu-guest-built.log` repeats the boot smoke inside the Linux `auto-os/starry:latest` container, so it is the closest current evidence for the host Linux QEMU path:

```text
kernel=showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
kernel_sha256=d5a8dfb2b181ec7cd44485228c41556a4d2bcadcba7910eff37c3008d51261a3
rootfs=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
rootfs_mode=snapshot
container=auto-os/starry:latest
qemu_smp=1
qemu_accel=tcg,thread=single
log_sha256=78f8a083f7c5c9690992fbed0e2757ed2452afebf17fd8103e89f9de5f0cfdb7
result=PASS boot smoke; reached StarryOS userland and printed ===M6-SELFBUILD-PASS===
```

Important lines:

```text
Platform Name             : riscv-virtio,qemu
arch = riscv64
platform = riscv64-qemu-virt
smp = 1
parallelism: mode=single-vcpu-single-thread nproc=1 CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1
found /opt/tgoskits/.m6-work/target/riscv64gc-unknown-none-elf/release/starryos — build already complete
===M6-SELFBUILD-PASS===
  (resume: ELF already on virtio disk)
```

Command:

```sh
docker run --rm --privileged \
  -v "$PWD":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'timeout 180 qemu-system-riscv64 \
    -nographic \
    -machine virt \
    -bios default \
    -smp 1 \
    -m 7G \
    -accel tcg,thread=single \
    -kernel showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin \
    -cpu rv64 \
    -monitor none \
    -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img,file.locking=off,snapshot=on \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    > showtime/single-cpu/logs/boot-host-linux-docker-qemu-guest-built.log 2>&1'
```

Nested QEMU log:

`boot-guest-qemu.log` is the guest-Starry nested-QEMU smoke. It boots the guest-built kernel, reaches outer StarryOS userland, executes `../../shared/scripts/nested-qemu-smoke.sh` from `/opt/run-tests.sh`, then starts an inner `qemu-system-riscv64` with the same guest-built kernel and a 256M smoke rootfs.

Current result:

```text
===NESTED-QEMU-SMOKE-BEGIN===
outer StarryOS userland reached
kernel_under_test=/opt/nested/starryos-singlecpu.bin
inner_rootfs=/opt/nested/rootfs-smoke-riscv64.img
QEMU emulator version 11.0.0 (Debian 1:11.0.0+ds-2)
OpenSBI v1.8
arch = riscv64
platform = riscv64-qemu-virt
===GUEST_BUILD_PASS===
nested_qemu_rc=0
===NESTED-QEMU-INNER-BOOT-SEEN===
```

Metadata:

```text
kernel=showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
rootfs=.guest-runs/showtime/rootfs-nested-qemu.img
rootfs_sha256=4bc7cd6c6a2454da148923724eb7408b85840782ac7c16ae33699e9076f01cae
inner_rootfs=/opt/nested/rootfs-smoke-riscv64.img
script=showtime/shared/scripts/nested-qemu-smoke.sh
script_sha256=235c38bedfc2db72affac4f4ee1af20c74141cc63d01a0bc8f71af2431fad4e3
log_sha256=c8dee9f0d25ff3ea7fb93551db86d6377554255dd34e079c4df85149cc0c808a
result=PASS nested QEMU smoke; inner StarryOS reached userland and printed ===GUEST_BUILD_PASS===
```

If a run fails, keep the failing log and summarize it in `../docs/issue-trail.md`.

The A/B comparison between the original reference kernel and the guest-built kernel is summarized in:

```text
../docs/kernel-ab-comparison.md
```
