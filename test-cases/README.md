# Test Cases

所有测试用例按类别组织在此目录下。

## 目录结构

```
test-cases/
├── custom/          # L1: 手写 C 单元测试（31 个，debugger agent 产出）
├── oscomp-basic/    # L1/L2: 基础系统调用测试生成器（32 个，自动生成）
├── linux-compat/    # L1: Linux 兼容性测试（submodule: rcore-os/linux-compatible-testsuit）
├── integration/     # L3: 集成测试（BusyBox/Shell/网络 shell 脚本）
├── ltp-subset/      # L2: LTP 精选列表（~120 个用例名称）
└── oscomp/          # L4: OS 竞赛官方测试
    ├── testsuits/   #   submodule: oscomp/testsuits-for-oskernel
    └── autotest/    #   submodule: oscomp/autotest-for-oskernel
```

## 四层测试体系

| 层级 | 目录 | 说明 |
|------|------|------|
| L1 | `custom/`, `oscomp-basic/`, `linux-compat/` | 单元测试，聚焦 syscall 正确性 |
| L2 | `ltp-subset/` | LTP 精选子集，验证 Linux 兼容性 |
| L3 | `integration/` | 真实应用测试（BusyBox、Shell、网络） |
| L4 | `oscomp/` | OS 竞赛官方评测框架 |

## 快速使用

```bash
# 编译 L1 自编测试
./testing/scripts/build-tests.sh riscv64

# 运行全量测试
./testing/scripts/test-runner.py --all --arch riscv64

# 一键构建所有套件
./auto-evolve/test-suites/build-all.sh riscv64
```
