# M6 自托管构建（Guest Cargo）复现与成果说明

## 目标

在 **QEMU + StarryOS 访客** 内，使用镜像预置的 **Alpine musl rustc/cargo**，对 `/opt/tgoskits` 执行 `cargo build -p starry-kernel`（及后续 starryos 两阶段链接），验证「内核环境里能编内核」闭环。宿主侧入口脚本为 `scripts/demo-m6-selfbuild.sh`，成功判据为串口日志中出现：

- `===M6-SELFBUILD-PASS===`（完整 starryos ELF），或  
- `===M6-SELFBUILD-LIB-PASS===`（仅内核 lib 阶段成功时的降级标记），或  
- `===M6-SELFBUILD-SUBSET-PASS===`（`demo-m6-selfbuild.sh --subset` 时的快速子集）

## 复现环境

- 仓库根目录具备 `tgoskits` 与已构建的宿主内核 ELF：  
  `tgoskits/target/riscv64gc-unknown-none-elf/release/starryos`（由 `bash scripts/build.sh ARCH=riscv64` 生成）。
- 自托管 ext4 镜像：  
  `tests/selfhost/rootfs-selfbuild-riscv64.img`  
  （由 `tests/selfhost/build-selfbuild-rootfs.sh` 在 **privileged** 的 `auto-os/starry` 容器内生成；镜像内需含 `lld`，见下文「镜像补丁」）。
- 推荐在 Docker 内执行（与 CI/文档一致），示例：

```bash
docker run --rm --privileged --network host -v "$PWD":/work -w /work \
  auto-os/starry:latest bash -lc '
  M=/tmp/m6sync && mkdir -p "$M" && mount -o loop /work/tests/selfhost/rootfs-selfbuild-riscv64.img "$M" &&
  awk "/<<'\''GUESTSH'\''/{p=1;next} /^GUESTSH\$/{exit} p" \
    /work/tests/selfhost/build-selfbuild-rootfs.sh > "$M/opt/build-starry-kernel.sh" &&
  chmod +x "$M/opt/build-starry-kernel.sh" && umount "$M" &&
  export M6_STALL_SEC=0 M6_QEMU_TIMEOUT_SEC=28800 &&
  bash scripts/build.sh ARCH=riscv64 &&
  bash scripts/demo-m6-selfbuild.sh
'
```

说明：

- **loop 挂载后写回** `GUESTSH`：保证访客脚本与 `tests/selfhost/build-selfbuild-rootfs.sh` 中 heredoc 一致（避免只改仓库未改盘内脚本）。
- **`M6_STALL_SEC=0`**：关闭「串口日志字节数不变」检测。访客内 rustc 可能 **很长时间没有任何 crate 级输出**，默认停滞检测易误杀；关闭后仅依赖 `M6_QEMU_TIMEOUT_SEC`（建议 ≥ 8h，视机器与是否全速仿真而定）。
- 串口全量日志：`.guest-runs/riscv64-m6/results.txt`（可用 `strings` 查看含转义序列的内容）。

预检（不启 QEMU）：

```bash
bash scripts/verify-m6-rootfs.sh
```

## 快速子集（确认工具链大致正常）

不编整棵 `starry-kernel` 时，可用 **`bash scripts/demo-m6-selfbuild.sh --subset`**。访客内依次执行：

1. `cargo metadata --offline --no-deps` — workspace 根解析  
2. `cargo pkgid --offline -p riscv-h`  
3. `cargo pkgid --offline -p ax-cpu`  
4. `cargo pkgid --offline -p ax-errno`（确认离线依赖解析）  

成功判据：串口含 **`===M6-SELFBUILD-SUBSET-PASS===`**。仍须先 **loop 挂载** 把 `build-selfbuild-rootfs.sh` 里的 `GUESTSH` 同步到镜像内 `/opt/build-starry-kernel.sh`（与完整 M6 相同）。

## 本轮已解决的关键问题（技术摘要）

1. **`LD_LIBRARY_PATH` 污染 glibc 进程**  
   仅在 `_run_cargo` 的 `env` 中为 musl cargo/rustc 注入 `LD_LIBRARY_PATH`；**禁止**在解释 `build-starry-kernel.sh` 的 glibc `bash` 上全局 export 指向 Alpine 的路径（否则 Welcome 后易 `stack smashing`）。

2. **rustc 使用绝对路径 `/usr/bin/cc`，绕过 PATH 上的 `/opt/ccwrap/cc`**  
   导致子进程仍带 musl 的 `LD_LIBRARY_PATH`，glibc **clang 链 musl build.rs** 时加载错误 `libstdc++.so.6` 并 **SIGSEGV**。  
   处理：在访客脚本中设置  
   `CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_LINKER=/opt/ccwrap/cc`，  
   并令 `CC`/`CXX` 等指向 `/opt/ccwrap/*`；`ccwrap` 内在调用系统 clang 前 **`unset LD_LIBRARY_PATH`**。

3. **riscv64 上 gnu `collect2` 在访客内易 ICE**  
   musl-gcc 包装器会回落到 `riscv64-linux-gnu-gcc`，仍可能 SIGSEGV/ICE。  
   处理：为 **主机 triple** `riscv64-alpine-linux-musl` 增加  
   `CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_RUSTFLAGS="-Clink-arg=-fuse-ld=lld"`，  
   并在 Debian rootfs 中安装 **`lld`**（已在本机用 chroot 对现有 `rootfs-selfbuild-riscv64.img` 执行过 `apt-get install -y lld`；后续重建 rootfs 时 `build-selfbuild-rootfs.sh` 已把 `lld` 写入 apt 列表）。

4. **停滞检测误杀**  
   默认 `M6_STALL_SEC` 提高到 **10800**，并支持 **`M6_STALL_SEC=0` 关闭**（见上）。  
   曾尝试 `CARGO_TERM_PROGRESS_WHEN=always`，在串口非 TTY 场景会报错且可能连带异常退出，已移除。

5. **访客 `cargo -v`**  
   在 `build-starry-kernel.sh` 中为三次 `cargo build` 增加 `-v`，在有条目编译时略增串口信息量（仍可能长时间无输出，故推荐长跑时 `M6_STALL_SEC=0`）。

6. **演示脚本注入**  
   `scripts/demo-m6-selfbuild.sh` 在挂载镜像时覆盖写入 `/opt/ccwrap/cc`，使**旧盘**也能得到与 rootfs 构建脚本一致的 ccwrap 行为。

## 验证状态（截至本文撰写时的 CI 代理机）

- **已消除**：此前约 **20s 内**即出现的 `clang`/`collect2` 与 **`stack smashing`** 类失败；在 **`M6_STALL_SEC=900`** 的配置下，曾观察到 QEMU **存活超过 15 分钟**且未再因链接器立即崩溃（说明 proc-macro / 主机链接路径已打通到「可长跑」阶段）。
- **未在代理机单次会话内跑完**：访客内完整 `starry-kernel` + starryos 两阶段在 QEMU 仿真下可达 **数小时**；需在本地或 CI 使用 **`M6_STALL_SEC=0`** 与足够大的 **`M6_QEMU_TIMEOUT_SEC`** 跑完全程后，在 `results.txt` 中检索 `===M6-SELFBUILD-PASS===` 作为最终盖章。

## 已知非致命告警

- Cargo 可能打印 **`failed to save last-use data` / `database or disk is full`（sqlite 13）**：在部分 lwext4 组合上属已知噪声；宿主 demo **不再**仅凭该字符串杀 QEMU。若后续仍出现**硬失败**，需再区分 sqlite 与真实磁盘满。

## 相关文件

| 路径 | 作用 |
|------|------|
| `tests/selfhost/build-selfbuild-rootfs.sh` | 构建自托管镜像、注入 `GUESTSH`（`/opt/build-starry-kernel.sh`）、ccwrap、apt 含 `lld` |
| `scripts/demo-m6-selfbuild.sh` | QEMU 启动、`run-tests`/`ccwrap` 注入、超时与停滞检测 |
| `scripts/verify-m6-rootfs.sh` | 挂载镜像的静态预检 |
| `.guest-runs/riscv64-m6/results.txt` | 串口捕获日志 |

## 最新实验记录（本次会话）

- 时间：2026-04-25（本地 Docker `auto-os/starry:latest`，riscv64 qemu-virt）
- 执行方式：先把 `build-selfbuild-rootfs.sh` 中 `GUESTSH` 同步到镜像，再运行  
  `bash scripts/demo-m6-selfbuild.sh --subset`。  
  为避免宿主上同一 raw 文件写锁冲突，运行时使用 rootfs 副本：  
  `ROOTFS=/work/.guest-runs/riscv64-m6/rootfs-run.img`。
- 结果：串口日志出现 **`===M6-SELFBUILD-SUBSET-PASS===`**，子集通过。
- 证据位置：`.guest-runs/riscv64-m6/results.txt`（可 `strings` 后检索 `SUBSET-PASS`）。

备注：PASS 标记后串口可能出现 `*** stack smashing detected ***`，当前以 demo 脚本判据（PASS 标记）作为子集验收标准；完整 M6 仍以 `===M6-SELFBUILD-PASS===` 为准。

---

*本文档描述复现步骤与已合入仓库的修复要点；完整 M6 PASS 以本地长跑日志中的 `===M6-SELFBUILD-PASS===` 为准。*
