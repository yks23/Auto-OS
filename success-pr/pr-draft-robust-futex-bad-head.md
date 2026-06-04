# fix(starry): tolerate unreadable robust futex head

## Summary

Stop thread exit from warning or failing when userspace registered an
unreadable robust-list head pointer.

Add a `test-futex-robust-list` regression where a pthread calls
`set_robust_list((void *)1, sizeof(struct robust_list_head))` and exits.

## Root Cause

Linux allows `set_robust_list` to record a user pointer without validating that
the pointed memory is currently readable. StarryOS already tolerated bad list
entries during exit cleanup, but the first read of the robust-list head itself
still returned `BadAddress` to `do_exit`, producing noisy and fragile
`exit robust list failed: AxErrorKind::BadAddress` cleanup.

This path is hot in pthread/rustc-heavy workloads and showed up repeatedly
during StarryOS guest self-build experiments.

## Fix

Treat an unreadable robust-list head as userspace cleanup state: log it at
debug level and return `Ok(())`. Valid heads, pending entries, and regular
owner-death cleanup keep the existing behavior.

## Why These Areas

- `os/StarryOS/kernel/src/task/ops.rs`: owns robust futex cleanup during thread
  exit.
- `test-suit/starryos/normal/qemu-smp1/syscall/test-futex-robust-list`: already
  covers robust-list ABI and owner-death behavior, so the bad-head pointer
  tolerance belongs in the same suite.

## Test Plan

```text
git diff --check upstream/dev..HEAD
cargo fmt --check --manifest-path os/StarryOS/starryos/Cargo.toml
cargo check -p starry-kernel --target riscv64gc-unknown-none-elf
cargo xtask starry test qemu --arch x86_64 -c syscall
```

Local status:

- `git diff --check upstream/dev..HEAD`: PASS
- `cargo fmt --check --manifest-path os/StarryOS/starryos/Cargo.toml`: PASS
- `cargo check -p starry-kernel --target riscv64gc-unknown-none-elf`: PASS on
  the local cached baseline before the latest upstream dependency refresh;
  retry on the new upstream/dev baseline is currently blocked by
  `index.crates.io` DNS.
- `cargo xtask starry test qemu --arch x86_64 -c syscall`: kernel build PASS in
  `30.61s`; QEMU run blocked locally because
  `tmp/axbuild/rootfs/rootfs-x86_64-alpine.img` is missing.

## Remaining Risk

CI should provide the final StarryOS test-suite run. This patch is intentionally
small and does not change robust-list pointer registration semantics.
