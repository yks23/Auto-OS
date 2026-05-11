---
name: starry-userspace-log
description: Explains StarryOS user-space logging via /dev/log Unix socket versus stub syslog syscall. Use when debugging missing logs, syslog, musl/apk logger, or Starry guest userland diagnostics.
disable-model-invocation: true
---

用户态看log需要看/dev/log，方便查看丢在哪里

## StarryOS 要点

- **`syslog(2)`**：内核里 **`sys_syslog`** 多为 **空实现**（直接成功），用户态经 libc 调 **syscall** 的日志 **不会** 按 Linux 习惯进 ring buffer。
- **`/dev/log`**：内核伪文件系统里提供 **Unix 域数据报 socket**（`tgoskits/os/StarryOS/kernel/src/pseudofs/dev/log.rs`）。用户进程把 syslog 报文发到 **`/dev/log`**，内核里 **`dev-log-server`** 任务 **`recv` 后用 `info!` 打印**，串口/控制台可见性取决于 **`AX_LOG`** 等日志级别。
- **排查「丢在哪」**：若应用走 **socket → `/dev/log`**，看串口/内核 **`info!`**；若只调 **`syslog` syscall** 或写 **`/dev/kmsg`** 等未实现路径，则 **可能全无输出**。

## 建议操作

1. 访客 onecrate 编最小 crate 且 cargo 输出在 **`/tmp/guest-onecrate-cargo.log`** 时：`guest-onecrate-syscall-evidence.sh` 默认 **`GUEST_ONECRATE_DEVLOG_SEC=15`**（可改如 `=10` 或 `=0` 关闭），会周期性 **`logger -t onecrate-cargo`** → **`/dev/log`**，串口可见内核 **`info!`** 行，便于对照技能第一句。
2. 确认 rootfs 里进程是否连接 **`/dev/log`**（strace 里 `connect`/`sendto` 路径）。
3. 临时用 **`logger`** 或自写小客户端 **`sendto`** 到 **`/dev/log`**，验证串口是否出现对应行。
4. 需要内核侧更多细节时，再开 **`debug!`** / 提高 **`AX_LOG`**（与具体构建配置一致）。

## 不要假设

- 不要把 **Linux `syslog(2)` + journald** 行为套到 Starry；**以 `/dev/log` 与内核 `log` crate 为准**。
