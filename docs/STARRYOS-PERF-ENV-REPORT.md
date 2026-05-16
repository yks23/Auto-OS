# StarryOS 编译环境、运行过程与性能瓶颈分析报告

**日期：** 2026-05-08  
**范围：** 以当前仓库 `scripts/build.sh ARCH=riscv64` 产出的 `starryos` 为内核，在 Docker + QEMU 下做一次可复现的「环境 + 轻量负载」记录，并结合代码路径做**静态**瓶颈归类（非采样级 profiling）。

---

## 1. 执行摘要

| 维度 | 结论（高信号） |
|------|----------------|
| **块设备 / virtio-blk** | VirtIO 队列层对单次请求走 **同步 `read_block`/`write_block`**，上层 `Block::read_block` 在 **`Mutex` 保护的队列上 `read_blocks_blocking`**，易形成 **串行 I/O + 锁竞争** 热点。 |
| **I/O 缓冲** | EXT4 路径存在 **块级 cache**（单块缓冲 + dirty 跟踪）；大块顺序 I/O 更依赖底层是否合并、是否多队列。 |
| **文件系统** | 根盘为 **EXT4（rsext4 + lwext4 C 库）** 时，元数据与 journal 会放大随机写延迟；与块层同步模型叠加。 |
| **内存** | 发行配置中 **RISC-V QEMU 平台物理内存上限** 与 `page-alloc-4g` 等特性绑定（默认 **4GiB** 量级），QEMU `-m` 与 DTB/内核模型需一致，否则引导或分配异常。 |
| **调度 / SMP** | 用户态可见 `sched_*` 多为占位或简化实现；**真并行**依赖 `ax_task` 与 SMP 下的 per-CPU 运行队列，但 **块设备全局 `Mutex`** 仍可能把多线程 I/O 串行化。 |
| **并行（用户态）** | 多进程 `dd`/编译能吃到多核的前提是 **内核态块路径与文件锁** 不成为硬瓶颈；此前基准里 **glibc/工具链在访客内崩溃** 属于用户态/ABI 风险，与块层调度混杂时需分开排查。 |

---

## 2. 过程记录（环境）

### 2.1 编译环境（产物）

- **推荐路径：** 在 `auto-os/starry:latest`（本机验证为 **aarch64** 镜像）内编译，宿主编译会因 **riscv musl 交叉编译器架构不匹配** 在 `lwext4_rust` 的 CMake 阶段失败（`riscv64-linux-musl-cc: cannot execute binary file`）。
- **命令：**

```bash
docker run --rm \
  -v "/path/to/Auto-OS:/work" -w /work \
  auto-os/starry:latest \
  bash -lc 'export PATH="/opt/riscv64-linux-musl-cross/bin:$PATH"
bash scripts/build.sh ARCH=riscv64'
```

- **关键编译选项（RISC-V QEMU）：** `scripts/build.sh` 为 `riscv64` 默认启用 **SMP（`starryos/qemu,smp`）**、`plat.max-cpu-num` 与 `plat.phys-memory-size`（默认 **4GiB**），与 M6 自托管 demo 对齐。

```75:91:scripts/build.sh
# riscv64 QEMU：默认多核 SMP + 更大物理内存（与 scripts/demo-m6-selfbuild.sh 一致）。
# 单核回退：MAX_CPU_NUM=1 bash scripts/build.sh ARCH=riscv64
STARRY_QEMU_FEATURES="starryos/qemu"
AXGEN_EXTRA=()
if [[ "$ARCH" == "riscv64" ]]; then
    MAX_CPU_NUM="${MAX_CPU_NUM:-4}"
    if [[ "${MAX_CPU_NUM:-1}" -gt 1 ]]; then
        STARRY_QEMU_FEATURES="starryos/qemu,smp"
        # 须 ≤ ax-feat「page-alloc-4g」位图容量（约 4GiB 可映射页）；更大需改 kernel 为 page-alloc-64g。
        _phys="${STARRY_PHYS_MEMORY_SIZE:-0x100000000}" # 4 GiB
        AXGEN_EXTRA+=(-w "plat.max-cpu-num=${MAX_CPU_NUM}")
        AXGEN_EXTRA+=(-w "plat.phys-memory-size=${_phys}")
```

- **产物路径：**
  - `tgoskits/target/riscv64gc-unknown-none-elf/release/starryos`
  - `tgoskits/os/StarryOS/starryos/starryos_riscv64-qemu-virt.elf`

### 2.2 运行环境（本次实测）

在 **同一 Docker 镜像** 内，使用已编译 ELF、`rust-objcopy` 展平为 raw kernel，挂载已有 **M6 rootfs 镜像**（`.guest-runs/riscv64-m6/rootfs-run.img`，约 22GiB，**未再拷贝**），QEMU 参数与 M6 脚本同类：**`-smp 4 -m 5G`**、**virtio-blk + `file.locking=off`**、virtio-net user。

**测量（宿主墙钟）：**

- `qemu_exit=0`
- **`host_wall_sec=9`**（容器内 `date` 差分；完整子集日志约 **6169 字节** 串口输出后即退出，说明该环境下 **TCG/磁盘缓存命中** 时子集路径极快——**不宜外推到 22GiB 镜像冷缓存或 Apple Silicon 上首次拉盘**。）

串口摘要行（过滤后）：

- `Welcome to Starry OS` / `apk` 提示
- `StarryOS M6` 子集标记 **`===M6-SELFBUILD-SUBSET-PASS===`**
- 多条 `exit robust list failed: AxErrorKind::BadAddress`（**用户态退出清理路径**与 robust futex/list 相关，提示 **内存/指针语义或 glibc 兼容层** 仍有噪声，需与「磁盘吞吐」类瓶颈区分）

---

## 3. 分维度分析（证据与推断）

### 3.1 块设备（virtio-blk）与 I/O 路径形状

**VirtIO 块队列实现：单次 `submit_request` 内直接完成读/写，`poll_request` 恒为成功。**

```130:153:tgoskits/platform/axplat-dyn/src/drivers/blk/virtio.rs
    fn submit_request(
        &mut self,
        request: rd_block::Request<'_>,
    ) -> Result<rd_block::RequestId, rd_block::BlkError> {
        let id = request.block_id;
        match request.kind {
            rd_block::RequestKind::Read(mut buffer) => {
                self.raw
                    .read_block(id as _, &mut buffer)
                    .map_err(map_dev_err_to_blk_err)?;
                Ok(rd_block::RequestId::new(0))
            }
            rd_block::RequestKind::Write(items) => {
                self.raw
                    .write_block(id as _, items)
                    .map_err(map_dev_err_to_blk_err)?;
                Ok(rd_block::RequestId::new(0))
            }
        }
    }

    fn poll_request(&mut self, _request: rd_block::RequestId) -> Result<(), rd_block::BlkError> {
        Ok(())
    }
```

**平台块设备封装：全局 `Mutex<CmdQueue>`，`read_block` 在锁内调用 `read_blocks_blocking`。**

```44:66:tgoskits/platform/axplat-dyn/src/drivers/blk/mod.rs
    fn read_block(&mut self, block_id: u64, buf: &mut [u8]) -> DevResult {
        let blk_count = buf.len() / self.block_size();
        let blocks = self
            .queue
            .lock()
            .read_blocks_blocking(block_id as _, blk_count);
        for (block, chunk) in blocks.into_iter().zip(buf.chunks_mut(self.block_size())) {
            let block = block.map_err(maping_blk_err_to_dev_err)?;
            if block.len() != chunk.len() {
                return Err(DevError::Io);
            }
            chunk.copy_from_slice(&block);
        }
        Ok(())
    }

    fn write_block(&mut self, block_id: u64, buf: &[u8]) -> DevResult {
        let blocks = self.queue.lock().write_blocks_blocking(block_id as _, buf);
```

**瓶颈含义：**

- 多线程并发 `read`/`write` 系统调用可能在 **同一把 `Mutex`** 上排队；virtio 层又是 **同步完成**，缺少 ** per-CPU 队列 / 中断合并** 时，CPU 与设备之间偏 **轮询式同步等待**（具体取决于 `virtio-drivers` 内部实现与 HAL）。
- `enable_irq` / `handle_irq` 在 virtio 包装中为 **`todo!()` / 恒 false**，说明该栈上 **未走 IRQ 驱动 I/O 完成事件** 的典型路径（偏轮询或同步完成），高 QPS 小块随机访问时 CPU 占用易升高。

```92:106:tgoskits/platform/axplat-dyn/src/drivers/blk/virtio.rs
    fn enable_irq(&mut self) {
        todo!()
    }

    fn disable_irq(&mut self) {
        todo!()
    }

    fn is_irq_enabled(&self) -> bool {
        false
    }

    fn handle_irq(&mut self) -> rd_block::Event {
        rd_block::Event::none()
    }
```

### 3.2 文件系统与页缓存 / 缓冲

**EXT4 块设备侧存在「单块 cache + dirty」模型**，顺序大块读写会反复走 `dev.read`/`write`；元数据密集场景受 journal 与树深度影响。

```81:117:tgoskits/components/rsext4/src/blockdev/cached_device.rs
    /// Reads `count` blocks directly into `buffer`.
    pub fn read_blocks(
        &mut self,
        buffer: &mut [u8],
        block_id: AbsoluteBN,
        count: u32,
    ) -> Ext4Result<()> {
        ...
        self.dev.read(buffer, block_id, count)
    }

    /// Writes `count` blocks directly from `buffer`.
    pub fn write_blocks(
        &mut self,
        buffer: &[u8],
        block_id: AbsoluteBN,
        count: u32,
    ) -> Ext4Result<()> {
        ...
        self.dev.write(buffer, block_id, count)
    }
```

**瓶颈含义：** 大根盘镜像 + 自托管编译 = **大量 EXT4 读写 + 元数据更新**；与 3.1 的同步块路径叠加后，**端到端延迟**常表现为「磁盘线程/锁 + FS 层」而非单纯 CPU。

### 3.3 内存与配置一致性

- 内核镜像默认 **4GiB 物理映射模型**（见 2.1 引用）。QEMU **`-m` 过小** 或与 OpenSBI/DTB 布局不匹配时，会出现 **早期引导卡住或 page fault**（历史 issue：`qemu-run-kernel.sh` 固定 **128MiB / `-smp 1`**，与 **SMP 发行内核** 不一致时尤其明显）。

```61:63:scripts/qemu-run-kernel.sh
# axplat x86-pc / riscv64-qemu-virt：phys-memory-size=0x800_0000, max-cpu-num=1
GUEST_MEM=128M
GUEST_SMP=1
```

**建议：** 性能或正确性测试 **M6 / SMP 内核** 时，以 `scripts/demo-m6-selfbuild.sh`、`scripts/bench-m6-guest-smp.sh` 的 **`-smp` / `-m`** 为准，勿混用 `qemu-run-kernel.sh` 的默认 RISC-V 参数。

### 3.4 调度与并行（用户态可见行为）

- `sys_sched_setscheduler` / `sys_sched_getparam` 等为 **简化桩**（返回成功或固定值），**不等于 Linux CFS 语义**。
- `sched_setaffinity` 已接到 `ax_task::set_current_affinity`，但 **I/O 与 FS 的全局锁** 仍可能让 **多线程负载「看起来并行、实际串行」**。

```108:136:tgoskits/os/StarryOS/kernel/src/syscall/task/schedule.rs
pub fn sys_sched_setaffinity(
    _pid: i32,
    cpusetsize: usize,
    user_mask: *const u8,
) -> AxResult<isize> {
    ...
    ax_task::set_current_affinity(cpu_mask);
    Ok(0)
}
...
pub fn sys_sched_setscheduler(_pid: i32, _policy: i32, _param: *const ()) -> AxResult<isize> {
    Ok(0)
}
```

### 3.5 并行：构建与 I/O 重叠

- **访客内 `cargo build -jN`**：并行度受 **依赖图** 与 **单盘 I/O** 限制；rustc 并行时若 **根文件系统在同一 virtio-blk** 上，**锁 + 同步块 I/O** 易成为上限。
- **脚本层**（如 `scripts/bench-m6-guest-smp.sh`）用 **多路 `dd`** 测并行时，若用户态工具触发 **ioctl/栈/GLIBC 路径 bug**，会与「真实 I/O 吞吐」混淆，需用 **最小 syscall 负载**（如 `dd` 到 `/dev/null`）分离测量。

---

## 4. 结论与建议的下一步

1. **当前最可能的系统级瓶颈排序（静态 +一次实测）：**  
   **块层（全局锁 + 同步 virtio 完成） ≥ EXT4/journal 元数据路径 ≥ QEMU/TCG 宿主算力**；**内存模型一致性**是正确性前提；**调度策略桩**对 CPU 密集多任务影响次于 **I/O 串行化**。
2. **实测建议：** 在固定 **`M6_QEMU_SMP`** 下，用 `scripts/bench-m6-guest-smp.sh` 分离 **访客墙钟** 与 **宿主 QEMU 墙钟**；大镜像务必 **`file.locking=off` + 独占副本或跳过重复 cp**。
3. **工程化改进方向（若要做优化）：** virtio-blk **多队列**、块层 **per-CPU 或细粒度锁**、**异步块层 + 完成队列**；FS 侧 **readahead / 写回策略**；对 **robust list / BadAddress** 做单独 issue 跟踪以免误判为 I/O 慢。

---

## 5. 复现清单（供审计）

```bash
# 编译（容器内）
docker run --rm -v "$PWD:/work" -w /work auto-os/starry:latest \
  bash -lc 'export PATH="/opt/riscv64-linux-musl-cross/bin:$PATH"; bash scripts/build.sh ARCH=riscv64'

# 运行（需已有 rootfs-run.img；示例为仓库内路径）
docker run --rm --privileged -v "$PWD:/work" -w /work auto-os/starry:latest \
  bash -lc 'export PATH="/opt/riscv64-linux-musl-cross/bin:$PATH"
  rust-objcopy -O binary /work/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos /tmp/k.bin
  timeout 300 qemu-system-riscv64 -display none -machine virt -bios default -smp 4 -m 5G \
    -kernel /tmp/k.bin -cpu rv64 -monitor none -serial file:/tmp/serial.txt \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file=/work/.guest-runs/riscv64-m6/rootfs-run.img,file.locking=off \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 </dev/null
  strings /tmp/serial.txt | tail -50'
```

---

*本报告基于仓库当前 HEAD 的脚本与源码路径；若分支切换，请以实际 `scripts/build.sh` / 平台驱动为准。*
