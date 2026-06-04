# PR #889: fix(aarch64): boot HVF SMP StarryOS

URL: https://github.com/rcore-os/tgoskits/pull/889
Branch: `fix/aarch64-hvf-smp-boot`
Base: `rcore-os/tgoskits:dev`

## Problem

Apple Silicon 上使用 QEMU HVF + GICv3 + `-smp 8` 启动 StarryOS 时，启动路径会依次暴露三个 OS 层问题：

- GICv3 Distributor 启动期 bulk reset 触发 QEMU HVF `Assertion failed: (isv)`。
- secondary CPU 在 current task 初始化前打开 timer/GIC 路径，导致 `current task is uninitialized`。
- aarch64 QEMU virt 的 GIC MMIO 窗口只有 1MB，不足以覆盖 8 CPU GICR redistributor frames。

## Fix

- 收敛 GICD 启动期 bulk reset，避免 HVF 下的宽 MMIO reset loop。
- secondary CPU 先初始化 scheduler/current task，再执行 per-CPU later init。
- 将 aarch64-qemu-virt GIC MMIO window 扩到 2MB。
- 新增 `test-aarch64-hvf-smp8-smoke`，验证 `smp = 8` 且进入 StarryOS userland。

## Evidence

```bash
git diff --check
cargo fmt --check
cargo xtask clippy --package arm-gic-driver
cargo xtask clippy --package ax-plat-aarch64-qemu-virt
AX_CONFIG_PATH=/private/tmp/tgoskits-hvf-opt/tmp/axbuild/axconfig/starryos/aarch64-unknown-none-softfloat/.axconfig.toml \
  cargo clippy -p ax-runtime --target aarch64-unknown-none-softfloat \
  --no-default-features \
  --features 'alloc,buddy-slab,ipi,irq,multitask,paging,rtc,smp,ax-driver,display,fs-ng,input,net-ng' \
  -- -D warnings
cargo xtask starry test qemu --arch aarch64 --test-group aarch64-hvf -c test-aarch64-hvf-smp8-smoke
```

Result: local HVF SMP8 smoke PASS, QEMU run about 2.86s, total about 6.86s.

## CI

Initial GitHub Actions run `26319432299`: `Detect changed paths` PASS; formatting/sync-lint started passing; broad container/QEMU matrix still pending.
