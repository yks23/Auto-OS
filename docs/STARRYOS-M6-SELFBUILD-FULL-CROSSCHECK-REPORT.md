# StarryOS M6 自机完整编译 — 详细信号、资源与七维瓶颈交叉校对报告

**文档性质：** 供与宿主机日志、串口 `results.txt`、以及内核/驱动源码 **交叉校对** 的单一事实来源（Single Source of Truth）。  
**日期：** 2026-05-08  
**对象：** 访客内完整 M6 流程（`starry-kernel` lib → `starryos` pass1 → pass2），以当前仓库 `tests/selfhost/build-selfbuild-rootfs.sh` 注入的 `/opt/build-starry-kernel.sh` 为准。

---

## A. 变更摘要（为「能编多少是多少 + 信号可见」）


| 项                                   | 说明                                                                                                                                                                                                                |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Rust 调试信息**                       | 访客内默认 `M6_RUSTFLAGS_COMMON=-C debuginfo=2`（等价于 gcc `**-g`** 级 DWARF），作用于 `starry-kernel` 与两遍 `starryos` 的 `rustc`；pass2 与 **linker script** 的 `RUSTFLAGS` 合并，避免覆盖。                                                |
| **cargo 冗长**                        | 默认 `M6_CARGO_VV=1` → `cargo -vv`；可 `M6_CARGO_VV=0` 改 `-v` 减日志。                                                                                                                                                    |
| **终端进度**                            | `CARGO_TERM_PROGRESS=wide`、`CARGO_TERM_VERBOSE=true`。                                                                                                                                                             |
| **PTY 解缓冲**                         | 默认 `**M6_CARGO_PTY=0`**：`script` PTY 包装在 Starry 访客 + musl cargo 下曾触发内核 panic；可选 `M6_CARGO_PTY=1` 减轻 cargo 对 pipe 的全缓冲（宿主可能更易看到 `results.txt` 增长）。                                                                 |
| `**starry-kernel` 的 `smp` feature** | 若盘内 **旧 tarball** 的 `kernel/Cargo.toml` **无** `smp = …` 行，则 **自动省略** `--features smp`，避免 `error: … does not contain this feature: smp`；**新镜像**应重新 `build-selfbuild-rootfs.sh` 以与宿主 `scripts/build.sh` 的 SMP 内核一致。 |
| **并行资源透传**                          | `scripts/demo-m6-selfbuild.sh` 注入的 `/opt/run-tests.sh` 现转发 `**CARGO_BUILD_JOBS` / `RAYON_NUM_THREADS`**；此前仅依赖访客 `getconf`，在 QEMU 下常得到 **2**，与宿主期望的 **4/8** 不一致（**资源未到位**）。                                        |


---

## A.1 续跑与宿主进度（Resume & progress）

**续跑（`M6_RESUME=1`，默认 `0`）**  
对**同一**可写 `ROOTFS` 镜像多次执行 `scripts/demo-m6-selfbuild.sh`（或 `bench-m6-guest-starryos-time.sh`）。访客 `/opt/build-starry-kernel.sh`（`build-selfbuild-rootfs.sh` 内 `GUESTSH`）会：

- 若已有 `target/.../starryos` ELF → 立即打印 `===M6-SELFBUILD-PASS===` 并退出；
- 若已有 `linker_<plat>.lds` → 跳过 starry-kernel lib 与 pass1，仅跑 pass2；
- 若已有 `libstarry_kernel*.rlib`（且未进入「仅 pass2」路径）→ 跳过 lib 阶段，从 pass1 继续；
- 每阶段成功后在盘上 `touch`：`/opt/tgoskits/.m6-done-kernel-lib`、`.m6-done-pass1`、`.m6-done-pass2`；续跑时 **marker 须与真实产物一致**（例如仅有 marker 无 rlib 会重新编 lib）。

示例：

```bash
export ROOTFS=/work/.guest-runs/riscv64-m6/rootfs-run.img
export M6_RESUME=1
export M6_QEMU_TIMEOUT_SEC=14400
bash scripts/demo-m6-selfbuild.sh
```

**宿主进度**  

- `demo-m6-selfbuild.sh` 心跳会向 stderr 打印 `last_phase_line`（对 `results.txt` 做 `strings` 后按 `[M6` 、`SELFBUILD`、`Compiling`、`Finished`、`error:`、`panic` 等过滤的最后一行）。
- 另开终端：`bash scripts/m6-selfbuild-watch.sh`（默认每 15s 打一批匹配行；可调 `M6_WATCH_INTERVAL_SEC`、`RESULT`）。也可直接 `tail -f .guest-runs/riscv64-m6/results.txt`（见脚本内注释）。
- **浏览器侧车（本机 HTTP）**：在仓库根目录另开终端运行 `python3 scripts/m6-selfbuild-progress-http.py`（或 `./scripts/m6-selfbuild-progress-http.py`），**看终端 stderr 打印的实际 URL**（默认先试 `8765`；若被占用会自动递增端口，最多 64 次）。浏览器打开该 URL（一般为 `http://127.0.0.1:8765/`，冲突时常见为 `8766`）。页面每约 3s 拉取 `GET /api/log`（`text/plain`，尾块约 256KiB / 至多 400 行，UTF-8 非法字节替换）与 **`GET /api/status`**（`application/json`：日志字节数、mtime、尾 512KiB 行数、`Compiling ` 命中数、阶段/错误 marker 末几行、**按日志文件字节数**在服务端内存中推算的 `staleness_sec` 等）；前端展示约最后 200 行日志并带小型状态条；`GET /health` 返回 `ok`。**HTTP 服务进程**仅依赖 Python 3 标准库；首页另从 CDN 加载 **Chart.js** 绘制 **「Syscall 增量（相邻两次 DUMP 之差）」** 横向条形图（与日志同周期 3s 刷新）。`GET /api/syscall_delta` 返回 JSON：`snapshots`（解析到的快照个数）、`labels`/`values`（相邻两次 `===SYSCALL_STATS_*===` 块之间、按 syscall 号 `nr` 的 **正**增量，取 delta 最大的前 40 项）、`note`（说明或「等待访客内至少两次 dump…」）。解析扫描 `M6_PROGRESS_LOG` 指向的同一 `results.txt` 的**尾部至多约 64MiB**（极长日志时更早的快照可能不在扫描窗内，`note` 会提示）。环境变量：`M6_PROGRESS_BIND`（默认 `127.0.0.1`）、`M6_PROGRESS_PORT`（默认 `8765`）、`M6_PROGRESS_LOG`（默认 `.guest-runs/riscv64-m6/results.txt`，相对当前工作目录）。`/api/status` 会读取宿主环境变量 **`M6_CARGO_PTY`**（未设或 `0` 时在 JSON `note` 中提示：cargo 可能对管道全缓冲，**日志字节不涨 ≠ 访客卡死**）。若浏览器出现 `{"detail":"Not Found"}` 且 `Server: uvicorn`，说明 **8765 上不是你的本脚本**（被其他服务占用），请以 stderr 为准或显式 `M6_PROGRESS_PORT=19999`。
- **真实编译时看 syscall 面板**：先跑真实 M6（如 `bash scripts/bench-m6-guest-starryos-time.sh` 或 `bash scripts/demo-m6-selfbuild.sh`）；访客 `/opt/build-starry-kernel.sh`（由 `tests/selfhost/build-selfbuild-rootfs.sh` 注入）会在阶段间向串口输出若干段 `===SYSCALL_STATS_BEGIN===` … `===SYSCALL_STATS_END===`（内核无 `/proc/syscall_stats` 时静默跳过）。宿主侧用上述 HTTP 页阅读增量图即可。多次对比跑次之间可在访客内 **`echo x > /proc/syscall_stats_reset`**（任意字节写入）清零计数器，避免与上一轮累计混淆。

**可观测性边界：串口/宿主统计与「syscall 级」证据（诚实说明）**

- **不宣称**在未配合内核/驱动的前提下具备完整访客 **syscall 轨迹**或逐调用延迟分解；当前 M6 交叉校对主要依赖：**串口合并日志**（`results.txt`）、**文件增长节奏**、以及日志里 **`Compiling …` 行密度** 等 **rustc/cargo 级**代理指标。
- **宿主侧（可选、轻量）**：例如对 QEMU 进程 `sample` CPU、`vm_stat` / 系统负载，用于判断 TCG/内存压力是否与「日志停滞」同时出现；仍无法单独证明访客用户态卡在某一 syscall。
- **访客侧（重 / 需自备）**：若用户在 rootfs 中安装工具，可对 `cargo` 跑 **`strace -c`** 做汇总统计（开销大、日志洪水，一般仅排障短跑）；更细粒度或低开销的 syscall 时间线需要 **未来内核 tracepoints / 调度器钩子** 等支持，本文档不假装已具备。
- **内核侧（轻量）**：访客内 `cat /proc/syscall_stats`（或串口抓取）可得按原始 syscall 号汇总的计数，M6 编 `cargo` 时常见 `read`/`write`/`mmap` 等增长；任意写入 `/proc/syscall_stats_reset` 可清零。自机脚本已把阶段性 dump 打进 `results.txt`，与 **`m6-selfbuild-progress-http.py`** 的 syscall 面板联动。

---

## B. 推荐运行命令（完整自机 + 资源给足 + 长超时）

在 **Docker root + 特权** 下（与 `verify-m6-rootfs` / loop 挂载一致）：

```bash
docker run --rm --privileged --network host \
  -v "/path/to/Auto-OS:/work" -w /work \
  auto-os/starry:latest \
  bash -lc '
export PATH="/opt/riscv64-linux-musl-cross/bin:$PATH"
export ROOTFS=/work/.guest-runs/riscv64-m6/rootfs-run.img   # 或 tests/selfhost/...img
# 时间：完整编 starry-kernel 在 TCG 上常需数小时量级
export M6_QEMU_TIMEOUT_SEC=14400
export M6_QEMU_SMP=4
export M6_QEMU_MEM=8G
export M6_STALL_SEC=0
export M6_GUEST_HEARTBEAT_SEC=60
export M6_HOST_HEARTBEAT_SEC=120
# 并行与 rustc 栈
export CARGO_BUILD_JOBS=4
export RAYON_NUM_THREADS=4
# 可选：减轻日志
# export M6_CARGO_VV=0
# export M6_RUSTFLAGS_COMMON="-C debuginfo=1"
bash scripts/demo-m6-selfbuild.sh
'
```

**产物与日志：**

- 串口合并日志：`.guest-runs/riscv64-m6/results.txt`（可能含 ANSI，建议 `strings results.txt | less`）。
- 访客内 tee：`/tmp/m6-cargo-kernel.log`、`/tmp/m6-cargo-pass1.log`、`/tmp/m6-cargo-pass2.log`（需事后挂载镜像提取，或扩展 init 把其 `cat` 到串口）。

---

## C. 本仓库实测事件（用于交叉校对）

### C.1 `starry-kernel` 缺少 `smp` feature（已修复为自动探测）

- **现象：** `error: the package 'starry-kernel' does not contain this feature: smp`  
- **根因：** 根盘内 `/opt/tgoskits` 为 **旧快照**，与当前宿主 `tgoskits/os/StarryOS/kernel/Cargo.toml` 不一致。  
- **处置：** 访客脚本按 `Cargo.toml` 是否含 `smp =` 决定是否追加 `--features smp`；**根治**为重新执行 `tests/selfhost/build-selfbuild-rootfs.sh` 刷新 `/opt/tgoskits`。

### C.2 串口字节数长时间不变（cargo 缓冲；可选 PTY）

- **现象：** `host_qemu_wall_seconds≈900` 期间 `wc -c results.txt` 几乎不变。  
- **初判：** `cargo` 对 **非 TTY stdout** 全缓冲；`-vv` 亦可能长时间无 flush。  
- **处置：** 可选 `M6_CARGO_PTY=1` 用 `script` PTY 包装（`script` 内已用 `**/usr/bin/env`**，避免 `env: not found`）。**默认关闭 PTY**：部分 Starry 组合下 PTY 曾触发访客 panic。  
- **复测：** 开 PTY 时心跳间隔内 `results.txt` 字节数可能更易增长；关 PTY 时依赖 `strings results.txt` / `m6-selfbuild-watch.sh` 看阶段行。

### C.3 宿主 `CARGO_BUILD_JOBS=4` 未进访客（已修复）

- **现象：** 串口打印 `parallelism: CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2`，与宿主 export 不一致。  
- **根因：** `/opt/run-tests.sh` 未转发 `CARGO_BUILD_JOBS` / `RAYON_NUM_THREADS`。  
- **处置：** `demo-m6-selfbuild.sh` 已增加 `export CARGO_BUILD_JOBS=...`、`export RAYON_NUM_THREADS=...`（空则访客脚本仍用 `getconf` 回退）。

---

## D. 七维瓶颈与证据表（FS / IO Buffer / Block / DRV / MEM / Schedule / 并行）

以下为 **代码路径 + 本场景行为** 的交叉索引；**未**在访客内跑 `perf`/`ftrace`（当前工具链与镜像未纳入），静态为主、动态为辅。

### 1. FS（文件系统）


| 观察                                                                  | 解释与定位                                                                                                                                                 |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| 串口 `Unsupported ioctl command: 21505 for fd: …`                     | 用户态（cargo/终端库）对某 fd 发起 **ioctl**，内核路径 `starry_kernel::syscall::fs::ctl` 返回不支持；属 **VFS/ioctl 覆盖面** 与 **用户态期望** 不匹配，一般 **不直接阻塞编译**，但会污染日志、偶发拖慢 libc 分支。 |
| `SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp`、`CARGO_HOME` 在 virtio ext4 子树 | 刻意避免 **极小 tmpfs** 与 **lwext4 + sqlite** 已知组合问题（见 `build-selfbuild-rootfs.sh` 注释）。                                                                     |
| EXT4 + journal                                                      | 大量 `rustc` 临时文件与 `**.rmeta`/incremental** 随机写 → **元数据 + journal** 放大延迟；与块层同步模型叠加（见 D.3）。                                                              |


### 2. I/O Buffer（stdio / 管道缓冲）


| 观察                    | 解释与定位                                                                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `results.txt` 长时间体积不变 | **cargo 对 pipe 全缓冲** + `tee`；可选 **script PTY**（见 A、C.2）；默认关 PTY 时用 `**strings` + 过滤** / `scripts/m6-selfbuild-watch.sh` 看进度。           |
| `mon:stdio` + 大块输出    | `demo-m6-selfbuild.sh` 仍用 `**-serial mon:stdio`**；高噪声时宿主终端与文件重定向仍可能 **交错**；基准脚本已示例 `-serial file:`（见 `scripts/bench-m6-guest-smp.sh`）。 |


### 3. Block（块 I/O 路径形状）


| 观察                                                            | 解释与定位                                                                                                                         |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| virtio-blk 上 **22GiB raw** 镜像                                 | 冷缓存首次读 **慢**；`file.locking=off` 为 macOS/并发场景必备（其它脚本已用）。                                                                       |
| 平台 `Block::read_block` 持 `**Mutex` + `read_blocks_blocking`** | 多 `rustc` 并发读盘时，**锁串行化** 与 **同步完成** 叠乘，易成 **I/O 上限**（参见 `tgoskits/platform/axplat-dyn/src/drivers/blk/mod.rs` 及 virtio 队列实现）。 |


### 4. DRV（设备驱动）


| 观察                                                 | 解释与定位                                                                                             |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| virtio-blk **IRQ 路径为桩**（`enable_irq`/`handle_irq`） | 偏 **轮询/同步完成** 语义；高 IOPS 时 CPU **忙等**风险（`tgoskits/platform/axplat-dyn/src/drivers/blk/virtio.rs`）。 |
| 串口 `uart8250`                                      | 编译日志吞吐受 **串口速率/实现** 限制；巨量 `-vv` 会 **占用 CPU 打日志**。                                                 |


### 5. MEM（内存）


| 观察                                                 | 解释与定位                                                                           |
| -------------------------------------------------- | ------------------------------------------------------------------------------- |
| `M6_QEMU_MEM` 与 axplat **phys-memory-size**        | 须与 `scripts/build.sh` / 镜像烘焙的 **4GiB 模型** 及 QEMU `-m` 一致（过小易引导/映射异常）。           |
| `RUST_MIN_STACK` 提升                                | 缓解 musl `rustc` 在 Starry 下的 **栈保护误报**（见 GUESTSH 注释）。                            |
| `RUSTFLAGS=-C debuginfo=2`                         | **显著增大** `target/` 体量与 **链接内存峰值**；若 OOM，先降为 `debuginfo=1` 或仅 pass1 开 debuginfo。 |
| `exit robust list failed: AxErrorKind::BadAddress` | **进程退出路径**（robust futex list）与用户态地址清理相关；与 **磁盘吞吐** 分开跟踪，避免误判为 Block 瓶颈。         |


### 6. Schedule（调度）


| 观察                            | 解释与定位                                                                |
| ----------------------------- | -------------------------------------------------------------------- |
| `sys_sched_setscheduler` 等桩实现 | Linux **CFS 语义不完整**；CPU 敏感阶段主要仍看 **rustc/llvm 自身线程** 与 **内核 I/O 锁**。 |
| `sched_setaffinity`           | 已接 `ax_task::set_current_affinity`；对 **单盘 virtio 锁** 的负载帮助有限。        |


### 7. 并行处理


| 观察                                       | 解释与定位                                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------------ |
| `CARGO_BUILD_JOBS` / `RAYON_NUM_THREADS` | 必须与 **QEMU `-smp`**、访客 **可见 CPU 数** 一致；已修复 **宿主 → 访客转发**（见 C.3）。               |
| 依赖图                                      | `cargo` 并行度受 **crate 图关键路径** 限制；`-vv` 会列出具体 `rustc` 子进程，便于确认 **是否并行启动多个 job**。 |


---

## E. 串口 / 日志交叉校对清单（建议 grep 模式）

在宿主对 `results.txt` 执行：

```bash
strings .guest-runs/riscv64-m6/results.txt | grep -E 'M6-|starry-kernel|starryos pass|SELFBUILD|error:|panic:|Compiling|Running|Finished|heartbeat|Unsupported ioctl|robust list'
```

- **成功：** `===M6-SELFBUILD-PASS===` 或退而求其次 `===M6-SELFBUILD-LIB-PASS===`。  
- **失败：** `error: could not compile`、`panic`、`stack smashing`。  
- **「卡住」：** 仅有 `heartbeat` 无 `Compiling` → 优先查 **依赖解析/锁文件**；若开了 `M6_CARGO_PTY=1` 再确认 PTY 路径无异常。有 `Compiling` 但极慢 → 查 **TCG、块锁、debuginfo 体量**。

---

## F. 结论（供决策）

1. **首要动态瓶颈（本场景）：** QEMU **TCG CPU** + **virtio-blk 同步路径 + 全局块锁** + **EXT4 元数据**；其次为 `**debuginfo=2` 的磁盘与内存开销**。
2. **首要「假卡住」：** **stdio 缓冲** 与 **旧 rootfs 缺 smp feature**；已通过 **可选 PTY、`/usr/bin/env`、feature 探测、环境变量转发、宿主 `strings`/watch** 修正或规避。
3. **根治数据面：** 重新烘焙 **rootfs** 使 `/opt/tgoskits` 与当前子模块一致，并固定 `**M6_QEMU_TIMEOUT_SEC`≥数小时** 做完整交叉编译一次，将 `**strings results.txt`** 全文归档作为基线。

---

## G. 脚本与行号索引（便于 diff）

- 访客 GUESTSH：`tests/selfhost/build-selfbuild-rootfs.sh`（`<<'GUESTSH'` … `GUESTSH` 块内：`_run_cargo`、`m6_ts`、三阶段 `cargo build`）。  
- 宿主注入：`scripts/demo-m6-selfbuild.sh`（`/opt/run-tests.sh` heredoc）；宿主进度轮询：`scripts/m6-selfbuild-watch.sh`。  
- 块路径参考：亦见 `docs/STARRYOS-PERF-ENV-REPORT.md`。

---

*本报告与仓库脚本同源；若你本地 `results.txt` 与本文 C 节现象不一致，请以 **你的串口文件 + 提交 SHA** 为准做 diff。*
---

## H. 测速结果（访客真实编译 / 后台跑满或超时）

| 字段 | 值 |
|------|-----|
| **启动时间 (UTC)** | 2026-05-08T10:12:14Z 起（`bench-selfbuild-20260508T101214Z.*`） |
| **配置** | `M6_CARGO_PTY=0`，`M6_QEMU_MEM=8G`，`M6_QEMU_SMP=4`，`M6_QEMU_TIMEOUT_SEC=28800`，`CARGO_BUILD_JOBS=4`，`ROOTFS=.guest-runs/riscv64-m6/rootfs-run.img` |
| **本 subagent 回报时状态** | **进行中**：容器内 `qemu-system-riscv64` 约 **100% CPU**（`docker exec … ps`），说明访客内 **rustc/cargo 在跑**；宿主 `results.txt` 字节数可长时间不变（**cargo 对 pipe 全缓冲**，非死锁判据）。 |
| **PASS 判定** | 串口出现 `===M6-SELFBUILD-PASS===` 后，读 `bench-selfbuild-20260508T101214Z.summary.txt` 中 `host_wall_total_seconds`。 |
| **工件路径** | 宿主：`scripts/bench-m6-guest-starryos-time.sh`；日志：`.guest-runs/riscv64-m6/bench-outer.log`、同目录 `bench-selfbuild-20260508T101214Z.log`；快照：`.guest-runs/riscv64-m6/BENCH-LAST.txt`。 |

**完成后请本地执行：** `strings .guest-runs/riscv64-m6/results.txt | grep -E 'SELFBUILD-PASS|SELFBUILD-LIB|error:|panic'`；若 PASS，再 `sudo mount -o loop rootfs-run.img /mnt && ls -lh /mnt/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos`。

