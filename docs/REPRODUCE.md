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

```bash
bash scripts/reproduce-all.sh
```

What happens:

1. **`docker build -t auto-os/starry`** — first time only, ~5 min.
   Image contains rust nightly-2026-04-01, qemu-system-riscv64, musl-cross,
   binfmt, cargo subcommands, etc.
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
| Just `docker build` the image | `sudo docker build --network host -t auto-os/starry .` |
| Drop into the container shell | `sudo docker run --rm -it --privileged --network host -v $PWD:/work -w /work auto-os/starry bash` |
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
