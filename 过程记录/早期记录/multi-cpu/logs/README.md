# Multi CPU Logs

Current logs:

```text
m6-smp4-mttcg-j4.log
m6-smp4-mttcg-j4.progress.csv
m6-smp4-mttcg-j4.done
```

`m6-smp4-mttcg-j4.log` is the first full M6 SMP4 MTTCG attempt:

```text
M6_QEMU_SMP=4
M6_TCG_THREAD=multi
CARGO_BUILD_JOBS=4
RAYON_NUM_THREADS=4
```

It failed quickly:

```text
rc=1 elapsed_sec=13
memory allocation of 8912904 bytes failed
```

Because this used `-accel tcg,thread=multi`, it is a speed experiment only. It must be isolated against a `thread=single` correctness run before drawing kernel correctness conclusions.

Expected future logs:

```text
build-smp.log
boot-smp-host-qemu.log
guest-cargo-build.log
```

Every multi-CPU log must record:

- source commit
- binary SHA256
- rootfs SHA256
- QEMU version
- full QEMU command
- `-smp` value
- `-accel` value
- cargo jobs / rayon threads
- workload
- wall time
- pass/fail

If `-accel tcg,thread=multi` is used, mark the result as a speed experiment unless it is later reproduced on real hardware or a correct emulator.
