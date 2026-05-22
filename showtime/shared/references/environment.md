# Environment

## Workspace

- root: `/Users/txc/code/Auto-OS`
- main project repo: `/Users/txc/code/Auto-OS/tgoskits`
- showtime docs: `/Users/txc/code/Auto-OS/showtime`

## Current focus

- single CPU target: `riscv64-qemu-virt`, `-smp 1`
- multi CPU target: `riscv64-qemu-virt`, `-smp 4`

## Current source points

| repo | branch | commit |
| --- | --- | --- |
| Auto-OS | `starryos-m6-reproduce-guide` | `970bc85a6f04e62a3e0da27cb2f45dee8fd8251f` |
| TGOSKit submodule | `fix/starry-robust-futex-cleanup` | `a81a6a7660ff2820631c7fd3dfe6d291ac023e60` |

## Relevant worktrees

| path | purpose |
| --- | --- |
| `/private/tmp/tgoskits-futex-private` | multi CPU futex/private + mutex experiment |
| `/private/tmp/tgoskits-pr692-clippy` | PR #692 clippy fix worktree |
| `/private/tmp/tgoskits-pr693` | PR #693 vfork worktree |
| `/private/tmp/tgoskits-pr694` | PR #694 IPv4-mapped IPv6 worktree |
| `/private/tmp/tgoskits-pr695` | PR #695 rsext4 inode bitmap worktree |

## Known produced artifacts outside showtime

M6 guest self-build large evidence:

```text
.guest-runs/rootfs-selfbuild-full-smp8.img
.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
.guest-runs/riscv64-m6/guest-extract/target.tar.from-fsck
```

Checksums:

```text
0f4aa5f8a577921157218cd9b4047fad8e54d62cd66403831acdd25a7b8dd4cf  .guest-runs/rootfs-selfbuild-full-smp8.img
86305c74d0060f878635ee4a352138ef39291ca6ab187cfb2b7678a90d964379  .guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
7f10197be3ddd13c7c3dbbdfb862f40e055b6bdd0a4ea25a4de67bad67c474c7  .guest-runs/riscv64-m6/guest-extract/target.tar.from-fsck
```

Experimental SMP4 kernel:

```text
/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.bin
/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.elf
```

These are not yet copied into `showtime/` because they still need source commit, checksum, run command, and boot logs.

## Secrets

Do not store tokens, private keys, or credential-bearing command output under `showtime/`.
