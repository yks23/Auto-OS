# LTP 精选子集

从 Linux Test Project (https://github.com/linux-test-project/ltp) 中精选与 Starry OS 已实现 syscall 直接相关的测试用例。

## 选取原则

1. Starry 已实现的 160+ syscall → 对应的 LTP 用例
2. oscomp 竞赛评测中使用的 LTP 用例（来自 autotest-for-oskernel/kernel/judge/judge_ltp-musl.py）
3. 高频 syscall 优先

## 用例列表

见 `ltp-syscalls.list`，共约 120 个用例。

## 获取 LTP 二进制

```bash
# 方法 1：从 oscomp Alpine rootfs 中提取（推荐，已含预编译版本）
# 方法 2：交叉编译
git clone https://github.com/linux-test-project/ltp.git
cd ltp
make autotools
./configure --host=riscv64-linux-musl CC=riscv64-linux-musl-gcc --prefix=/opt/ltp
make -j$(nproc)
make install DESTDIR=/opt/ltp-riscv64
```

## 运行

将 LTP 二进制放入 rootfs 的 `/opt/ltp/` 后，在 QEMU 中：

```bash
cd /opt/ltp/testcases/bin
for test in $(cat /path/to/ltp-syscalls.list | grep -v '^#'); do
    echo "RUN LTP CASE $test"
    ./$test 2>&1
    echo "END LTP CASE $test : $?"
done
```
