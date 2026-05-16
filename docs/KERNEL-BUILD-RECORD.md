# 内核双架构构建留档（第一遍 + 第二遍说明）

本文记录一次成功的 **first** 归档与如何在本机完成 **after-clean**（第二遍），便于对照 SHA 与复现。

## 第一遍（已完成，2026-04-24）

对应 `MANIFEST-20260424T054529Z.txt`（详见同目录下 `docs/KERNEL-MANIFEST-latest.txt` 同步副本）。

| 产物 | SHA-256 |
|------|---------|
| `.guest-runs/kernels/starryos-riscv64-20260424T054529Z-first.elf` | `4df2fb70a930edfaf735033fcb2321f4016c1f72970ee443bb23b36cc7dbee87` |
| `.guest-runs/kernels/starryos-x86_64-20260424T054529Z-first.elf` | `104b4d460a2548b3f4f1051c02737e2736b2837dc8ffc2e57c23df42565fab3b` |

提交时的 git：`b71adc86acbe071ff5f16b81c99f5e9065a23ed9`（以你当时 `MANIFEST` 为准）。

## 第二遍（`cargo clean -p starryos` 后再编）— 已完成

已在 **`auto-os/starry`** 容器内执行：

`bash scripts/build-dual-kernels.sh --second-pass-only`

对应 **`MANIFEST-20260424T074215Z.txt`**（摘要已同步到 **`docs/KERNEL-MANIFEST-latest.txt`**）。

| 产物 | SHA-256 |
|------|---------|
| `.guest-runs/kernels/starryos-riscv64-20260424T074215Z-after-clean.elf` | `4df2fb70a930edfaf735033fcb2321f4016c1f72970ee443bb23b36cc7dbee87` |
| `.guest-runs/kernels/starryos-x86_64-20260424T074215Z-after-clean.elf` | `104b4d460a2548b3f4f1051c02737e2736b2837dc8ffc2e57c23df42565fab3b` |

与 **first** 轮哈希一致，说明在**未改源码**的前提下 **`cargo clean -p starryos` 后重编** 得到**可复现**的相同二进制（正常）。

### 网络拉不下 `drivercraft/arm-scmi` 时的处理（已写入仓库）

`tgoskits/vendor/arm-scmi` 为 GitHub 指定 commit 的源码展开，`tgoskits/Cargo.toml` 增加 **`[patch."https://github.com/drivercraft/arm-scmi"]`** 走本地 path，避免容器内 `git fetch` 失败。预取 tarball 可用镜像（示例）：

```bash
mkdir -p .cache && curl -fL -o .cache/arm-scmi.tgz \
  "https://ghfast.top/https://github.com/drivercraft/arm-scmi/archive/9e9942d91da2be10666aff4002d213987fa39869.tar.gz"
```

再解压到 `tgoskits/vendor/arm-scmi`（与当前布局一致）。

### 常用命令（备查）

```bash
export CARGO_NET_GIT_FETCH_WITH_CLI=true   # 其它 git 依赖仍走 git 时可选
docker run --rm --platform linux/arm64 --network host \
  -v "$PWD:/work" -w /work \
  auto-os/starry \
  bash scripts/build-dual-kernels.sh --second-pass-only
```

## 对比 first 与 after-clean

```bash
bash scripts/compare-starry-kernels.sh \
  .guest-runs/kernels/starryos-riscv64-20260424T054529Z-first.elf \
  .guest-runs/kernels/starryos-riscv64-*-after-clean.elf
```

（路径里的 glob 请换成你机器上实际文件名。）
