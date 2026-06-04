# M6 — 在 Starry 生态里「用 Starry 用户态去编 Starry 内核」

## 与 M5 的关系

| 里程碑 | 证明内容 |
|--------|----------|
| **M5** | QEMU 里 **Starry 内核 + Alpine rootfs**，guest 内 **rustc / cargo** 编 **用户态** hello + hellocargo → `===M5-DEMO-PASS===`（`scripts/demo-m5-rust.sh` / `scripts/reproduce-all.sh`） |
| **M6（本目录）** | 在 **与 guest 相同的 riscv64 Linux/musl 用户态** 下，对 **`starryos` 内核 crate** 跑 `cargo check`（或将来在 guest 内全量 `cargo build` 并换内核启动） |

当前仓库**已自动化**：

1. **确认 M5 已复现**：`bash scripts/verify-reproduce-m5.sh`
2. **M6 代理（Docker）**：`bash scripts/m6-docker-riscvlinux-cargo-check.sh`  
   - 使用 **`docker run --platform linux/amd64` + `ubuntu:24.04`**：在容器内安装与 `scripts/setup-env.sh` 相同的 **`riscv64-linux-musl-cross`**（供 **`lwext4_rust`** 找到 `riscv64-linux-musl-cc`），再 **rustup + ax-config-gen + cargo**，第二遍用 **`cargo check -p starryos`**（目标 **`riscv64gc-unknown-none-elf**`）代替完整链接验收。  
   - 需要网络（apt / rustup / crates.io）。**不是**「在 riscv64 CPU 上跑 rustc」：当前 **riscv64 + musl** 上 rustup 官方安装器不可用，且与 **x86_64 预编译 musl 交叉包** 架构一致的做法是固定 **amd64** 容器；真在 **QEMU 的 Alpine guest** 里自举需另配 **apk rust** 或 **vendor** 等（见下文）。

## 全量「在 QEMU Starry guest 里 cargo build 出 starryos 并换内核启动」

尚未一键脚本化，推荐路线：

1. **virtio-9p**：QEMU 增加 `-virtfs local,path=$PWD/tgoskits,...`，init 或 `run-tests.sh` 里 `mount -t 9p ... /mnt/tg`。
2. **guest 内**：与 host 相同 `ax-config-gen` + 两遍 `cargo build -p starryos`（见 `scripts/build.sh`），需 **rust-src / llvm-tools** 或 **cargo vendor** 进 rootfs（体积大）。
3. **验证**：`riscv64-linux-musl-objcopy -O binary` guest 产出的 ELF，第二次 QEMU `-kernel guest.bin` 起机到 shell。

若你希望在 **无 Docker** 的 Linux 上验证，可用 **qemu-riscv64-static + chroot** 挂载 rust rootfs 并 `mount --bind` 宿主 `tgoskits`（需 root）；脚本可在此基础上扩展。

## 一键复现 M5（Linux）

```bash
sudo bash scripts/setup-env.sh
bash scripts/check-env.sh
bash scripts/reproduce-all.sh
bash scripts/verify-reproduce-m5.sh
```

可选（有 Docker 时）：

```bash
bash scripts/m6-docker-riscvlinux-cargo-check.sh
```

或从本目录：

```bash
bash tests/selfhost/m6/test_verify_m5_reproduced.sh
bash tests/selfhost/m6/test_m6_docker_riscvlinux_cargo_check.sh
```
