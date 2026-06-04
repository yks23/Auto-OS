# Single CPU RISC-V Artifacts

This directory contains the StarryOS kernel artifacts produced by the M6 guest self-build run.

## Files

```text
starryos-singlecpu.bin
starryos-singlecpu.elf
SHA256SUMS
build-info.md
```

## Provenance

- target: `riscv64-qemu-virt`
- build mode: StarryOS guest self-build
- QEMU mode: `-smp 1 -accel tcg,thread=single`
- result: `===M6-SELFBUILD-PASS===`
- full metadata: [`build-info.md`](build-info.md)

Do not place SMP or experimental kernels in this directory; use `../../../multi-cpu/binaries/` for those.
