# REPRODUCE — From `git clone` to StarryOS self-build (Docker-only host)

This is the new minimal-host-deps reproduction guide. The **only** thing
the host needs is **Docker**. All other build / run dependencies (rust
nightly, qemu, musl-cross, binfmt, `tgoskits` sources, Debian + Rust
toolchain inside the guest, …) live inside the Docker image we ship.

> If you'd rather see _what_ is happening end-to-end before running it,
> jump straight to **§5 What this proves**.

---

## 1. Host requirements

| | |
|---|---|
| OS | any Linux that runs Docker (Ubuntu 22.04+ / Debian 12+ tested) |
| Arch | `x86_64` (cross-builds RISC-V images) |
| RAM | ≥ 4 GiB (QEMU guest uses 2-3 GiB for the demo) |
| Disk | ≥ 12 GiB free (Docker image ~3 GiB, rootfs images ~5 GiB) |
| **Required packages** | **`docker`** — that's it |

> No need to install rust, qemu, musl-cross, binfmt-support, e2fsprogs, … on
> the host. The Docker image already has them.

---

## 2. Get the code

```bash
git clone --recurse-submodules https://github.com/yks23/Auto-OS.git
cd Auto-OS
```

(`--recurse-submodules` pulls `tgoskits` from `yks23/tgoskits` selfhost-m5,
which already includes T1-T10 + F-α/β/γ/δ + M1.5 + F-ε.)

---

## 3. Install docker (one-shot)

If you already have docker & it's running, skip this.

```bash
sudo bash scripts/setup-env.sh
```

What it does:
- `apt-get install docker.io` (or `dnf install docker` on Fedora)
- Tries to start `dockerd` via systemd; if there is no systemd (cloud agents,
  nested containers, ...) it launches it manually with
  `--storage-driver=vfs --iptables=false`.

Verify:

```bash
bash scripts/check-env.sh
# expected:  Summary: 12 PASS, 0 WARN, 0 FAIL
```

---

## 4. One-button reproduce

**Docker Desktop 内存**：`docker info` 里 **Total Memory** 建议 **≥10 GiB**（arm64 上整仓 `cargo` 否则易慢或 OOM）。若低于约 **9 GiB**，`reproduce-all.sh` 会 **默认退出**；仅在无法调大 VM 时临时跳过：`AUTO_OS_REPRODUCE_ALLOW_LOW_DOCKER_MEM=1 bash scripts/reproduce-all.sh ...`。

**Cargo 缓存**：`docker run --rm` 会丢掉容器可写层；脚本默认把镜像内 **`/usr/local/cargo/registry`** 与 **`git`** 挂到仓库下 **`.docker-cargo-registry/`**（已在 `.gitignore`），避免每次冷启动重复拉 crates。不需要时：`AUTO_OS_DOCKER_NO_CARGO_CACHE=1`。自定义目录：`AUTO_OS_DOCKER_CARGO_CACHE=/path/to/dir`。

**跨机续作（路径 A / M5）**：对齐同一 Auto-OS **commit** 与 **`git submodule update --init tgoskits`** 后，可将 **`tgoskits/target/`** 与已生成的 **`tests/selfhost/rootfs-selfhost-rust-riscv64.img`** 用 `rsync` 或拷盘带到新机，再 **`bash scripts/reproduce-all.sh --skip-build`**，可显著省时间与流量。

```bash
bash scripts/reproduce-all.sh
```

**Docker 平台**：`reproduce-all.sh` 为 `docker build` / `docker run` 传入 **`--platform`**，与
`Dockerfile` 里 BuildKit 的 **`TARGETARCH`** 一致：

| 宿主 | 默认 `--platform` | 镜像内 RISC-V 宿主工具链（lwext4 等） |
|------|---------------------|--------------------------------------|
| **宿主 CPU 为 arm64 / aarch64**（Apple Silicon、Linux aarch64 云主机等） | `linux/arm64` | arceos **riscv64-linux-musl-cross**（i686 宿主）+ **`qemu-i386-static`** 包装为 `riscv64-linux-musl-*`，供 lwext4 真 musl 头文件 |
| **其他**（x86_64、CI、Intel Mac 等） | `linux/amd64` | arceos **riscv64-linux-musl-cross** 预编译包 |

Apple Silicon 默认 **不再** 构建 `linux/amd64` 用户态镜像，以避免 Docker Desktop 上常见的
`fork/exec /usr/bin/runc`、`unpigz: exec format error`（QEMU/Rosetta 链未就绪或损坏时）。

需要强制 amd64 时（例如你已修好 Rosetta 且希望与 CI 完全一致）：  
`DOCKER_PLATFORM=linux/amd64 bash scripts/reproduce-all.sh`。

若切换过平台仍异常，可：`docker builder prune -f` 后重试。

What happens:

1. **`docker build --platform <默认或 DOCKER_PLATFORM> -t auto-os/starry`** — first time only, ~5 min.
   Image contains rust nightly-2026-04-01, qemu-system-riscv64, riscv cross toolchain for lwext4,
   binfmt helpers, cargo subcommands, etc.
2. `git submodule update --init tgoskits` (no-op if already inited).
3. **Inside the container**:
   - `bash scripts/build.sh ARCH=riscv64` — cross-compiles the StarryOS
     riscv64 kernel ELF (`tgoskits/target/.../release/starryos`).
   - If the M5 demo rootfs (`tests/selfhost/rootfs-selfhost-rust-riscv64.img`)
     does not exist, builds it (~3-5 min, Alpine + apk rust 1.95).
   - Runs the **M5 demo**: boot starry kernel under qemu, inject hello.rs +
     hellocargo project, watch the guest run `rustc hello.rs` and
     `cargo --offline build --release` to completion, then execute the
     produced binary.

Successful run ends with:

```
=== M5 demo done ===
...
Hello from rustc, compiled INSIDE StarryOS!
1..=10 sum = 55
   Compiling hellocargo v0.1.0
    Finished `release` profile in ~10s
Hello from cargo, INSIDE StarryOS!
add_squares(3, 4) = 25  (expect 25)
===M5-DEMO-PASS===
```

Wall time on a 16C/16G x86_64 host:
- first run: ~10 min total (image build dominates)
- repeat run with `--skip-build`: ~1.5 min

---

## 5. What this proves

After `reproduce-all.sh` exits 0:

- The StarryOS riscv64 kernel was **freshly cross-compiled** on the host
  (inside the docker container) from upstream sources.
- The kernel **boots in QEMU** (riscv64-virt + virtio-blk + virtio-net).
- It mounts an **Alpine ext4 rootfs** that contains a real `rustc 1.95` and
  `cargo 1.95` (provided by Alpine's `apk add rust cargo`).
- It **runs `rustc hello.rs`** end-to-end: rustc forks `cc` for linking via
  `posix_spawn` (this is precisely the path that the F-ε vfork fix unblocked),
  produces a static RISC-V ELF, then **starry runs that ELF** and prints
  `1..=10 sum = 55`.
- It **runs `cargo --offline build --release`** on a multi-file project,
  which exercises cargo → rustc → cc → ld via repeated `posix_spawn` calls,
  and **executes** the cargo-built binary.

That is StarryOS self-hosting a Rust toolchain to build & run new Rust code,
with no host-side rust / qemu / musl install required.

---

## 6. Optional — M6 selfbuild rootfs (heavy)

There's a **larger** rootfs that also contains rust **nightly** and the
StarryOS kernel sources themselves (it's the rootfs you'd use to attempt
in-guest `cargo build` of the kernel). Building it is heavier:

```bash
bash scripts/reproduce-all.sh --m6
```

This will additionally:

- build `tests/selfhost/rootfs-selfbuild-riscv64.img` (~5 GiB raw, ~1.3 GiB
  xz-compressed) — Debian 13 trixie riscv64 rootfs containing
  `rustc nightly-2026-04-01`, `cargo`, `musl-tools`, the tgoskits sources at
  `/opt/tgoskits` with `cargo fetch` already populated.
- boot the starry kernel against it and run `scripts/demo-m6-selfbuild.sh`,
  which inside the guest runs `rustc --version`, `cargo --version`,
  `git log -1` on `/opt/tgoskits`, then attempts
  `cargo build -p ax_errno --target riscv64gc-unknown-none-elf --release`.

Status: **the toolchain itself runs** (we have logs of `rustc 1.96.0-nightly`
and `cargo 1.96.0-nightly` printing inside the guest), but a full `cargo
build` of starry-kernel-sized C/C++ build scripts hits a `*** stack smashing
detected ***` in user-space, which we believe is a starry user-stack /
mprotect interaction — separate from the F-ε fix and not yet fixed in this
branch. M6 thus boots the toolchain successfully but does not yet finish
the kernel build.

---

## 7. Manual / debug recipes

| Want… | Run |
|---|---|
| Just `docker build` the image | `sudo docker build --platform linux/amd64 --network host -t auto-os/starry -f Dockerfile .`（Intel/Linux amd64）；Apple Silicon 上常用 `--platform linux/arm64` |
| Drop into the container shell | `sudo docker run --rm -it --platform linux/arm64 --privileged --network host -v $PWD:/work -w /work auto-os/starry bash`（与 `reproduce-all` 默认一致时） |
| Re-build kernel only | inside container: `bash scripts/build.sh ARCH=riscv64` |
| Re-build M5 rootfs only | inside container: `bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64 PROFILE=rust` |
| Re-build M6 rootfs only | inside container: `bash tests/selfhost/build-selfbuild-rootfs.sh` |
| Re-run M5 demo only | inside container: `bash scripts/demo-m5-rust.sh` |
| Re-run M6 demo only | inside container: `bash scripts/demo-m6-selfbuild.sh` |

---

## 8. Files / layout reference

```
Dockerfile                                      # the only build env we ship
docker/register-binfmt.sh                       # helper inside image
scripts/check-env.sh                            # only checks docker
scripts/setup-env.sh                            # only installs docker
scripts/reproduce-all.sh                        # host driver (docker run)
scripts/reproduce-in-container.sh               # runs inside the container
scripts/build.sh                                # build StarryOS kernel ELF
scripts/demo-m5-rust.sh                         # M5: cargo build hello world
scripts/demo-m6-selfbuild.sh                    # M6: in-guest starry build
tests/selfhost/build-selfhost-rootfs.sh         # M5 rootfs (alpine + rust)
tests/selfhost/build-selfbuild-rootfs.sh        # M6 rootfs (debian + nightly)
tgoskits/                                       # StarryOS submodule
patches/                                        # historical patches (T1-T10 + F-α-ε)
docs/REPRODUCE.md                               # this file
docs/DEMO.md                                    # M5 demo writeup
```
