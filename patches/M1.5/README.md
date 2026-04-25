# M1.5: init.sh self-host test runner hook

starry kernel 的 console RX 路径不工作（host→guest 串口字节进不去 BusyBox stdin），
所以走"不需要 stdin"方案：让 init.sh 自动 exec /opt/run-tests.sh。

完整使用：scripts/run-tests-in-guest.sh ARCH=...
- mount rootfs，注入 31 个 musl 测试 + run-tests.sh driver 到 /opt/
- 启动 QEMU，starry init.sh 自动跑 /opt/run-tests.sh 收集结果

验收背景与体量总述见 `docs/SELFHOST-IMPLEMENTATION-SUMMARY.md`；历史逐测报告见 git 中的 `docs/M1.5-results.md`。
