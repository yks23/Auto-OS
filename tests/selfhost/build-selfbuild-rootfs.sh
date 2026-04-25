#!/usr/bin/env bash
# build-selfbuild-rootfs.sh — build a riscv64 rootfs that contains everything
# needed to compile StarryOS's own kernel from inside the (StarryOS) guest:
#   - Debian 13 trixie riscv64 base (glibc root + musl-gcc / build tools)
#   - **Alpine edge musl rustc/cargo** under /opt/alpine-rust (Starry 下 glibc
#     官方 nightly cargo 会栈保护崩溃；与 M5 一致用 musl 宿主工具链)
#   - static.rust-lang.org 的 **rust-std**（riscv64gc-unknown-none-elf），版本
#     与 Alpine rustc 一致；Alpine `rust-src` apk 供 `-Z build-std` 以外路径
#   - musl-tools (musl-gcc) for the lwext4_rust C build script
#   - cmake / clang / build-essential / git / pkg-config
#   - tgoskits at /opt/tgoskits（镜像内移除 rust-toolchain.toml 以免强拉
#     nightly）；`cargo fetch` 预填 registry
#
# Output:
#   tests/selfhost/rootfs-selfbuild-riscv64.img      (~7.5 GiB ext4)
#   tests/selfhost/rootfs-selfbuild-riscv64.img.xz   (compressed for release)
#
# Run inside the auto-os/starry docker image:
#   docker run --rm --privileged --network host -v $PWD:/work -w /work \
#       auto-os/starry bash tests/selfhost/build-selfbuild-rootfs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARCH="riscv64"
DEBIAN_VER="13"
DEBIAN_CODENAME="trixie"
TGOSKITS_BRANCH="selfhost-m5"
# Alpine minirootfs（与 build-selfhost-rootfs.sh 一致）；rust/cargo 来自 edge apk
ALPINE_DOT="3.21.0"
ALPINE_REL="v3.21"
ALPINE_BASE_URL="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_REL}/releases/riscv64"
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_DOT}-riscv64.tar.gz"
TGOSKITS_URL="https://github.com/yks23/tgoskits.git"

OUT_IMG="$ROOT/tests/selfhost/rootfs-selfbuild-${ARCH}.img"
WORK_DIR="${WORK_DIR:-/tmp/selfbuild-rootfs.work}"
DISK_SIZE_GB="${DISK_SIZE_GB:-20}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: run as root (this script mounts loop devices and chroots)" >&2
    exit 1
fi

# Sanity: we need binfmt + qemu-riscv64-static + chroot + GPT tools
command -v qemu-riscv64-static >/dev/null || { echo "need qemu-riscv64-static"; exit 1; }
command -v sgdisk >/dev/null || { echo "need gdisk (sgdisk)"; exit 1; }
command -v mkfs.ext4 >/dev/null || { echo "need e2fsprogs (mkfs.ext4)"; exit 1; }
# Ubuntu 24.04 + qemu-user-static：常见节点名为 riscv64（见 /usr/lib/binfmt.d/qemu-riscv64.conf）
have_riscv_binfmt() {
    [[ -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]] || [[ -f /proc/sys/fs/binfmt_misc/riscv64 ]]
}
have_riscv_binfmt || /usr/local/bin/register-binfmt
have_riscv_binfmt || { echo "binfmt_misc not available — pass --privileged to docker"; exit 1; }

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# --------------------------------------------------------- 1. download base
TARBALL="$WORK_DIR/debian-${DEBIAN_VER}-nocloud-${ARCH}.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
    echo "[1/8] downloading Debian ${DEBIAN_VER} ${ARCH} cloud rootfs..."
    curl -fL -o "$TARBALL" \
        "https://cdimage.debian.org/cdimage/cloud/${DEBIAN_CODENAME}/latest/debian-${DEBIAN_VER}-nocloud-${ARCH}.tar.xz"
fi
ls -lh "$TARBALL"

# Debian "nocloud" tarball contains a single disk.raw (3 GiB GPT-partitioned).
# Resize to DISK_SIZE_GB and grow the root partition, then mount its ext4 rootfs.
echo "[2/8] extract + resize disk to ${DISK_SIZE_GB} GiB..."
rm -rf disk-extract
mkdir disk-extract
tar -C disk-extract -xf "$TARBALL"
DISK_RAW="$WORK_DIR/disk-extract/disk.raw"
truncate -s "${DISK_SIZE_GB}G" "$DISK_RAW"

# Reset and recreate partition 1 to fill the new size
LOOP=$(losetup -fP --show "$DISK_RAW")
sgdisk -e "$LOOP" >/dev/null
sgdisk -d 1 "$LOOP" >/dev/null
sgdisk -N 1 "$LOOP" >/dev/null
losetup -d "$LOOP"

OFFSET=$((262144 * 512))    # partition 1 starts at sector 262144
losetup --offset "$OFFSET" -fP --show "$DISK_RAW" >/tmp/.loop
LOOP=$(cat /tmp/.loop)
e2fsck -fy "$LOOP" >/dev/null 2>&1 || true
resize2fs "$LOOP" >/dev/null

# --------------------------------------------------------- 3. mount + chroot prep
MNT="$WORK_DIR/mnt"
mkdir -p "$MNT"
echo "[3/8] mount + chroot prep..."
mount "$LOOP" "$MNT"
df -h "$MNT" | tail -1

cleanup() {
    sync
    umount -lR "$MNT/proc" "$MNT/dev" "$MNT/sys" "$MNT" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

cp /usr/bin/qemu-riscv64-static "$MNT/usr/bin/"
rm -f "$MNT/etc/resolv.conf"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
mount -t proc /proc "$MNT/proc"
mount --rbind /dev "$MNT/dev"
mount --rbind /sys "$MNT/sys"

run_in() { chroot "$MNT" /bin/bash -c "$*"; }

# --------------------------------------------------------- 4. apt deps
echo "[4/8] apt: build deps inside debian rootfs..."
run_in "apt-get update" >/dev/null
run_in "apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils tar git make pkg-config python3 \
    build-essential cmake clang libclang-dev musl-tools llvm lld" 2>&1 | tail -3
run_in "apt-get clean"

# rustc 构建 build.rs 时默认调 PATH 上的 cc（常指向 gcc）；riscv64 访客里 gcc/collect2 曾 ICE，统一走 clang。
echo "[4b/8] ccwrap: cc/gcc -> clang ..."
mkdir -p "$MNT/opt/ccwrap"
# 与 scripts/demo-m6-selfbuild.sh 内嵌的 ccwrap 内容保持一致（演示脚本会覆盖注入旧镜像）。
cat > "$MNT/opt/ccwrap/cc" <<'CCWRAP'
#!/bin/sh
# 清除 cargo 为 musl rustc 注入的 LD_LIBRARY_PATH，避免 glibc clang 误加载 Alpine libstdc++ 而 SIGSEGV。
unset LD_LIBRARY_PATH
case "$(basename "$0")" in
c++|g++) exec /usr/bin/clang++ "$@" ;;
*) exec /usr/bin/clang "$@" ;;
esac
CCWRAP
chmod +x "$MNT/opt/ccwrap/cc"
ln -sf cc "$MNT/opt/ccwrap/gcc"
ln -sf cc "$MNT/opt/ccwrap/c++"
ln -sf cc "$MNT/opt/ccwrap/g++"

# --------------------------------------------------------- 5. Alpine musl rustc/cargo + matching rust-std (none-elf)
echo "[5/8] Alpine stage: musl rustc/cargo -> /opt/alpine-rust ..."
# 解压到容器本机 /tmp，避免 WORK_DIR 在 Docker Desktop 绑定卷上时 tar 无法 chmod var/empty
ALPINE_STAGE="$(mktemp -d /tmp/alpine-rust-stage.XXXXXX)"
mkdir -p "$ALPINE_STAGE"/{proc,sys,dev/pts}
ALPINE_TGZ="$WORK_DIR/$ALPINE_TARBALL"
if [[ ! -f "$ALPINE_TGZ" ]]; then
    curl -fL -o "$ALPINE_TGZ" "${ALPINE_BASE_URL}/${ALPINE_TARBALL}"
fi
# Docker/rootless 下 tar 可能无法还原 owner/mode（如 ./var/empty）
tar xzf "$ALPINE_TGZ" -C "$ALPINE_STAGE" --no-same-owner --no-same-permissions
cp /usr/bin/qemu-riscv64-static "$ALPINE_STAGE/usr/bin/"
cp /etc/resolv.conf "$ALPINE_STAGE/etc/resolv.conf"
mount -t proc /proc "$ALPINE_STAGE/proc"
mount --rbind /dev "$ALPINE_STAGE/dev"
mount --rbind /sys "$ALPINE_STAGE/sys"

run_alpine() { chroot "$ALPINE_STAGE" /bin/sh -c "$*"; }

run_alpine "echo https://dl-cdn.alpinelinux.org/alpine/edge/main >> /etc/apk/repositories"
run_alpine "echo https://dl-cdn.alpinelinux.org/alpine/edge/community >> /etc/apk/repositories"
run_alpine "/sbin/apk update -q"
# rust-src: 部分 crate / build.rs 需要；riscv64 上 rust 仅在 edge
run_alpine "/sbin/apk add --no-cache rust cargo rust-src"

# 不在此用 qemu-user 跑 `rustc -Vv`（scudo 在仿真下易崩）。从 /lib/apk/db/installed 读 rust 的 V: 行。
ALPINE_FULL_VER="$(chroot "$ALPINE_STAGE" /bin/sh -c "grep -A1 '^P:rust$' /lib/apk/db/installed | grep '^V:' | head -1 | sed 's/^V://'")"
# e.g. 1.95.0-r0 → rust-std 用 1.95.0
ALPINE_RUSTC_VER="$(printf '%s\n' "$ALPINE_FULL_VER" | sed 's/-r[0-9]*$//')"
[[ -n "$ALPINE_RUSTC_VER" ]] || { echo "error: could not parse rust V: from apk db (got '$ALPINE_FULL_VER')"; exit 1; }
echo "  Alpine rust installed V:$ALPINE_FULL_VER → rust-std release=$ALPINE_RUSTC_VER"

umount "$ALPINE_STAGE/proc" 2>/dev/null || true
umount -lR "$ALPINE_STAGE/dev" "$ALPINE_STAGE/sys" 2>/dev/null || true

echo "[5b/8] copy Alpine rust + libs into \$MNT/opt/alpine-rust ..."
mkdir -p "$MNT/opt/alpine-rust/lib" "$MNT/opt/alpine-rust/usr/bin" "$MNT/opt/alpine-rust/usr/lib"
shopt -s nullglob
for x in "$ALPINE_STAGE"/lib/ld-musl*.so.1 "$ALPINE_STAGE"/lib/libc.musl*.so.1; do
    [[ -e "$x" ]] && cp -a "$x" "$MNT/opt/alpine-rust/lib/"
done
shopt -u nullglob
cp -a "$ALPINE_STAGE/usr/lib/." "$MNT/opt/alpine-rust/usr/lib/"
# Alpine 里常见 libc.so -> /lib/ld-musl-*.so.1；拷到 Debian 后绝对路径会指到 **glibc** /lib，需改写到本树。
while IFS= read -r -d '' link; do
    t=$(readlink "$link" || true)
    if [[ "$t" == /lib/* ]]; then
        ln -sf "/opt/alpine-rust/lib/${t#/lib/}" "$link"
    fi
done < <(find "$MNT/opt/alpine-rust/usr/lib" -type l -print0 2>/dev/null || true)
while IFS= read -r -d '' link; do
    t=$(readlink "$link" || true)
    if [[ "$t" == /usr/lib/* ]]; then
        ln -sf "/opt/alpine-rust/usr/lib/${t#/usr/lib/}" "$link"
    fi
done < <(find "$MNT/opt/alpine-rust/lib" -type l -print0 2>/dev/null || true)
cp -a "$ALPINE_STAGE/usr/bin/rustc" "$ALPINE_STAGE/usr/bin/cargo" "$MNT/opt/alpine-rust/usr/bin/"
for _b in rust-lld rust-lld-wrapper lld; do
    if [[ -x "$ALPINE_STAGE/usr/bin/$_b" ]]; then
        cp -a "$ALPINE_STAGE/usr/bin/$_b" "$MNT/opt/alpine-rust/usr/bin/"
    fi
done

[[ -n "$(ls "$MNT/opt/alpine-rust/lib"/ld-musl*.so.1 2>/dev/null)" ]] || { echo "error: no /opt/alpine-rust/lib/ld-musl*.so.1"; exit 1; }

STD_VER="${ALPINE_RUSTC_VER}"
STD_TARBALL="rust-std-${STD_VER}-riscv64gc-unknown-none-elf.tar.xz"
STD_URL="https://static.rust-lang.org/dist/${STD_TARBALL}"
echo "[5c/8] install rust-std ($STD_TARBALL) into /opt/alpine-rust/usr ..."
rm -f "$WORK_DIR/$STD_TARBALL"
if ! curl -fL "$STD_URL" -o "$WORK_DIR/$STD_TARBALL" 2>/dev/null; then
    # e.g. release 1.xx.0-nightly → try stable component tarball 1.xx.0
    rm -f "$WORK_DIR/$STD_TARBALL"
    STD_VER="${ALPINE_RUSTC_VER%%-nightly}"
    STD_TARBALL="rust-std-${STD_VER}-riscv64gc-unknown-none-elf.tar.xz"
    STD_URL="https://static.rust-lang.org/dist/${STD_TARBALL}"
    curl -fL "$STD_URL" -o "$WORK_DIR/$STD_TARBALL"
fi
mkdir -p "$WORK_DIR/rust-std-extract"
tar xJf "$WORK_DIR/$STD_TARBALL" -C "$WORK_DIR/rust-std-extract" --strip-components=1
( cd "$WORK_DIR/rust-std-extract" && ./install.sh --prefix="$MNT/opt/alpine-rust/usr" >/dev/null )
rm -rf "$WORK_DIR/rust-std-extract" "$WORK_DIR/$STD_TARBALL"

# Alpine rustc/cargo 的 PT_INTERP 为 /lib/ld-musl-riscv64.so.1（与 glibc 的 ld-linux 文件名不同，可并存）。
# 不要用 patchelf 改解释器：曾观察到在 Starry 访客内触发 stack smashing，疑似破坏 ELF 安全元数据。
echo "[5d/8] install musl dynamic linker into guest /lib (for PT_INTERP) ..."
shopt -s nullglob
for x in "$MNT/opt/alpine-rust/lib"/ld-musl*.so.1 "$MNT/opt/alpine-rust/lib"/libc.musl*.so.1; do
    [[ -e "$x" ]] || continue
    cp -a "$x" "$MNT/lib/$(basename "$x")"
done
shopt -u nullglob

# musl 动态链接器默认不读 glibc 的 ld.so.cache；写入官方支持的搜索路径文件（见 musl ldso）。
mkdir -p "$MNT/etc"
cat > "$MNT/etc/ld-musl-riscv64.path" <<'LDP'
/opt/alpine-rust/lib
/opt/alpine-rust/usr/lib
/lib
/usr/lib
LDP

# 避免与旧版镜像里 glibc rust 混用
rm -f "$MNT/usr/local/bin/rustc" "$MNT/usr/local/bin/cargo" "$MNT/usr/local/bin/rustdoc" \
    "$MNT/usr/local/bin/rust-lld" "$MNT/usr/local/bin/cargo-clippy" 2>/dev/null || true

# 同上：riscv64 二进制在 debian+qemu-user 下可能 SIGABRT；真机验证在 Starry 访客内。
run_in "export LD_LIBRARY_PATH=/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib; \
  /opt/alpine-rust/usr/bin/rustc -V && /opt/alpine-rust/usr/bin/cargo -V" \
  || echo "  warn: skipped chroot rustc/cargo sanity (qemu-user + host toolchain quirk)"

rm -rf "$ALPINE_STAGE"

# --------------------------------------------------------- 6. tgoskits + cargo fetch
echo "[6/8] tgoskits + cargo fetch (pre-populate registry)..."
mkdir -p "$MNT/opt"
if [[ -f "$ROOT/tgoskits/Cargo.toml" ]]; then
    echo "  copying bind-mounted workspace -> /opt/tgoskits (skip git clone; avoids flaky GitHub)"
    rm -rf "$MNT/opt/tgoskits"
    mkdir -p "$MNT/opt/tgoskits"
    (cd "$ROOT/tgoskits" && tar cf - \
        --exclude='./target' \
        --exclude='./.guest-runs' \
        .) | (cd "$MNT/opt/tgoskits" && tar xf -)
    # tar 会带入 .git（含 submodule gitdir 指针）；拷进镜像后指向宿主路径，访客里 git 会误解析甚至触发异常退出链上的栈保护崩溃。
    rm -rf "$MNT/opt/tgoskits/.git"
    echo "  copied; HEAD (from host workspace):"
    (cd "$ROOT/tgoskits" && git log -1 --oneline 2>/dev/null || echo "(no git log)")
else
    echo "  no $ROOT/tgoskits — falling back to git clone"
    run_in "
set -e
cd /opt
[ -d tgoskits ] || git clone --depth 1 -b ${TGOSKITS_BRANCH} ${TGOSKITS_URL}
cd /opt/tgoskits
echo TGOSKITS HEAD: \$(git log -1 --oneline)
"
fi

# 避免按 rust-toolchain.toml 强拉 nightly（与 /opt/alpine-rust 的 rustc 不一致）
rm -f "$MNT/opt/tgoskits/rust-toolchain.toml"

echo "[6b/8] cargo fetch -> /opt/cargo-home (host cargo; riscv64 chroot + qemu-user 下 cargo 常 Scudo SIGABRT)..."
CR_HOME="$(mkdir -p "$MNT/opt/cargo-home" && cd "$MNT/opt/cargo-home" && pwd)"
(
    set -e
    cd "$ROOT/tgoskits"
    [[ -f Cargo.toml ]]
    echo "  workspace HEAD (host):"
    git log -1 --oneline 2>/dev/null || echo "(no git log)"
    CARGO_HOME="$CR_HOME" cargo fetch
)

echo "[6c/8] bake StarryOS .axconfig.toml (host ax-config-gen; 访客内无 riscv64 版 ax-config-gen)..."
PLAT_C="$ROOT/tgoskits/components/axplat_crates/platforms/axplat-riscv64-qemu-virt/axconfig.toml"
STARRY_SRC="$ROOT/tgoskits/os/StarryOS"
STARRY_IMG="$MNT/opt/tgoskits/os/StarryOS"
command -v ax-config-gen >/dev/null 2>&1 || {
    echo "error: ax-config-gen not in PATH (Dockerfile 应安装 cargo-axplat/ax-config-gen)" >&2
    exit 1
}
[[ -f "$PLAT_C" ]] || { echo "error: missing $PLAT_C" >&2; exit 1; }
mkdir -p "$STARRY_IMG"
( cd "$STARRY_SRC" && ax-config-gen "$(pwd)/make/defconfig.toml" "$PLAT_C" \
    -w 'arch="riscv64"' -w 'platform="riscv64-qemu-virt"' \
    -o "$STARRY_IMG/.axconfig.toml" )

# --------------------------------------------------------- 7. inject demo helper
echo "[7/8] inject demo helper /opt/build-starry-kernel.sh ..."
cat > "$MNT/opt/build-starry-kernel.sh" <<'GUESTSH'
#!/bin/bash
# /opt/build-starry-kernel.sh — runs inside the StarryOS guest.
# 使用镜像内 **Alpine musl** rustc/cargo（/opt/alpine-rust）；避免 Debian+glibc 官方 cargo 在 Starry 下栈崩溃。
# 不用 pipefail：部分 bash+glibc 在 Starry 下与 set -o 组合曾触发异常退出链上的栈保护误报。
set -e
# glibc 的 bash/tee/find 等不要从 /opt/alpine-rust/usr/bin 解析；musl cargo 仅由 _run_cargo 注入 PATH+LD_LIBRARY_PATH。
export PATH="/opt/ccwrap:/usr/bin:/usr/sbin:/bin:/sbin:${PATH:-}"
# 全局不要 export Alpine LD_LIBRARY_PATH：本脚本由 glibc bash 解释，混用 musl 库会崩溃。
# 预填 crate 源在 /opt/cargo-home；把 CARGO_HOME 指到 /opt/tgoskits 下新目录并只 symlink 大目录，
# 让 cargo 的 sqlite（.global-cache）落在与 tgoskits 相同的 ext4 子树，避免在部分 lwext4 路径上 SQLITE_FULL。
ORIG_CARGO=/opt/cargo-home
CARGO_HOME_GUEST=/opt/tgoskits/m6-cargo-home
/bin/mkdir -p "$CARGO_HOME_GUEST/registry"
for name in index cache src; do
    if [ -e "$ORIG_CARGO/registry/$name" ] && [ ! -e "$CARGO_HOME_GUEST/registry/$name" ]; then
        ln -sfn "$ORIG_CARGO/registry/$name" "$CARGO_HOME_GUEST/registry/$name"
    fi
done
if [ -d "$ORIG_CARGO/git" ] && [ ! -e "$CARGO_HOME_GUEST/git" ]; then
    ln -sfn "$ORIG_CARGO/git" "$CARGO_HOME_GUEST/git"
fi
export CARGO_HOME="$CARGO_HOME_GUEST"
rm -f "$CARGO_HOME/.global-cache" "$CARGO_HOME/.package-cache" 2>/dev/null || true
# Starry 上 /tmp 常为极小 tmpfs；cargo/sqlite 与 rustc 临时文件必须落在 virtio 盘上。
/bin/mkdir -p /opt/tgoskits/.m6-tmp
export TMPDIR=/opt/tgoskits/.m6-tmp
export TMP=/opt/tgoskits/.m6-tmp
export TEMP=/opt/tgoskits/.m6-tmp
# rustc 常硬编码调用 /usr/bin/cc，绕开 PATH 里的 ccwrap；显式指定 musl 主机链接器为 /opt/ccwrap/cc（清 LD_LIBRARY_PATH）。
export CC="${CC:-/opt/ccwrap/cc}"
export CXX="${CXX:-/opt/ccwrap/c++}"
export CC_riscv64_alpine_linux_musl="${CC_riscv64_alpine_linux_musl:-/opt/ccwrap/cc}"
export CXX_riscv64_alpine_linux_musl="${CXX_riscv64_alpine_linux_musl:-/opt/ccwrap/c++}"
# 主机 musl：collect2 在访客里易 ICE，用 lld；不影响 riscv64gc-unknown-none-elf（另套 target）。
export CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_LINKER=/opt/ccwrap/cc
export CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_RUSTFLAGS="-Clink-arg=-fuse-ld=lld"
# 降低 cargo / rayon 工作线程默认栈不足导致 __stack_chk_fail 的风险
export RUST_MIN_STACK="${RUST_MIN_STACK:-16777216}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-1}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
RUSTC=/opt/alpine-rust/usr/bin/rustc
CARGO=/opt/alpine-rust/usr/bin/cargo
# 不用 stdbuf：其在 glibc 下依赖 LD_PRELOAD(libstdbuf)，在 Starry 访客里会异常退出/被报成 not found。
# 用 tee 把 cargo 输出打到串口 + /tmp，便于宿主侧看 results.txt 体积增长。
# 仅对 musl cargo 进程注入 LD_LIBRARY_PATH（勿污染当前 glibc bash）。
_run_cargo() {
    env PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin" \
        LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib" \
        SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp \
        TMPDIR=/opt/tgoskits/.m6-tmp \
        "$CARGO" "$@"
}

# 快速子集：验证 guest 内 cargo 离线解析/索引可用与关键包可定位，不编整棵 starry-kernel。
# 由宿主 demo 注入 M6_MODE=subset（见 scripts/demo-m6-selfbuild.sh --subset）。
if [ "${M6_MODE:-full}" = "subset" ]; then
    echo "================================================================"
    echo "  StarryOS M6 — guest cargo SUBSET (quick smoke)"
    echo "================================================================"
    echo
    cd /opt/tgoskits
    echo "[subset-0] cargo metadata --offline --no-deps (workspace 根解析)"
    _run_cargo metadata --offline --format-version 1 --no-deps > /tmp/m6-subset-meta.json
    RC0=$?
    echo "metadata exit=$RC0"
    [ "$RC0" -eq 0 ] || exit "$RC0"
    echo "[subset-1] cargo pkgid -p riscv-h (关键包离线定位)"
    set -o pipefail
    _run_cargo pkgid --offline -p riscv-h 2>&1 | tee /tmp/m6-subset-riscv-h.log
    RC1=${PIPESTATUS[0]}
    set +o pipefail
    echo "riscv-h pkgid exit=$RC1"
    [ "$RC1" -eq 0 ] || exit "$RC1"
    echo "[subset-2] cargo pkgid -p ax-cpu (关键包离线定位)"
    set -o pipefail
    _run_cargo pkgid --offline -p ax-cpu 2>&1 | tee /tmp/m6-subset-ax-cpu.log
    RC2=${PIPESTATUS[0]}
    set +o pipefail
    echo "ax-cpu pkgid exit=$RC2"
    [ "$RC2" -eq 0 ] || exit "$RC2"
    echo "[subset-3] cargo pkgid -p ax-errno"
    set -o pipefail
    _run_cargo pkgid --offline -p ax-errno 2>&1 | tee /tmp/m6-subset-axerrno.log
    RC3=${PIPESTATUS[0]}
    set +o pipefail
    echo "ax-errno pkgid exit=$RC3"
    [ "$RC3" -eq 0 ] || exit "$RC3"
    echo
    echo "================================================================"
    echo "===M6-SELFBUILD-SUBSET-PASS==="
    echo "  guest cargo metadata/pkgid offline checks OK"
    echo "================================================================"
    exit 0
fi

echo "================================================================"
echo "  StarryOS Self-Build Demo M6 — guest cargo build starry-kernel"
echo "================================================================"
echo
echo "[0] toolchain sanity:"
# rustc --version 在部分 Starry+QEMU 组合下会在进程收尾阶段触发 __stack_chk_fail；直接进入构建。
echo "rustc binary: $RUSTC (skip --version)"
echo
cd /opt/tgoskits
echo "[1] tgoskits source (HEAD):"
if [ -d /opt/tgoskits/.git ]; then
    /usr/bin/git -C /opt/tgoskits log -1 --oneline 2>/dev/null || echo "(no git log)"
else
    echo "(no .git in image — workspace tarball copy)"
fi
echo

# axplat：平台 toml 在树内；合并后的 .axconfig.toml 由 rootfs 构建阶段在**宿主**生成并拷入镜像。
cd /opt/tgoskits/os/StarryOS
PLAT_CONFIG="/opt/tgoskits/components/axplat_crates/platforms/axplat-riscv64-qemu-virt/axconfig.toml"
if [ ! -f "$PLAT_CONFIG" ]; then
    echo "FATAL: missing $PLAT_CONFIG"
    exit 1
fi
if [ ! -f .axconfig.toml ]; then
    echo "FATAL: missing baked .axconfig.toml under os/StarryOS (re-run tests/selfhost/build-selfbuild-rootfs.sh)"
    exit 1
fi
PLAT_NAME=$(awk -F'"' '$1 ~ /^platform[[:space:]]*=/ {print $2}' "$PLAT_CONFIG" | head -1)
if [ -z "$PLAT_NAME" ]; then
    PLAT_NAME="riscv64-qemu-virt"
fi
echo "PLAT_CONFIG=$PLAT_CONFIG PLAT_NAME=$PLAT_NAME (baked .axconfig.toml)"

export AX_ARCH=riscv64
export AX_PLATFORM="$PLAT_NAME"
export AX_MODE=release
export AX_LOG=warn
export AX_TARGET=riscv64gc-unknown-none-elf
export AX_IP=10.0.2.15
export AX_GW=10.0.2.2
export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"

cd /opt/tgoskits

echo "[2] cargo build -p starry-kernel (lib)"
set -o pipefail
_run_cargo build -v --offline -p starry-kernel \
    --target riscv64gc-unknown-none-elf --release 2>&1 | tee /tmp/m6-cargo-kernel.log
RC=${PIPESTATUS[0]}
set +o pipefail
echo "starry-kernel-build exit=$RC"
if [ "$RC" -ne 0 ]; then
    exit "$RC"
fi
LIB=$(find target/riscv64gc-unknown-none-elf/release -name "libstarry_kernel*.rlib" | head -1)
echo "produced: $(ls -lh "$LIB" 2>&1 | head)"
echo

echo "[3] pass1 starryos (generate linker_${PLAT_NAME}.lds)"
set -o pipefail
_run_cargo build -v --offline -p starryos \
    --target riscv64gc-unknown-none-elf --release \
    --features starryos/qemu 2>&1 | tee /tmp/m6-cargo-pass1.log
RC1=${PIPESTATUS[0]}
set +o pipefail
echo "starryos pass1 exit=$RC1"
LD="target/riscv64gc-unknown-none-elf/release/linker_${PLAT_NAME}.lds"
if [ ! -f "$LD" ]; then
    echo "pass1 did not create $LD — reporting lib-only progress"
    echo "===M6-SELFBUILD-LIB-PASS==="
    exit 0
fi

echo "[4] pass2 starryos (final ELF)"
set -o pipefail
RUSTFLAGS="-C link-arg=-T$(pwd)/$LD -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
    _run_cargo build -v --offline -p starryos \
    --target riscv64gc-unknown-none-elf --release \
    --features starryos/qemu 2>&1 | tee /tmp/m6-cargo-pass2.log
RC2=${PIPESTATUS[0]}
set +o pipefail
echo "starryos pass2 exit=$RC2"

ELF=target/riscv64gc-unknown-none-elf/release/starryos
if [ -f "$ELF" ]; then
    ls -lh "$ELF"
    file "$ELF" | head -1
    echo
    echo "================================================================"
    echo "===M6-SELFBUILD-PASS==="
    echo "  starry kernel ELF was just produced INSIDE the starry guest!"
    echo "================================================================"
elif [ "$RC2" -eq 0 ]; then
    echo "===M6-SELFBUILD-LIB-PASS==="
else
    exit "$RC2"
fi
GUESTSH
chmod +x "$MNT/opt/build-starry-kernel.sh"

# --------------------------------------------------------- 8. finalise
echo "[8/8] cleanup, finalising image..."
run_in "rm -rf /var/cache/apt/archives /var/lib/apt/lists/* /tmp/* /opt/rust-extract" 2>/dev/null || true
df -h "$MNT" | tail -1

# Convert disk.raw → standalone ext4 image (skip the GPT, just the rootfs)
sync
cleanup
trap - EXIT

echo "[+] extracting partition 1 → $OUT_IMG"
mkdir -p "$(dirname "$OUT_IMG")"
PART_SIZE=$(( $(stat -c %s "$DISK_RAW") - OFFSET ))
dd if="$DISK_RAW" of="$OUT_IMG" bs=4M skip=$((OFFSET / 4194304)) status=none
ls -lh "$OUT_IMG"

# Debian trixie defaults enable orphan_file / metadata_csum_seed; lwext4 in StarryOS
# cannot mount those — strip so the guest rootfs is Starry-compatible.
echo "[+] tune2fs: disable orphan_file (lwext4 / StarryOS compat)..."
e2fsck -fy "$OUT_IMG" >/dev/null
tune2fs -O ^orphan_file,^metadata_csum_seed "$OUT_IMG"
e2fsck -fy "$OUT_IMG" >/dev/null

echo "[+] xz compress (this may take a while)..."
rm -f "$OUT_IMG.xz"
xz -k -T0 -9 "$OUT_IMG"
ls -lh "$OUT_IMG" "$OUT_IMG.xz"
sha256sum "$OUT_IMG" > "$OUT_IMG.sha256"
sha256sum "$OUT_IMG.xz" > "$OUT_IMG.xz.sha256"

echo
echo "================================================================"
echo "  ✓ selfbuild rootfs ready"
echo "  raw : $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
echo "  xz  : $OUT_IMG.xz ($(du -h "$OUT_IMG.xz" | cut -f1))"
echo "================================================================"
