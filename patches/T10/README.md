# T10：selfhost rootfs（占位 patch）

- **tgoskits**：仅 `0001` 空 commit 作为任务锚点；真实 rootfs 脚本在 Auto-OS `tests/selfhost/`。
- **产物**：`tests/selfhost/build-selfhost-rootfs.sh`、`verify-selfhost-rootfs.sh`、`SELFHOST-ROOTFS.md`。

## 自检

- [ ] `scripts/sanity-check.sh` 显示 `OK`
- [ ] `sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=x86_64` 产出 ext4 + xz + sha256
- [ ] `sudo bash tests/selfhost/verify-selfhost-rootfs.sh …img` 通过
