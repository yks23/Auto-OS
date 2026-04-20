# T4：mount 放开 ext4，添加 virtio-9p

## 目标仓库
- **工作仓**：`https://github.com/yks23/Auto-OS`（你 push 到这里）
- **tgoskits 子模块**：只读，pin 在 PIN.toml 指定的 commit；**不 push tgoskits**
- **PR 目标**：`yks23/Auto-OS` 的 `main` 分支
- **交付物**：`patches/Tn-slug/*.patch` + `tests/selfhost/test_*.c`
- **你的工作分支**：`cursor/selfhost-mount-fs-7c9d`

## 当前缺陷
`tgoskits/os/StarryOS/kernel/src/syscall/fs/mount.rs:20-22`：

```rust
if fs_type != "tmpfs" {
    return Err(AxError::NoSuchDevice);
}
```

guest 内不能挂第二块 ext4 toolchain 镜像，也不能 9p 直通 host 源码——这是 self-hosting 的物理瓶颈（rootfs 不能塞下整个 toolchain）。

## 验收标准

### A. ext4 挂载（必须）

复用 `ax-fs-ng-ext4`（已在 `kernel/Cargo.toml` 作为 `ax-fs` 依赖）。

- `sys_mount(source, target, "ext4", flags, data)`：
  - `source` 解析成块设备路径（先支持 `/dev/vdb`、`/dev/vdc`，可以查 `ax-driver` 已注册的 block device）。
  - 在 `target` 创建 mountpoint，attach ext4 fs root。
  - 失败返回合理 errno：`ENODEV`（设备不存在）、`EBUSY`（已挂）、`ENOTBLK`、`EINVAL`。
- `sys_umount2(target, flags)`：
  - 支持 `MNT_DETACH`、`MNT_FORCE`。
  - 若 target 仍有打开的 fd，返回 `EBUSY`（除非 MNT_FORCE）。
- `sys_mount(_, target, _, MS_BIND, _)`：bind mount，让一个目录"映射"到另一个挂点。简化版可只支持目录 bind（不做文件 bind）。

### B. virtio-9p 挂载（必须，stretch 可选）

QEMU 已支持 virtio-9p：`-fsdev local,id=hostsrc,path=/host/path,security_model=none -device virtio-9p-pci,fsdev=hostsrc,mount_tag=hostsrc`。

- 在 `tgoskits/components/` 或 `os/arceos/modules/ax-driver/` 增加 `virtio-9p` 驱动（virtio device id 9，transport 走 virtio-mmio 或 virtio-pci）。
- 实现 `9p2000.L` 协议子集（`Tversion / Tattach / Twalk / Topen / Tread / Twrite / Tclunk / Tcreate / Tremove / Tstat / Twstat`）。可考虑使用现成 crate（如 `p9` 或自写最小实现）。
- `sys_mount("hostsrc", "/workspace", "9p", flags, "trans=virtio,version=9p2000.L")` 能挂上。

**如果 9p 完整实现工作量过大**：本任务 9p 部分允许只到"驱动+协议骨架"+`unimplemented`，但 ext4 必须完整可用，并在 PR 描述中清晰说明 9p 的进度与剩余工作。

### C. QEMU 配置示例

在 `tgoskits/os/StarryOS/configs/qemu/qemu-{x86_64,riscv64}.toml` 新增 `[selfhost]` profile（或加注释提示用户怎么改）来挂第二块 ext4 镜像与 9p 共享。**不修改默认配置**，避免破坏现有 CI。

### D. 测试

- `test_mount_ext4.c`：在已经准备好的 `/dev/vdb`（CI 准备一个 ext4 空镜像）上 `mount -t ext4 /dev/vdb /mnt && touch /mnt/x && umount /mnt`，重新挂载后 `/mnt/x` 必须仍然存在。
- `test_mount_bind.c`：`mount --bind /tmp/a /tmp/b` 后两边 ls 一致。

### E. 构建与回归

- `make ARCH=riscv64 build && make ARCH=x86_64 build` 通过。
- 默认 `make rootfs && make run` 仍能进入 BusyBox shell（不破坏既有路径）。

## 提交策略

1. `feat(starry/fs): allow real ext4 in sys_mount`
2. `feat(starry/fs): support MS_BIND mount`
3. `feat(starry/fs): add umount2 with MNT_DETACH/MNT_FORCE`
4. （可选）`feat(driver): virtio-9p driver skeleton`
5. （可选）`feat(starry/fs): wire virtio-9p as a mount fs_type`
6. `test(starry/fs): mount ext4 / bind tests`

PR 标题：`feat(starry/fs): expand sys_mount to ext4 + 9p for self-hosting`。

## 注意

- 不要破坏 `pseudofs` 的 `/dev`、`/tmp`、`/proc`、`/sys` 自动挂载流程。
- `sys_mount` 的权限检查可以暂时不做（无 CAP_SYS_ADMIN）。

---

## 🧪 测试填充责任（强制）

**重要更新（Director, 2026-04-18）**：本任务 PR #2 已经把测试**骨架**写好了
（ 全部 main 默认 `pass()`，含 TODO Plan）。
你必须在你的 PR 里**填满**与 T4 相关的所有骨架文件，让 main 真正
验证对应 syscall 的行为。

### 你必须填充的骨架文件

见 `selfhost-orchestrator/DETAILED-TEST-MATRIX.md` 的 §T4：mount ext4 + bind 章节。

**对每个测试**：
1. 打开 `tests/selfhost/test_xxx.c`（或 .sh）
2. 把 main 里 `/* TODO(T4): ... */` 注释保留作为 plan 文档
3. **删掉** `pass(); return 0;` 占位
4. 按 DETAILED-TEST-MATRIX 的 Action / Expected return / Expected errno / Side effect 四列实现真正的验证逻辑
5. 用 `fail("...")` 在任意 assert 失败时立即 exit 1
6. 全部 assert 通过才 `pass();`

### 质量硬指标

- 每个 syscall 调用都必须**检查返回值**，失败时 `fail("syscall_name failed: %s", strerror(errno))`
- **errno 必须精确匹配**（不能用 `errno != 0` 这种宽松检查）
- **所有创建的临时文件、子进程、fd 在 fail/pass 前必须清理**（不要污染下一个测试的环境）
- 测试**幂等**：连续跑两次结果一致
- 不要依赖测试间顺序，每个测试自己 setup 自己 teardown

### Spec 引用

骨架文件顶部已经从 TEST-MATRIX.md 复制了 Spec 注释。如果你的实现细节
与 DETAILED-TEST-MATRIX 不一致（例如 errno 选择不同），**优先服从
DETAILED-TEST-MATRIX**，并在 PR 描述里说明理由。

### 测试与实现同 PR 提交

测试代码与 patches/T4-*/ 内的实现代码必须在**同一个 PR** 内提交。
review 时会要求测试 PASS 才合并。本机 `make ARCH=...` 编测试可能
因 musl-gcc 缺失 SKIP，那就在 PR 里说明，CI 上验证。

### Commit 拆分建议

1. `feat(patches/T4): <实现>`
2. `test(selfhost/T4): fill in skeleton test_<xxx>.c`（每填一组测试可以一个 commit）
3. （可选）`docs(T4): note any deviation from DETAILED-TEST-MATRIX`

