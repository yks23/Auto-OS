# Auto-OS 测试体系

## 总览

```
testing/
├── TESTING.md              # 本文件
│
├── scripts/                # 测试运行脚本
│   ├── test-runner.py      # 统一测试入口（编译 + QEMU + 解析）
│   ├── build-tests.sh      # 批量交叉编译 C 测试
│   ├── inject-rootfs.sh    # 将测试程序注入 rootfs
│   └── parse-results.py    # 解析测试输出，生成报告
│
└── results/                # 测试结果输出
    ├── latest.json         # 最近一次测试结果
    └── history/            # 历史结果

test-cases/                 # 所有测试用例（按类别组织）
├── custom/                 # L1: 自编 syscall 单元测试（C, musl 静态编译, 31 个）
├── oscomp-basic/           # L1/L2: 基础系统调用测试生成器
├── linux-compat/           # L1: Linux 兼容性测试（submodule: rcore-os/linux-compatible-testsuit）
├── integration/            # L3: 真实应用集成测试（BusyBox/Shell/网络）
├── ltp-subset/             # L2: LTP 精选列表
└── oscomp/                 # L4: OS 竞赛官方测试
    ├── testsuits/          #   submodule: oscomp/testsuits-for-oskernel
    └── autotest/           #   submodule: oscomp/autotest-for-oskernel
```

---

## 四层测试体系

### L1: Syscall 单元测试（自编）

**来源**：test-cases/custom/ 中 debugger agent 自动生成的 C 测试程序。

**特点**：
- 每个文件测试一个 syscall 或一组相关 syscall
- musl-libc 静态编译，无外部依赖
- 输出 `[TEST] name ... PASS/FAIL` 格式，便于自动解析
- 聚焦 Starry 特有的问题（stub/dummy/语义偏差）

**运行方式**：
```bash
# 编译全部
./testing/scripts/build-tests.sh riscv64

# 注入 rootfs 并在 QEMU 中运行
./testing/scripts/test-runner.py --level l1 --arch riscv64
```

**当前覆盖**：31 个测试文件，覆盖 membarrier、timerfd、flock、fcntl 锁、SIGSTOP、fork CoW、execve 多线程、accept 地址、futex 压力等。

---

### L2: LTP 精选子集

**来源**：Linux Test Project (https://github.com/linux-test-project/ltp)

LTP 有 4000+ 测试用例，全跑不现实。我们精选与 Starry 已实现 syscall 直接相关的子集。

**选取原则**：
1. Starry 已实现的 syscall → 对应的 LTP 用例必须通过
2. 竞赛评测中出现的 LTP 用例（见 oscomp-autotest/kernel/judge/judge_ltp-musl.py）
3. 高频 syscall 优先（read/write/mmap/fork/exec/wait/signal）

**精选列表**（`test-cases/ltp-subset/ltp-syscalls.list`）：

```
# 文件 I/O
read01 read02 write01 write02 writev01 readv01
open01 openat01 close01 dup01 dup201
lseek01 pread01 pwrite01
fstat01 stat01 fstatat01

# 进程管理
fork01 fork02 vfork01
clone01 clone02
execve01 execve02
exit01 exit_group01
wait01 wait02 waitpid01

# 信号
kill01 kill02
rt_sigaction01 rt_sigprocmask01
rt_sigreturn01 rt_sigsuspend01

# 内存管理
mmap01 mmap02 mmap03
munmap01 mprotect01 brk01
madvise01 msync01

# 同步
futex_wait01 futex_wake01
flock01 flock02
fcntl01 fcntl02

# 网络
socket01 bind01 connect01
accept01 listen01
send01 recv01 sendto01 recvfrom01

# IPC
pipe01 pipe02
msgget01 msgsnd01 msgrcv01
shmget01 shmat01 shmdt01

# 时间
clock_gettime01 nanosleep01
timerfd_create01 timerfd_settime01

# 调度
sched_yield01
sched_getaffinity01 sched_setaffinity01

# 系统信息
uname01 sysinfo01 getpid01
getuid01 setuid01
```

**获取 LTP 预编译二进制**：
```bash
# 从 oscomp 的 Alpine rootfs 中提取（已含 LTP musl 编译版）
# 或交叉编译：
cd ltp && make autotools && ./configure --host=riscv64-linux-musl \
  CC=riscv64-linux-musl-gcc --prefix=/opt/ltp-riscv64
make -j$(nproc) && make install
```

---

### L3: 集成测试（真实应用）

验证真实 Linux 程序能否在 Starry 上运行。

**BusyBox 核心命令**（`test-cases/integration/test-busybox.sh`）：
```bash
# 文件操作
ls / && ls -la /tmp && mkdir -p /tmp/test_dir && rm -rf /tmp/test_dir
echo "hello" > /tmp/test_file && cat /tmp/test_file && rm /tmp/test_file
cp /bin/busybox /tmp/bb_copy && diff /bin/busybox /tmp/bb_copy

# 进程操作
ps aux
id
uname -a
uptime
free

# 文本处理
echo "hello world" | grep "hello"
echo -e "b\na\nc" | sort
seq 1 10 | wc -l

# 网络（如果可用）
ping -c 1 127.0.0.1
wget -q -O /dev/null http://127.0.0.1/ 2>/dev/null || true
```

**Shell 脚本功能**（`test-cases/integration/test-shell.sh`）：
```bash
# 变量和算术
A=42 && [ "$A" = "42" ] && echo "PASS: variable"
B=$((A + 8)) && [ "$B" = "50" ] && echo "PASS: arithmetic"

# 条件和循环
for i in 1 2 3; do echo $i; done | wc -l | grep -q 3 && echo "PASS: for loop"

# 管道和重定向
echo "test" | cat | cat > /tmp/pipe_test && cat /tmp/pipe_test | grep -q "test" && echo "PASS: pipe"

# 子进程
(exit 42); [ $? -eq 42 ] && echo "PASS: subshell exit"

# 信号
sh -c 'kill -0 $$' && echo "PASS: kill -0 self"

# Job control（需要 SIGSTOP/SIGCONT 工作）
sleep 100 &
BGPID=$!
kill -STOP $BGPID && kill -CONT $BGPID && kill $BGPID && echo "PASS: job control"
```

---

### L4: OS 竞赛测试（oscomp）

直接使用官方评测框架，验证竞赛水平。

**包含的评测项**（来自 `oscomp-autotest/kernel/judge/`）：
- `judge_basic-musl.py`：基础系统调用
- `judge_busybox-musl.py`：BusyBox 命令
- `judge_ltp-musl.py`：LTP 子集
- `judge_libctest-musl.py`：libc 测试
- `judge_libcbench-musl.py`：libc 性能基准
- `judge_lmbench-musl.py`：系统调用延迟基准
- `judge_iozone-musl.py`：文件 I/O 性能
- `judge_cyclictest-musl.py`：实时调度延迟
- `judge_lua-musl.py`：Lua 解释器
- `judge_iperf-musl.py` / `judge_netperf-musl.py`：网络性能

**运行方式**：
```bash
# 使用 oscomp 提供的 Docker 环境
docker pull zhouzhouyi/os-contest:20260104
docker run -it --rm -v $(pwd):/workspace -w /workspace zhouzhouyi/os-contest:20260104

# 在容器中运行评测
cd test-cases/oscomp/autotest
python3 -m kernel --arch riscv64 --kernel /workspace/starry-os
```

---

## 测试运行入口

### 统一命令

```bash
# 运行全部四层测试
./testing/scripts/test-runner.py --all --arch riscv64

# 只运行某一层
./testing/scripts/test-runner.py --level l1 --arch riscv64    # 自编单元测试
./testing/scripts/test-runner.py --level l2 --arch riscv64    # LTP 子集
./testing/scripts/test-runner.py --level l3 --arch riscv64    # 集成测试
./testing/scripts/test-runner.py --level l4 --arch riscv64    # oscomp 评测

# 只运行某个测试文件
./testing/scripts/test-runner.py --test test_timerfd --arch riscv64

# 生成报告
./testing/scripts/test-runner.py --report --arch riscv64
```

### 输出格式

每次测试运行生成 `testing/results/latest.json`：

```json
{
  "timestamp": "2026-04-14T12:00:00Z",
  "arch": "riscv64",
  "kernel_commit": "abc1234",
  "levels": {
    "l1": {"total": 31, "passed": 28, "failed": 3, "skipped": 0},
    "l2": {"total": 60, "passed": 45, "failed": 10, "skipped": 5},
    "l3": {"total": 20, "passed": 18, "failed": 2, "skipped": 0},
    "l4": {"total": 100, "passed": 75, "failed": 20, "skipped": 5}
  },
  "overall_pass_rate": 78.7,
  "failed_tests": [
    {"name": "test_timerfd", "level": "l1", "reason": "poll timeout"},
    ...
  ]
}
```

---

## 与 Auto-Evolve 的集成

测试体系与 AI agent 系统的交互点：

### Debugger 使用测试

1. **发现问题时**：运行对应的 L1/L2 测试确认 bug 存在
2. **回归验证时**：executor 修复后重跑测试确认 PASS
3. **主动改进时**：跑 L3/L4 发现新的不兼容点

### Executor 使用测试

1. **修复前**：运行 issue 指定的测试，确认 FAIL（基线）
2. **修复后**：重跑同一测试，确认 PASS
3. **回归检查**：运行全部 L1 测试，确认不破坏已有修复

### Kernel 调度器使用测试

每次 executor 完成一个 fix 分支后，自动触发该分支的 L1 测试。如果有 regression，自动创建新 issue。

---

## 未来扩展

### 覆盖率统计

Starry 是 `no_std` 内核，不能直接用 `cargo-llvm-cov`。但可以：
1. 在 QEMU 中通过 gcov/kcov 收集内核代码覆盖率
2. 统计哪些 syscall 路径被测试覆盖了
3. 引导 debugger 优先审计未覆盖的路径

### Rust 形式验证（Kani / Miri）

- **Kani**：适用于验证关键 unsafe 代码的正确性（如页表操作、CoW 逻辑）
- **Miri**：适用于检测 UB（如 `AssumeSync<T>` 的正确性）
- 局限：两者都不支持 `no_std` 内核的完整环境，只能用于隔离出的纯逻辑模块

### 性能基准

- `lmbench`：系统调用延迟（fork/exec/mmap/pipe 等）
- `iozone`：文件 I/O 吞吐
- `iperf`：网络吞吐
- 基准数据可用于量化优化效果（如 AddrSpace 锁改 RwLock 前后对比）
