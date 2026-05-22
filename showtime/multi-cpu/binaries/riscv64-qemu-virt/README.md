# Multi CPU RISC-V Binary Slot

Place experimental SMP `riscv64-qemu-virt` StarryOS artifacts here only after recording their provenance.

Expected files:

```text
starryos-smp4.bin
starryos-smp4.elf
SHA256SUMS
build-info.md
```

`build-info.md` should record:

- source commit
- branch/worktree
- kernel changes included
- build command
- QEMU `-smp` and `-accel` mode
- whether the binary is for speed experiment or correctness validation

Current known external artifact paths are listed in `../../docs/progress.md` and `../../../shared/references/environment.md`.

