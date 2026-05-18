# Auto-OS Showtime

这里收集 StarryOS self-build/showtime 相关的可运行产物、问题链路、测例和总结文档。目录按单 CPU 和多 CPU 两条线拆开，避免把“已经稳定可交付”和“仍在实验的并行加速”混在一起。

当前默认目标架构先按 `riscv64-qemu-virt` 组织，因为前面的 M6/selfbuild 与 SMP 实验都围绕这个目标推进。后续如果要补 `aarch64`、`x86_64` 或其它平台，可以在相同目录结构下增加对应子目录。

## 目录结构

```text
showtime/
├── README.md
├── single-cpu/
│   ├── README.md
│   ├── binaries/
│   │   └── riscv64-qemu-virt/
│   │       ├── starryos-singlecpu.bin
│   │       ├── starryos-singlecpu.elf
│   │       └── SHA256SUMS
│   ├── runbooks/
│   │   ├── host-linux-qemu.md
│   │   └── guest-starry-qemu.md
│   ├── logs/
│   │   └── m6-selfbuild-guest-pass.log
│   ├── tests/
│   │   ├── README.md
│   │   └── pr-cases.md
│   └── docs/
│       ├── m6-selfbuild-result.md
│       ├── issue-trail.md
│       ├── bugfixes.md
│       └── pr-plan.md
├── multi-cpu/
│   ├── README.md
│   ├── binaries/
│   │   └── riscv64-qemu-virt/
│   │       ├── starryos-smp4.bin
│   │       ├── starryos-smp4.elf
│   │       └── SHA256SUMS
│   ├── benchmarks/
│   │   ├── hello-world-builds.md
│   │   └── raw-results.csv
│   ├── logs/
│   │   ├── build-smp.log
│   │   ├── boot-smp-host-qemu.log
│   │   └── guest-cargo-build.log
│   ├── tests/
│   │   ├── README.md
│   │   └── stress-cases.md
│   └── docs/
│       ├── progress.md
│       ├── blockers.md
│       ├── qemu-tcg-notes.md
│       └── pr-candidates.md
└── shared/
    ├── scripts/
    │   ├── build-single-cpu.sh
    │   ├── build-multi-cpu.sh
    │   ├── run-host-qemu.sh
    │   └── run-guest-qemu.sh
    ├── rootfs/
    │   └── README.md
    └── references/
        ├── environment.md
        └── commands.md
```

## 范围

### 单 CPU

目标：准备一个已知可用的单 CPU `riscv64-qemu-virt` StarryOS binary，并配套足够的构建日志、启动日志和 runbook。

当前已经完成的是 M6 guest self-build：StarryOS guest 在 `-smp 1 -accel tcg,thread=single` 下完成 `cargo build --release`，日志中出现 `===M6-SELFBUILD-PASS===`，并已把 guest 内产出的 `.elf/.bin` 放入 `single-cpu/binaries/riscv64-qemu-virt/`。

接下来仍需单独验证这个新产物可以在以下环境启动：

- host Linux 下的 QEMU
- guest StarryOS 中启动的 QEMU（确认可用后补齐）

这条线还要记录按时间顺序发现的问题、修掉的 bug、对应测例，以及未来提交 PR 时可以直接引用的说明。

### 多 CPU

目标：记录真实 SMP guest build 加速的进展，包括 benchmark 数据、并行 guest cargo build 暴露的内核问题、QEMU 风险点，以及足够稳定后可以提交 PR 的修复候选。

这条线必须把“速度提升”和“正确性风险”分开写。特别是 RISC-V QEMU TCG 下使用 `-smp N` 时，要明确记录是否用了 MTTCG，以及它对 guest 原子操作正确性的影响。

## 产物规则

- binary 放在 `single-cpu/binaries/` 或 `multi-cpu/binaries/`，不要把实验性 SMP kernel 混进单 CPU 稳定路径。
- 每个 binary 都需要记录：
  - build command
  - source commit
  - target architecture/platform
  - boot command
  - boot log
  - SHA256 checksum
- 每个准备提交 PR 的 bug 都需要记录：
  - symptom
  - root cause 或当前假设
  - minimal reproducer/test
  - fix commit 或 patch 位置
  - verification command/log

## 当前文档入口

1. M6 guest self-build 结果：[`single-cpu/docs/m6-selfbuild-result.md`](single-cpu/docs/m6-selfbuild-result.md)
2. 单 CPU 总览：[`single-cpu/README.md`](single-cpu/README.md)
3. 单 CPU host QEMU runbook：[`single-cpu/runbooks/host-linux-qemu.md`](single-cpu/runbooks/host-linux-qemu.md)
4. 单 CPU guest Starry QEMU runbook：[`single-cpu/runbooks/guest-starry-qemu.md`](single-cpu/runbooks/guest-starry-qemu.md)
5. 单 CPU bug/PR 线索：[`single-cpu/docs/bugfixes.md`](single-cpu/docs/bugfixes.md)
6. 多 CPU 总览：[`multi-cpu/README.md`](multi-cpu/README.md)
7. 多 CPU benchmark：[`multi-cpu/benchmarks/hello-world-builds.md`](multi-cpu/benchmarks/hello-world-builds.md)
8. 多 CPU 风险与 blocker：[`multi-cpu/docs/blockers.md`](multi-cpu/docs/blockers.md)
9. QEMU TCG 说明：[`multi-cpu/docs/qemu-tcg-notes.md`](multi-cpu/docs/qemu-tcg-notes.md)
10. 环境和命令记录：[`shared/references/environment.md`](shared/references/environment.md), [`shared/references/commands.md`](shared/references/commands.md)
