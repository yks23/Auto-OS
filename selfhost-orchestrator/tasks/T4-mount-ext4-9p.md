# T4：mount 放开 ext4，添加 virtio-9p

## 目标仓库
- **上游**：`https://github.com/rcore-os/tgoskits`
- **基线分支**：`dev`
- **PR 目标分支**：`dev`
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
