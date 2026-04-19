# F-β：Starry `/dev/console` RX（host 串口 → BusyBox stdin）

## 现象

- TX：内核 `write_bytes` → QEMU virt 16550 → host 正常。
- RX：host 经 TCP:4444 写入的字节进不了 `read(0,…)`（BusyBox 等 stdin 阻塞）。

## 调用链（修复前）

1. 用户 `read(0, buf)` → Starry `Tty::read_at` → `LineDiscipline::read`（`pseudofs/dev/tty/mod.rs`）。
2. `ntty` 把真实 UART 接到 `TtyConfig { reader: Console, … }`（`ntty.rs`）。
3. `ax_hal::console::irq_num()` 在 **riscv64 qemu-virt** 上返回 `Some(UART_IRQ)` → `ProcessMode::External`。
4. `LineDiscipline::new` 起 `tty-reader` 任务：在 `poll_fn` 里先 `reader.poll()`，再 `register_irq_waker(UART_IRQ, waker)`（`ldisc.rs` + `axtask::future::poll.rs`）。
5. `register_irq_waker`：`register_irq_hook`（全局一次）+ `POLL_IRQ[irq].register(waker)` + `ax_hal::irq::set_enable(irq, true)`。
6. PLIC 收到 UART 外设中断 → `axplat-riscv64-qemu-virt` `IrqIfImpl::handle` S_EXT 分支：`claim` → `IRQ_HANDLER_TABLE.handle(uart_irq)` → `complete` → 返回 `Some(uart_irq)` → `axhal::handle_irq` 调 `irq_hook(uart_irq)` → 唤醒 `tty-reader`。

## 断点

- `IRQ_HANDLER_TABLE.handle(UART_IRQ)` **没有**为 UART 注册过 `ax_hal::irq::register` 的 top-half；表项为空则 **不会读 IIR/RBR**，16550 的「接收数据可用」中断线可能一直保持有效。
- 依赖 `irq_hook` 仅唤醒 `tty-reader` 再去 `Console::read`/`try_receive_bytes` 的路径，在实测中与「host 已发字节、guest 永远等 stdin」一致，判定为 **IRQ 驱动 RX 路径不可靠**。

## 修复

- 在 `axplat-riscv64-qemu-virt/src/console.rs` 将 `irq_num()` 改为返回 **`None`**（与 x86 COM1 一致）。
- `ntty` 因而选择 **`ProcessMode::Manual`**：`LineDiscipline::read` 在持锁路径里循环 `reader.poll()` + `yield_now()`，直接轮询 `read_bytes`，不依赖 UART IRQ 唤醒后台任务。

## 验证

- `tests/selfhost/test_stdin_byte.c`：非阻塞 `read(0,…)`，无字节时输出 `PASS (SKIP: …)` 以便 `run-tests-in-guest.sh` 不挂死；host 在提示后发送一字节应打印 `got 1 bytes` 与 `PASS`。
- 真测：交互 shell 下由 host 发字符/行，应可被 `cat` 或 shell 读入。
