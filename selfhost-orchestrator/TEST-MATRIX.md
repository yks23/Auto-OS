# 测试矩阵（Test Matrix）

每个阶段必须通过的测试，按阶段-架构-测试用例三维列出。

## 通用约定

- 所有测试用例放在 **`tests/selfhost/`**（Auto-OS 仓内，不在 tgoskits 内），CI build 时随 selfhost 镜像一起打包进 guest /opt/tests。
- 命名：`test_<feature>_<aspect>.c` 或 `.rs`。
- C 测试 musl 静态编译：`<arch>-linux-musl-gcc -static -O0 test_x.c -o test_x`。
- 每个测试 main 结尾 **必须** printf 一行 `[TEST] <name> PASS` 或 `[TEST] <name> FAIL: <reason>`，exit 0/1 跟随 PASS/FAIL。
- CI 用正则 `\[TEST\] (\w+) (PASS|FAIL)` 解析报告。
- 每个测试单文件、独立 main、不依赖 framework，方便快速增删。
- 测试启动方式：`scripts/run-selfhost-tests.sh ARCH`，内部 BusyBox shell 顺序跑所有 `test_*` 二进制。

## CI 触发模型

- 每 PR：sanity-check + build + ci-test（Phase 1 acceptance test）
- Nightly：S0 smoke（hello.c）
- Weekly：S1 medium（BusyBox） + S2 cargo + S3 bootstrap
- Manual：S4 reproducibility

---

## Phase 1：基线修复测试

### T1 多线程 execve

| 用例 | 预期 |
|---|---|
| `test_execve_basic.c` | 单线程 `execve("/bin/echo", {"echo","ok"}, ...)` exit 0，stdout 含 "ok" |
| `test_execve_multithread.c` | 主线程开 4 个子线程死循环，主线程 `execve` 必须成功，新映像 exit 0 |
| `test_execveat_dirfd.c` | 用 `openat(AT_FDCWD, "/bin", O_DIRECTORY)` 的 fd 调 `execveat(fd, "echo", ...)` 成功 |
| `test_execve_fdcloexec.c` | open fd 不带 O_CLOEXEC、open fd 带 O_CLOEXEC，execve 后前者保留、后者关闭 |

**验证脚本**：
```sh
for t in test_execve_basic test_execve_multithread test_execveat_dirfd test_execve_fdcloexec; do
    ./$t || { echo "$t FAIL"; exit 1; }
done
```

### T2 文件锁

| 用例 | 预期 |
|---|---|
| `test_flock_excl_block.c` | 子进程拿 LOCK_EX，父进程 LOCK_EX 阻塞；子 close 后父立刻拿到 |
| `test_flock_nonblock.c` | 子进程拿 LOCK_EX，父进程 LOCK_NB\|LOCK_EX 必须 EWOULDBLOCK |
| `test_flock_shared.c` | 两个 LOCK_SH 可以共存；其中任一升级 LOCK_EX 阻塞另一个 |
| `test_flock_close_release.c` | close fd 后锁立即释放，另一进程能拿 |
| `test_fcntl_setlk_overlap.c` | 进程 A 锁 [0,100) W，进程 B `F_GETLK` [50,200) 看到 conflict 信息 |
| `test_fcntl_setlkw_signal.c` | F_SETLKW 阻塞时收到 SIGUSR1，返回 EINTR |
| `test_fcntl_ofd_fork.c` | 父 F_OFD_SETLK 后 fork，子的同 fd 看到 OFD 锁是"自己的" |
| `test_fcntl_unknown_cmd.c` | `fcntl(fd, 12345, 0)` 必须 EINVAL，不是 0 |

### T3 AF_INET6

| 用例 | 预期 |
|---|---|
| `test_ipv6_socket_basic.c` | `socket(AF_INET6, SOCK_STREAM, 0)` ≥ 0 |
| `test_ipv6_bind_getsockname.c` | bind `[::]:0` 后 `getsockname` family == AF_INET6 |
| `test_ipv6_v4mapped_loopback.c` | v4 server bind 127.0.0.1:N，v6 client connect `[::ffff:127.0.0.1]:N` 通 |
| `test_ipv6_pure_v6_unreach.c` | connect 真 v6 地址（非 v4-mapped）必须 ENETUNREACH（fallback 模式） |
| `test_ipv6_v6only_setsockopt.c` | `IPV6_V6ONLY` getset 不报错 |

### T4 mount

| 用例 | 预期 |
|---|---|
| `test_mount_ext4_basic.sh` | `mkfs.ext4 /dev/vdb` 后 `mount -t ext4 /dev/vdb /mnt`，`echo hi > /mnt/x`，umount，重 mount，`/mnt/x` == "hi" |
| `test_mount_unknown_fstype.c` | `mount(_, _, "totally-fake", 0, _)` 必须 ENODEV，不是 0 |
| `test_mount_bind_dir.sh` | `mkdir /tmp/{a,b}; touch /tmp/a/x; mount --bind /tmp/a /tmp/b; ls /tmp/b/x 存在` |
| `test_umount_busy.c` | open 一个文件，umount 必须 EBUSY；MNT_DETACH 必须成功 |
| `test_umount_force.c` | MNT_FORCE 即使有 open fd 也 umount |
| `test_mount_9p_optional.sh` | （T18 后）9p 挂载并读写 |

### T5 资源限制

| 用例 | 预期 |
|---|---|
| `test_rlimit_stack_default.c` | `getrlimit(RLIMIT_STACK).rlim_cur >= 8*1024*1024` |
| `test_rlimit_stack_alloca.c` | 递归 alloca 4 MiB 不爆栈 |
| `test_rlimit_nofile_set.c` | `setrlimit(NOFILE, {32,32})`，dup 第 32 个返回 EMFILE |
| `test_rlimit_nofile_inherit.c` | setrlimit 后 fork，子 getrlimit 同值 |
| `test_rlimit_as_set.c` | setrlimit AS=128MB，mmap 200MB 必须 ENOMEM |
| `test_rlimit_data_brk.c` | setrlimit DATA=64MB，brk 超过必须 ENOMEM |
| `test_qemu_mem.sh` | `cat /proc/meminfo`，MemTotal ≥ 3.5 GiB（默认 4G 减开销） |
| `test_qemu_smp.sh` | `nproc` >= 4 |

---

## Phase 2：工具链测试

### T6 ptrace

| 用例 | 预期 |
|---|---|
| `test_ptrace_traceme_attach.c` | TRACEME + execve + parent waitpid 拿 SIGTRAP |
| `test_ptrace_peek_poke.c` | PEEKDATA 读到子进程内存，POKEDATA 改写后子进程看到改变 |
| `test_ptrace_getregs_setregs.c` | GETREGS 拿到合理寄存器；SETREGS 修改 PC 后 CONT，子进程跳到新地址 |
| `test_ptrace_singlestep.c` | SINGLESTEP 后子进程停在下一条指令，每步发 SIGTRAP |
| `test_strace_smoke.sh` | `strace /bin/ls` 输出含 "execve" "openat" "exit_group" |

### T7 prctl

| 用例 | 预期 |
|---|---|
| `test_prctl_pdeathsig.c` | child PR_SET_PDEATHSIG=SIGUSR1, parent _exit, child handler 触发 |
| `test_prctl_dumpable.c` | PR_GET_DUMPABLE 默认 1；SET 0 后 GET 返回 0 |
| `test_prctl_no_new_privs.c` | SET 后 GET 返回 1 |
| `test_prctl_keepcaps.c` | SET/GET 不报错 |
| `test_prctl_get_tid_address.c` | 与 set_tid_address 设置的地址一致 |

### T8 procfs

| 用例 | 预期 |
|---|---|
| `test_proc_self_exe.c` | `readlink("/proc/self/exe")` 返回该测试自己的真实路径 |
| `test_proc_cpuinfo.sh` | grep "processor"（x86）或 "isa"（riscv）有匹配 |
| `test_proc_meminfo.sh` | grep -E "MemTotal\|MemFree\|MemAvailable" 三行都在 |
| `test_proc_random_uuid.sh` | `cat /proc/sys/kernel/random/uuid` 输出 UUID 格式 |
| `test_proc_pid_maps.sh` | `cat /proc/self/maps` 含 `[stack]`、`[heap]` 行 |

### T9 缺失 syscall

| 用例 | 预期 |
|---|---|
| `test_waitid_pid.c` | `waitid(P_PID, child_pid, &info, WEXITED)` 拿到正确 si_status |
| `test_openat2_resolve_beneath.c` | RESOLVE_BENEATH 阻止 ../ 越界 |
| `test_personality_get.c` | `personality(0xffffffff)` 返回 0（PER_LINUX） |
| `test_setpriority_other_pid.c` | setpriority 改子进程 nice，getpriority 返回新值 |
| `test_getresuid_basic.c` | getresuid 三值都为 0（root） |

### T10 rootfs-selfhost 镜像

| 验证 | 预期 |
|---|---|
| 镜像存在 | `rootfs-selfhost-x86_64.img.xz`、`rootfs-selfhost-riscv64.img.xz` 在 GitHub releases |
| 大小检查 | 解压后 ≥ 2 GiB ≤ 6 GiB |
| 工具检查 | `gcc --version` `ld --version` `make --version` `pkg-config --version` `rustc --version`（如有）`cargo --version`（如有）都在 |
| 启动检查 | 替换 rootfs 后 `make ARCH=... selfhost` 能进 shell |

---

## Phase 3：S0 自我编译冒烟

### T12 S0 测试 harness

| 用例 | 预期 |
|---|---|
| `test_compile_hello_c.sh` | guest 内 `echo 'int main(){puts("hi");}' > /tmp/hello.c && gcc /tmp/hello.c -o /tmp/hello && /tmp/hello` 输出 "hi" |
| `test_compile_hello_cpp.sh` | g++ + iostream 静态编出 hello |
| `test_link_static.sh` | 链接一个 5 文件 C 项目静态产物 |
| `test_link_dynamic.sh` | 动态链接 + ld-musl 加载，./prog 正常运行 |

### T13 x86_64 vDSO

| 用例 | 预期 |
|---|---|
| `test_vdso_present_x86.sh` | `cat /proc/self/maps` 含 `[vdso]` 真实地址段 |
| `test_vdso_clock_gettime.c` | glibc 编出的二进制调 clock_gettime 不爆，结果合理（递增） |

### T14 AddrSpace 锁

| 用例 | 预期 |
|---|---|
| `test_concurrent_mmap.c` | 8 个线程并发 mmap+munmap 各 100 次，全部成功 |
| `bench_mmap_throughput.sh` | 与 RwLock 改造前对比，吞吐 ≥ 1.5x |

---

## Phase 4：稳定性 + CI

### T15-T17 杂项

| 用例 | 预期 |
|---|---|
| `test_signal_per_thread_skip.c` | 多线程并发 sigreturn，验证 skip flag 不串扰 |
| `test_mremap_real.c` | mremap 一段 mapped file，源映射的修改 page 在新地址可见（页表真共享） |
| `test_madvise_dontneed.c` | mmap 1GB ANON 写入后 MADV_DONTNEED，再读该区域全 0 |

### T18 9p

| 用例 | 预期 |
|---|---|
| `test_9p_mount.sh` | host 启动 `-fsdev local -device virtio-9p-pci`，guest mount 后 ls 能看到 host 目录 |
| `test_9p_rw.sh` | guest 写入 host 文件，host 端能看到 |

### T19 sysfs

| 用例 | 预期 |
|---|---|
| `test_sys_cpu_online.sh` | `cat /sys/devices/system/cpu/online` 输出 "0-3"（SMP=4 时） |

### T20 S1 中型测试

| 用例 | 预期 |
|---|---|
| `test_compile_busybox.sh` | guest 内解压 busybox 源码、`make defconfig && make -j4` 成功，产物可运行 |

---

## Phase 5：S2 cargo 测试

### T21 rust 工具链

| 验证 | 预期 |
|---|---|
| `rustc --version` | 输出版本 |
| `cargo --version` | 输出版本 |
| 静态二进制 | rustc 是 musl 静态版 |

### T22 网络

| 用例 | 预期 |
|---|---|
| `test_offline_mirror.sh` | guest 内配置 cargo mirror 到本地 ext4 上的 `crates-io-mirror`，能 build 出依赖 |
| （可选）`test_real_v6.sh` | 真 v6 地址 connect 通（T22 完成后） |

### T23 cargo 测试

| 用例 | 预期 |
|---|---|
| `test_cargo_new_build.sh` | guest 内 `cargo new foo && cd foo && cargo build` 成功 |
| `test_cargo_run.sh` | `cargo run` 输出 "Hello, world!" |
| `test_cargo_test.sh` | `cargo test` 跑一个简单 unit test 通过 |

---

## Phase 6：S3/S4 完全自举

### T26 S3 测试

```sh
# 1. host build kernel ELF，记录 sha256
make ARCH=x86_64 build
HOST_SHA=$(sha256sum starryos.elf | cut -d' ' -f1)

# 2. 在 guest 内同样 build
guest$ cargo xtask starry build --arch x86_64
guest$ sha256sum starryos.elf

# 3. 把 guest 出的 ELF 拿出，host QEMU 启动
qemu-system-x86_64 -kernel guest-built.elf ... 
# expect: 进入 BusyBox shell

# 4. （T27）若 GUEST_SHA == HOST_SHA → 完全 reproducible
```

### T27 reproducibility

需要：
- 固定时间戳（SOURCE_DATE_EPOCH）
- 固定 seed
- 工具链版本一致（host 与 guest）
- guest fs metadata 影响小

---

## CI 矩阵

`.github/workflows/selfhost.yml` 的 jobs（D4 负责）：

| Job | 触发条件 | 内容 |
|---|---|---|
| `selfhost-build-{arch}` | 每个 PR | `make ARCH=<arch> build` |
| `selfhost-ci-test-{arch}` | 每个 PR | `make ARCH=<arch> ci-test`，覆盖 Phase 1 全部测试 |
| `selfhost-smoke-{arch}` | 每个 PR | guest 内 hello.c 编译 |
| `selfhost-medium-{arch}` | nightly | guest 内 BusyBox 编译 |
| `selfhost-bootstrap-{arch}` | weekly | guest 内 cargo build kernel |
| `selfhost-reproducible-{arch}` | weekly | host vs guest sha256 |

每个 job 给 30-90 分钟超时；失败时把日志归档为 artifact。

---

## 测试基础设施

- **单架构跑所有测试的入口**：`tgoskits/scripts/run-selfhost-tests.sh ARCH` （D4 负责实现）
- **快速汇总**：测试结束后 BusyBox shell 内运行 `grep -E '\[TEST\]' /tmp/results.log | sort | uniq -c`
- **CI 报告**：JUnit XML 格式输出到 `selfhost-results-{arch}.xml`，GitHub Actions 直接展示
