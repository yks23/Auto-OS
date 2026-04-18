# Phase 1 细化测试矩阵（syscall × case 级别）

每个测试用例必须明确：调用哪个 syscall、传什么参数、期望返回值/errno、要观察到什么副作用。骨架（PR #2）已就位，本文件是给 T1-T5 实现 subagent 的"填 TODO 合同"。

---

## 表格读法

```
| Test                       | Syscall(s) under test                  | Setup                          | Action                                          | Expected return | Expected errno | Side effect to observe          |
```

> ⚠️ **每个 test_xxx.c 的 main() 必须把 Action 列的所有步骤跑完，把 Expected 列的每一条用 assert 验证；任意一条不符就 `fail("..."); return;`，全部符合才 `pass();`。骨架里 TODO 已经写好了 Plan 大纲，实现时按下面 Action 列细化。**

---

## T1：多线程 execve + execveat

**Syscalls under test**：`execve` (59), `execveat` (322 on x86, 281 on riscv), `clone` (`CLONE_THREAD`), `wait4`

| Test | Syscall | Setup | Action | Expected return | Expected errno | Side effect |
|---|---|---|---|---|---|---|
| `test_execve_basic` | `execve` | 创建一个临时可执行 shim：`int main(){ exit(42); }`；写到 `/tmp/test_execve_shim` 并 chmod +x | fork → child 调用 `execve("/tmp/test_execve_shim", argv, envp)` → parent `wait4(child, &ws, 0, NULL)` | execve 在 child 不返回；wait4 返回 child PID | — | `WIFEXITED(ws) && WEXITSTATUS(ws) == 42` |
| `test_execve_multithread` | `execve`, `clone(CLONE_THREAD)` | `pthread_create` 启 4 个子线程，每个线程死循环 `pause()` | 主线程 `execve("/tmp/test_execve_shim", argv, envp)` 加载一个 `int main(){exit(43);}` | execve 不返回；外层 `wait4(child, ...)` 看到 exit 43 | — | 进程 PID 不变；4 个子线程被回收（不留僵尸 task） |
| `test_execveat_dirfd` | `execveat`, `openat` | `openat(AT_FDCWD, "/tmp", O_DIRECTORY)` 拿 dirfd；放好 shim 在 `/tmp/shim2`（exit 44） | `execveat(dirfd, "shim2", argv, envp, 0)` | 不返回；wait 看到 exit 44 | — | dirfd 在 exec 后行为符合 cloexec 规则（如果 open 时无 cloexec，仍开） |
| `test_execve_fdcloexec` | `execve`, `open`, `fcntl(F_GETFD)` | open 两个文件 `/tmp/keep`（无 cloexec）和 `/tmp/close`（O_CLOEXEC） | execve 一个 helper：`int main(int argc, char**argv){ int kf=atoi(argv[1]), cf=atoi(argv[2]); int r1=fcntl(kf, F_GETFD); int r2=fcntl(cf, F_GETFD); printf("%d %d\n", r1, r2); }` | exec 不返回 | helper 输出 `>=0 -1`（keep 还在、close 不在） | — |

### Sub-syscall 边界（实现侧必须覆盖，测试可以再补）

- `execve` 的 PID/TGID 保持
- `signal handler` 重置（`SIG_DFL`），但 mask 保留
- `set_child_tid` 清零
- 兄弟线程被 SIGKILL 后不留 zombie task
- 多线程 execve 不死锁（aspace 锁释放顺序）

---

## T2：flock + fcntl 记录锁

**Syscalls under test**：`flock` (143), `fcntl` (72) cmd=`F_SETLK`/`F_SETLKW`/`F_GETLK`/`F_OFD_SETLK`/`F_OFD_SETLKW`/`F_OFD_GETLK`，加上 `fork` / `wait4` / `pipe` 做同步

| Test | Syscall | Setup | Action | Expected | Side effect |
|---|---|---|---|---|---|
| `test_flock_excl_block` | `flock(LOCK_EX)` | 创建 `/tmp/flock_a`；建 pipe 用来子→父同步 | child open + `flock(fd, LOCK_EX)` → 写 pipe 通知 → sleep(1) → close(fd)；父 open + `read(pipe)` → `flock(fd, LOCK_EX)` 必须阻塞 ≥0.5s 后成功 | child flock 返回 0；父 flock 返回 0；阻塞时长 ≥ 500ms | — |
| `test_flock_nonblock` | `flock(LOCK_EX|LOCK_NB)` | child 拿 LOCK_EX 后 sleep(2) | 父 `flock(fd, LOCK_EX|LOCK_NB)` | -1 | `EWOULDBLOCK` (`EAGAIN`) | — |
| `test_flock_shared` | `flock(LOCK_SH)`, `flock(LOCK_EX|LOCK_NB)` | 两个进程都拿 LOCK_SH | 第三个 flock LOCK_EX|LOCK_NB | -1 | `EWOULDBLOCK` | LOCK_SH+LOCK_SH 共存 |
| `test_flock_close_release` | `flock`, `close` | child 拿 LOCK_EX 后**立刻** close fd（不显式 LOCK_UN） | 父 `flock(LOCK_EX|LOCK_NB)` | 0 | — | close 等价于 LOCK_UN |
| `test_fcntl_setlk_overlap` | `fcntl(F_SETLK)`, `fcntl(F_GETLK)` | 进程 A `F_SETLK` 区间 `[0, 100)` type=`F_WRLCK` | 进程 B 调 `F_GETLK` 区间 `[50, 200)`，参数 struct flock 类型 `F_WRLCK` | 0 | — | 返回的 `l_type == F_WRLCK`，`l_pid == A_pid`，`l_start == 0`，`l_len == 100` |
| `test_fcntl_setlkw_signal` | `fcntl(F_SETLKW)`, `kill(SIGUSR1)` | A 占 W 锁；安装 SIGUSR1 handler；fork B | B 在 [0,100) 调 `F_SETLKW`（必阻塞）；父在 100ms 后 `kill(B, SIGUSR1)` | -1 | `EINTR` | — |
| `test_fcntl_ofd_fork` | `fcntl(F_OFD_SETLK)`, `fork` | A `F_OFD_SETLK` `[0, 100)` W | A `fork()`；child 在**同一 fd** 上 `F_OFD_GETLK` `[0, 100)` | 0 | — | `l_type == F_UNLCK`（OFD 锁跨 fork 共享，child 视作"自己持有"） |
| `test_fcntl_unknown_cmd` | `fcntl(fd, 0x12345)` | 任意有效 fd | `fcntl(fd, 0x12345, 0)` | -1 | `EINVAL` | — |

### 实现必须做但测试不强制（D3 自检）

- 进程 SIGKILL 退出时遍历释放该进程的 record lock
- OFD 锁随 file description 引用计数到 0 释放
- 阻塞队列 FIFO 顺序

---

## T3：AF_INET6 socket（v4-mapped fallback 模式）

**Syscalls under test**：`socket` (41), `bind` (49), `connect` (42), `listen` (50), `accept` (43), `getsockname` (51), `getpeername` (52), `setsockopt` (54), `getsockopt` (55)

| Test | Syscall | Setup | Action | Expected | Errno |
|---|---|---|---|---|---|
| `test_ipv6_socket_basic` | `socket(AF_INET6, SOCK_STREAM, 0)`, `socket(AF_INET6, SOCK_DGRAM, 0)`, `close` | — | 各创一个 socket | 都 ≥ 0 | — |
| `test_ipv6_bind_getsockname` | `socket(AF_INET6)`, `bind`, `getsockname` | sockaddr_in6 = `[::]:0` | bind 后 `getsockname` 拿回 addr | bind 0；getsockname 0 | — | `addr.ss_family == AF_INET6`；端口 != 0 |
| `test_ipv6_v4mapped_loopback` | `socket(AF_INET, SOCK_STREAM)` (server)、`socket(AF_INET6, SOCK_STREAM)` (client)、`bind`/`listen`/`accept`/`connect` | server bind `127.0.0.1:0`，listen，记录端口 P；client 准备 sockaddr_in6 = `[::ffff:127.0.0.1]:P` | client connect → server accept → 双向写读一字节 | connect 0；accept ≥0；read/write 1 | — | server 收到的 byte == client 发的 |
| `test_ipv6_pure_v6_unreach` | `socket(AF_INET6)`, `connect` | sockaddr_in6 = `[2001:db8::1]:9999`（非 v4-mapped） | connect | -1 | `ENETUNREACH` 或 `EAFNOSUPPORT`（fallback 模式允许两者之一） | — |
| `test_ipv6_v6only_setsockopt` | `setsockopt(IPV6_V6ONLY)`, `getsockopt(IPV6_V6ONLY)` | socket(AF_INET6) | setsockopt 设为 1；getsockopt 读 | 都 0 | — | getsockopt 拿到 1（或至少不是错误） |

---

## T4：mount ext4 + bind

**Syscalls under test**：`mount` (165), `umount2` (166)

> ⚠️ ext4 测试需要 guest 内有第二块磁盘 `/dev/vdb` + 装 mkfs.ext4。CI 阶段如不可用，标 SKIP 并在测试 stdout 打印 `[TEST] xxx PASS (skipped: no /dev/vdb)`，**不 fail**。

| Test | Syscall | Setup | Action | Expected | Errno |
|---|---|---|---|---|---|
| `test_mount_ext4_basic.sh` | `mkfs.ext4 /dev/vdb`, `mount -t ext4`, `umount` | `[ -b /dev/vdb ] || skip` | `mkfs.ext4 /dev/vdb`；`mount -t ext4 /dev/vdb /mnt`；`echo hi > /mnt/x`；`umount /mnt`；`mount -t ext4 /dev/vdb /mnt`；`cat /mnt/x` | exit 0 | — | 第二次挂载后内容仍是 "hi" |
| `test_mount_unknown_fstype.c` | `mount(NULL, "/mnt", "totally-fake-fs", 0, NULL)` | `mkdir /mnt`（已存在 ok） | mount call | -1 | `ENODEV` | — |
| `test_mount_bind_dir.sh` | `mount --bind` | `mkdir /tmp/a /tmp/b; touch /tmp/a/x` | `mount --bind /tmp/a /tmp/b`；`ls /tmp/b/x`；`umount /tmp/b` | 0 | — | `/tmp/b/x` 可见 |
| `test_umount_busy.c` | `open`, `umount2(MNT_BUSY=0)`, `umount2(MNT_DETACH)` | bind /tmp/a /tmp/b；`open /tmp/b/x` 持有 fd | `umount2("/tmp/b", 0)` 必失败；再 `umount2("/tmp/b", MNT_DETACH)` 必成功 | -1, then 0 | `EBUSY` | DETACH 后即使 fd 还在也成功 |
| `test_umount_force.c` | `umount2(MNT_FORCE)` | 同上 setup，open fd | `umount2("/tmp/b", MNT_FORCE)` | 0 | — | — |
| `test_mount_9p_optional.sh` | `mount -t 9p` | `[ -e /dev/virtio-ports ] || skip` | （T18 之前都 skip）`mount -t 9p hostsrc /workspace -o trans=virtio,version=9p2000.L` | exit 0 or skip | — | — |

---

## T5：资源限制（rlimit）+ Makefile 默认值调整

**Syscalls under test**：`prlimit64` (261), `getrlimit` (97 on x86 only), `setrlimit` (160 on x86), `mmap`, `dup`

| Test | Syscall | Setup | Action | Expected | Errno |
|---|---|---|---|---|---|
| `test_rlimit_stack_default.c` | `prlimit64(RLIMIT_STACK, NULL, &out)` | — | 读默认 RLIMIT_STACK | 0 | — | `out.rlim_cur >= 8 * 1024 * 1024`（8 MiB） |
| `test_rlimit_stack_alloca.c` | （隐式：栈分配） | — | 在 main 里 `volatile char buf[4*1024*1024]; buf[0]=1;` | exit 0 | — | 不爆栈（不 SIGSEGV） |
| `test_rlimit_nofile_set.c` | `prlimit64(RLIMIT_NOFILE, &new, NULL)`, `dup` | open `/dev/null` 成 base fd | `prlimit64(RLIMIT_NOFILE, {32,32})`；while(`dup(0)` >= 0) count++；最后一次 dup 必失败 | dup count <= 31 | last dup `EMFILE` | 计数 + errno 都对 |
| `test_rlimit_nofile_inherit.c` | `prlimit64(set)`, `fork`, `prlimit64(get)` | parent set NOFILE={64,64} | fork → child `prlimit64(RLIMIT_NOFILE, NULL, &out)` | 0 | — | `out.rlim_cur == 64` |
| `test_rlimit_as_set.c` | `prlimit64(RLIMIT_AS)`, `mmap` | — | set AS=128 MiB；`mmap(NULL, 200<<20, RW, MAP_PRIVATE|MAP_ANON, -1, 0)` | mmap == `MAP_FAILED` | `ENOMEM` | — |
| `test_rlimit_data_brk.c` | `prlimit64(RLIMIT_DATA)`, `brk` | 记录初始 `brk(0)` | set DATA=64 MiB；`brk(initial + 200<<20)` | -1 (or current) | `ENOMEM` | brk 不超 |
| `test_qemu_mem.sh` | `cat /proc/meminfo` | — | grep MemTotal | exit 0 | — | MemTotal ≥ 3.5 GiB |
| `test_qemu_smp.sh` | `nproc` | — | nproc | exit 0 | — | 输出 ≥ 4 |

---

## 通用代码风格

每个 .c 测试 main 的标准结构（在骨架基础上填）：

```c
int main(void) {
    /* 1. setup */
    int fd = open("/tmp/foo", O_CREAT|O_RDWR, 0600);
    if (fd < 0) fail("open setup: %s", strerror(errno));

    /* 2. action */
    int r = some_syscall(fd, ...);

    /* 3. assert return value */
    if (r != EXPECTED_RETURN)
        fail("syscall returned %d, expected %d", r, EXPECTED_RETURN);

    /* 4. assert errno (only for r == -1) */
    if (r == -1 && errno != EXPECTED_ERRNO)
        fail("errno = %d (%s), expected %d (%s)",
             errno, strerror(errno), EXPECTED_ERRNO, strerror(EXPECTED_ERRNO));

    /* 5. assert side effects */
    /* ... */

    /* 6. cleanup */
    close(fd);
    unlink("/tmp/foo");

    pass();
    return 0;
}
```

**fail() 在任何 assert 失败时立即调用并 exit(1)**，不要继续往下走。

## 跨任务通用工具（建议放 `tests/selfhost/common.h`，由第一个动到 helper 的 task 创建）

```c
/* common.h */
#ifndef SELFHOST_COMMON_H
#define SELFHOST_COMMON_H
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>

#define ASSERT_EQ(actual, expected) do { \
    long _a = (long)(actual), _e = (long)(expected); \
    if (_a != _e) fail("ASSERT_EQ failed: actual=%ld expected=%ld at %s:%d", \
                       _a, _e, __FILE__, __LINE__); \
} while (0)

#define ASSERT_ERRNO(e) do { \
    if (errno != (e)) fail("ASSERT_ERRNO failed: errno=%d (%s) expected=%d (%s)", \
                           errno, strerror(errno), (e), strerror(e)); \
} while (0)

#define ASSERT_TRUE(cond) do { \
    if (!(cond)) fail("ASSERT_TRUE failed: " #cond " at %s:%d", __FILE__, __LINE__); \
} while (0)

#endif
```

如果加 common.h，骨架里的 `pass()` / `fail()` 也可以提到 common.h。但也可以每个 .c 自带，不强制。

## SKIP 约定

某些 syscall（如 ext4 mount 需要 /dev/vdb、9p 需要 host fsdev）在 CI 早期不一定能满足。对这些用例：

- 在 setup 阶段检测前置条件
- 不满足时打印 `[TEST] <name> PASS (SKIP: <reason>)`，**仍然 exit(0)**
- CI 用正则区分 PASS / PASS-SKIP / FAIL

## 怎么用这份矩阵

每个 T1-T5 任务包都会引用本文件的对应章节作为"测试细化合同"。subagent 只填骨架的 TODO，不重写文件结构。
