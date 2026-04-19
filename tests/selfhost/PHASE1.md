# Phase 1 测试用例索引（骨架）

本目录对应 `selfhost-orchestrator/TEST-MATRIX.md` §Phase 1。以下为全套用例状态；当前为 **SKELETON**：编译与 `[TEST] … PASS` 输出格式已统一，功能断言留待 T1–T5 实现者按 TODO 填充。

## T1 多线程 execve

| 文件 | 状态 |
|------|------|
| `test_execve_basic.c` | 骨架已就位 / 等待 T1 填充功能 |
| `test_execve_multithread.c` | 骨架已就位 / 等待 T1 填充功能 |
| `test_execveat_dirfd.c` | 骨架已就位 / 等待 T1 填充功能 |
| `test_execve_fdcloexec.c` | 骨架已就位 / 等待 T1 填充功能 |

## T2 文件锁

| 文件 | 状态 |
|------|------|
| `test_flock_excl_block.c` | 骨架已就位 / 等待 T2 填充功能 |
| `test_flock_nonblock.c` | 骨架已就位 / 等待 T2 填充功能 |
| `test_flock_shared.c` | 骨架已就位 / 等待 T2 填充功能 |
| `test_flock_close_release.c` | 骨架已就位 / 等待 T2 填充功能 |
| `test_fcntl_setlk_overlap.c` | 骨架已就位 / 等待 T2 填充功能 |
| `test_fcntl_setlkw_signal.c` | 骨架已就位 / 等待 T2 填充功能 |
| `test_fcntl_ofd_fork.c` | 骨架已就位 / 等待 T2 填充功能 |
| `test_fcntl_unknown_cmd.c` | 骨架已就位 / 等待 T2 填充功能 |

## T3 AF_INET6

| 文件 | 状态 |
|------|------|
| `test_ipv6_socket_basic.c` | 骨架已就位 / 等待 T3 填充功能 |
| `test_ipv6_bind_getsockname.c` | 骨架已就位 / 等待 T3 填充功能 |
| `test_ipv6_v4mapped_loopback.c` | 骨架已就位 / 等待 T3 填充功能 |
| `test_ipv6_pure_v6_unreach.c` | 骨架已就位 / 等待 T3 填充功能 |
| `test_ipv6_v6only_setsockopt.c` | 骨架已就位 / 等待 T3 填充功能 |

## T4 mount

| 文件 | 状态 |
|------|------|
| `test_mount_ext4_basic.sh` | 骨架已就位 / 等待 T4 填充功能 |
| `test_mount_unknown_fstype.c` | 骨架已就位 / 等待 T4 填充功能 |
| `test_mount_bind_dir.sh` | 骨架已就位 / 等待 T4 填充功能 |
| `test_umount_busy.c` | 骨架已就位 / 等待 T4 填充功能 |
| `test_umount_force.c` | 骨架已就位 / 等待 T4 填充功能 |
| `test_mount_9p_optional.sh` | 骨架已就位 / 等待 T4 填充功能 |

## T5 资源限制

| 文件 | 状态 |
|------|------|
| `test_rlimit_stack_default.c` | 骨架已就位 / 等待 T5 填充功能 |
| `test_rlimit_stack_alloca.c` | 骨架已就位 / 等待 T5 填充功能 |
| `test_rlimit_nofile_set.c` | 骨架已就位 / 等待 T5 填充功能 |
| `test_rlimit_nofile_inherit.c` | 骨架已就位 / 等待 T5 填充功能 |
| `test_rlimit_as_set.c` | 骨架已就位 / 等待 T5 填充功能 |
| `test_rlimit_data_brk.c` | 骨架已就位 / 等待 T5 填充功能 |
| `test_qemu_mem.sh` | 骨架已就位 / 等待 T5 填充功能 |
| `test_qemu_smp.sh` | 骨架已就位 / 等待 T5 填充功能 |

## 构建

见本目录 `Makefile`：`make ARCH=x86_64` / `make ARCH=riscv64` 生成 `out-<arch>/` 下静态二进制与可执行 `.sh` 副本。
