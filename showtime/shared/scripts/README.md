# Scripts

This directory contains verified helper scripts.

Do not add a script here until the command has been run manually at least once and the matching documentation has been updated.

Verified scripts:

- `nested-qemu-smoke.sh`
  - injected as `/opt/run-tests.sh` into `.guest-runs/showtime/rootfs-nested-qemu.img`
  - log: `../../single-cpu/logs/boot-guest-qemu.log`
  - current result: outer StarryOS runs guest `qemu-system-riscv64`; inner StarryOS reaches userland and prints `===GUEST_BUILD_PASS===`

Planned scripts:

- `build-single-cpu.sh`
- `build-multi-cpu.sh`
- `run-host-qemu.sh`

Each script should print:

- source commit
- output path
- QEMU command, when applicable
- log path
