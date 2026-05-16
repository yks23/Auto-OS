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
TGOSKITS_BRANCH="selfhost"
# Alpine minirootfs（与 build-selfhost-rootfs.sh 一致）；rust/cargo 来自 edge apk
ALPINE_DOT="3.21.0"
ALPINE_REL="v3.21"
ALPINE_BASE_URL="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_REL}/releases/riscv64"
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_DOT}-riscv64.tar.gz"
TGOSKITS_URL="https://github.com/yks23/tgoskits.git"

OUT_IMG="$ROOT/tests/selfhost/rootfs-selfbuild-${ARCH}.img"
WORK_DIR="${WORK_DIR:-$ROOT/.cache/rootfs-build}"
DISK_SIZE_GB="${DISK_SIZE_GB:-20}"
# xz 压缩等级：默认 6（比 -9 快 3–5x，大小差异 <5%）；需要最小体积时设 XZ_LEVEL=9。
XZ_LEVEL="${XZ_LEVEL:-6}"
# 与 scripts/build.sh / demo-m6-selfbuild 默认一致：多核 SMP + 更大物理内存（访客内多 rustc）。
M6_MAX_CPU_NUM="${M6_MAX_CPU_NUM:-4}"
M6_PHYS_MEM="${M6_PHYS_MEMORY_SIZE:-0x100000000}" # 4GiB，与 starry-kernel page-alloc-4g 上限一致

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

# 增量重建：若 BASE_CACHE 指向一个已 "apt install 完" 的 ext4 镜像，
# 可跳过步骤 1–4（下载 + 解压 + apt + ccwrap）。用 -DROOTFS_BASE_CACHE=/path/to/cache.img 或
# 设环境变量；跳过时仍重新执行 5–8（Alpine rust + tgoskits + inject + finalise）。
BASE_CACHE="${ROOTFS_BASE_CACHE:-}"
if [[ -n "$BASE_CACHE" && -f "$BASE_CACHE" ]]; then
    echo "[cache] restoring base rootfs from $BASE_CACHE (skipping steps 1–4)..."
    DISK_RAW="$WORK_DIR/disk.raw"
    cp "$BASE_CACHE" "$DISK_RAW"
    # resize in case the cached image is smaller
    truncate -s "${DISK_SIZE_GB}G" "$DISK_RAW" 2>/dev/null || true
    LOOP=$(losetup -fP --show "$DISK_RAW")
    e2fsck -fy "$LOOP" >/dev/null 2>&1 || true
    resize2fs "$LOOP" >/dev/null 2>&1 || true
    MNT="$WORK_DIR/mnt"
    mkdir -p "$MNT"
    mount "$LOOP" "$MNT"
    cleanup() {
        sync
        umount -lR "$MNT/proc" "$MNT/dev" "$MNT/sys" "$MNT" 2>/dev/null || true
        losetup -d "$LOOP" 2>/dev/null || true
    }
    trap cleanup EXIT
    cp /usr/bin/qemu-riscv64-static "$MNT/usr/bin/" 2>/dev/null || true
    rm -f "$MNT/etc/resolv.conf"
    cp /etc/resolv.conf "$MNT/etc/resolv.conf"
    mount -t proc /proc "$MNT/proc"
    mount --rbind /dev "$MNT/dev"
    mount --rbind /sys "$MNT/sys"
    run_in() { chroot "$MNT" /bin/bash -c "$*"; }
    echo "[cache] base restored, continuing from step 5..."
    # jump to step 5
    SKIP_STEPS_1_TO_4=1
fi

# --------------------------------------------------------- 1. download base
SKIP_STEPS_1_TO_4="${SKIP_STEPS_1_TO_4:-}"
if [[ -z "$SKIP_STEPS_1_TO_4" ]]; then
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
fi # end SKIP_STEPS_1_TO_4 guard

# 保存 base cache（apt + ccwrap 完成后的 rootfs），供后续增量重建跳过步骤 1–4。
BASE_CACHE_SAVE="${ROOTFS_BASE_CACHE_SAVE:-$WORK_DIR/base-apt-done.img}"
if [[ ! -f "$BASE_CACHE_SAVE" ]]; then
    echo "[cache] saving base rootfs cache -> $BASE_CACHE_SAVE ..."
    sync
    dd if="$DISK_RAW" of="$BASE_CACHE_SAVE" bs=4M skip=$((OFFSET / 4194304)) status=none
    echo "[cache] base cache saved ($(du -h "$BASE_CACHE_SAVE" | cut -f1))"
fi

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
if [[ ! -f "$WORK_DIR/$STD_TARBALL" ]]; then
    if ! curl -fL "$STD_URL" -o "$WORK_DIR/$STD_TARBALL" 2>/dev/null; then
        # e.g. release 1.xx.0-nightly → try stable component tarball 1.xx.0
        rm -f "$WORK_DIR/$STD_TARBALL"
        STD_VER="${ALPINE_RUSTC_VER%%-nightly}"
        STD_TARBALL="rust-std-${STD_VER}-riscv64gc-unknown-none-elf.tar.xz"
        STD_URL="https://static.rust-lang.org/dist/${STD_TARBALL}"
        curl -fL "$STD_URL" -o "$WORK_DIR/$STD_TARBALL"
    fi
fi
mkdir -p "$WORK_DIR/rust-std-extract"
tar xJf "$WORK_DIR/$STD_TARBALL" -C "$WORK_DIR/rust-std-extract" --strip-components=1
( cd "$WORK_DIR/rust-std-extract" && ./install.sh --prefix="$MNT/opt/alpine-rust/usr" >/dev/null )
rm -rf "$WORK_DIR/rust-std-extract"

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
_DEFCONFIG=""
_TGOSKITS="$ROOT/tgoskits"
for _dc in "$_TGOSKITS/os/arceos/configs/defconfig.toml" "$STARRY_SRC/make/defconfig.toml"; do
    [[ -f "$_dc" ]] && { _DEFCONFIG="$_dc"; break; }
done
[[ -n "$_DEFCONFIG" ]] || { echo "error: defconfig.toml not found" >&2; exit 1; }
( cd "$STARRY_SRC" && ax-config-gen "$_DEFCONFIG" "$PLAT_C" \
    -w 'arch="riscv64"' -w 'platform="riscv64-qemu-virt"' \
    -w "plat.max-cpu-num=${M6_MAX_CPU_NUM}" \
    -w "plat.phys-memory-size=${M6_PHYS_MEM}" \
    -o "$STARRY_IMG/.axconfig.toml" )

# --------------------------------------------------------- 7. inject demo helper
echo "[7/8] inject demo helper /opt/build-starry-kernel.sh ..."
cat > "$MNT/opt/build-starry-kernel.sh" <<'GUESTSH'
#!/bin/bash
# /opt/build-starry-kernel.sh — runs inside the StarryOS guest.
# 使用镜像内 **Alpine musl** rustc/cargo（/opt/alpine-rust）；避免 Debian+glibc 官方 cargo 在 Starry 下栈崩溃。
# 不用 pipefail：部分 bash+glibc 在 Starry 下与 set -o 组合曾触发异常退出链上的栈保护误报。
set -e
# 串口诊断：阶段 + UTC 时间戳；长步骤间可设 M6_GUEST_HEARTBEAT_SEC（默认 120）周期性心跳。
m6_ts() { echo "[M6 $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
# 串口输出 /proc/syscall_stats 供宿主 m6-selfbuild-progress-http.py 解析增量。
# 此为 **Starry 访客内核内** 的真实计数；不得以宿主 strace 或假日志冒烟代替。
# 旧内核无该文件时静默跳过。默认整文件 cat；若 >200KiB 则只取前 300 行以免串口洪泛。
# M6_SYSCALL_STATS_INTERVAL_SEC — 长 cargo 阶段后台周期性 dump 的间隔秒数（默认 10）；无效值回落 10；最小 1。
m6_dump_syscall_stats() {
    if [ -r /proc/syscall_stats ]; then
        echo "===SYSCALL_STATS_BEGIN==="
        _sz=$(wc -c </proc/syscall_stats 2>/dev/null | tr -d '[:space:]' || echo 0)
        case ${_sz:-0} in
        '' | *[!0-9]*) _sz=0 ;;
        esac
        if [ "${_sz:-0}" -gt 204800 ]; then
            echo "m6_dump_syscall_stats: truncating to first 300 lines (size ${_sz} bytes > 200KiB)"
            head -n 300 /proc/syscall_stats
        else
            cat /proc/syscall_stats
        fi
        echo "===SYSCALL_STATS_END==="
    fi
}
# 与 m6_hb_* 类似：在 starry-kernel / pass1 / pass2 等长 cargo 阶段周期性调用 m6_dump_syscall_stats。
m6_syscall_stats_watch_start() {
    rm -f /tmp/m6-syscall-watch.pid
    (
        _iv="${M6_SYSCALL_STATS_INTERVAL_SEC:-10}"
        case ${_iv} in
        '' | *[!0-9]*) _iv=10 ;;
        esac
        if [ "${_iv}" -lt 1 ]; then _iv=1; fi
        while sleep "${_iv}"; do
            m6_dump_syscall_stats
        done
    ) &
    echo $! >/tmp/m6-syscall-watch.pid
}
m6_syscall_stats_watch_stop() {
    if [ -f /tmp/m6-syscall-watch.pid ]; then
        kill "$(cat /tmp/m6-syscall-watch.pid)" 2>/dev/null || true
        rm -f /tmp/m6-syscall-watch.pid
    fi
}
m6_hb_start() {
    rm -f /tmp/m6-hb.pid
    (
        while sleep "${M6_GUEST_HEARTBEAT_SEC:-120}"; do
            m6_ts "heartbeat phase=${M6_PHASE:-?} (rustc/cargo may print nothing for a long time)"
        done
    ) &
    echo $! >/tmp/m6-hb.pid
}
m6_hb_stop() {
    if [ -f /tmp/m6-hb.pid ]; then
        kill "$(cat /tmp/m6-hb.pid)" 2>/dev/null || true
        rm -f /tmp/m6-hb.pid
    fi
}
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
# 降低 rustc 默认栈过小导致 __stack_chk_fail 的风险；并行度默认随访客 CPU 数（QEMU -smp）。
export RUST_MIN_STACK="${RUST_MIN_STACK:-16777216}"
_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)"
if [[ "${_NPROC}" -lt 1 ]]; then _NPROC=1; fi
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-$_NPROC}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_NPROC}"
# 详细编译信号（宿主可通过 demo 注入覆盖）：
#   M6_RUSTFLAGS_COMMON — 默认带 DWARF（等价 gcc -g），便于 rustc 卡住时 objdump/llvm-objcopy 仍可符号化；
#   M6_CARGO_VV=1 — cargo -vv（每道 rustc 命令行全量打印）；=0 则仅用 -v 缩短日志。
#   CARGO_TERM_PROGRESS — wide 在串口上更易看出「仍在跑」。
export CARGO_TERM_PROGRESS="${CARGO_TERM_PROGRESS:-wide}"
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-true}"
export CARGO_INCREMENTAL=0
M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON:--C debuginfo=2}"
M6_CARGO_VV="${M6_CARGO_VV:-1}"
if [ "$M6_CARGO_VV" = "1" ]; then _CARGO_V="-vv"; else _CARGO_V="-v"; fi
RUSTC=/opt/ccwrap/rustc
CARGO=/opt/alpine-rust/usr/bin/cargo
# Strip rust-src workspace for -Z build-std (remove std/test members to avoid crates.io deps)
_strip_buildstd_ws() {
  [[ -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]] || return 0
  cp -f "${_RUSTLIB_SRC}/library/Cargo.toml" "${_RUSTLIB_SRC}/library/Cargo.toml.orig" 2>/dev/null || true
  cat > "${_RUSTLIB_SRC}/library/Cargo.toml" << 'MINI_WS'
cargo-features = ["profile-rustflags"]
[workspace]
resolver = "1"
members = ["sysroot"]
exclude = ["stdarch", "windows_link"]
[profile.release.package.compiler_builtins]
codegen-units = 10000
MINI_WS
  cp -f "${_RUSTLIB_SRC}/library/sysroot/Cargo.toml" "${_RUSTLIB_SRC}/library/sysroot/Cargo.toml.orig" 2>/dev/null || true
  cat > "${_RUSTLIB_SRC}/library/sysroot/Cargo.toml" << 'MINI_SYSROOT'
cargo-features = ["public-dependency"]
[package]
name = "sysroot"
version = "0.0.0"
edition = "2024"
[lib]
test = false
bench = false
doc = false
[dependencies]
core = { path = "../core", public = true }
alloc = { path = "../alloc", public = true }
compiler_builtins = { path = "../compiler-builtins/compiler-builtins" }
[features]
default = ["panic-unwind"]
backtrace = []
panic-unwind = []
panic-abort = []
compiler-builtins-c = []
compiler-builtins-mem = []
MINI_SYSROOT
  cat > "${_RUSTLIB_SRC}/library/Cargo.lock" << 'BUILDSTD_LOCK'
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 3

[[package]]
name = "alloc"
version = "0.0.0"
dependencies = ["compiler_builtins", "core"]

[[package]]
name = "compiler_builtins"
version = "0.1.160"
dependencies = ["core"]

[[package]]
name = "core"
version = "0.0.0"

[[package]]
name = "sysroot"
version = "0.0.0"
dependencies = ["alloc", "compiler_builtins", "core"]
BUILDSTD_LOCK
}
# ── Ensure rust-src is available for -Z build-std (bare-metal target) ──
_SYSROOT="$("$RUSTC" --print sysroot 2>/dev/null || echo "/opt/alpine-rust/usr")"
_RUSTLIB_SRC="${_SYSROOT}/lib/rustlib/src/rust"
if [[ ! -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]]; then
  echo "[M6] rust-src missing; extracting..."
  rm -rf "${_RUSTLIB_SRC}" 2>/dev/null || true
  mkdir -p "$(dirname "${_RUSTLIB_SRC}")" 2>/dev/null || true
  if [[ -f "/opt/rust-src-for-rootfs.tar.gz" ]]; then
    (cd "$(dirname "${_RUSTLIB_SRC}")" && tar xzf /opt/rust-src-for-rootfs.tar.gz)
    if [[ -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]]; then
      echo "[M6] rust-src extracted OK"
      _strip_buildstd_ws
    else
      echo "[M6] warn: rust-src extraction failed"
    fi
  else
    echo "[M6] warn: /opt/rust-src-for-rootfs.tar.gz not found; -Z build-std may fail"
  fi
elif [[ -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]]; then
  _strip_buildstd_ws
fi
_BS_FLAG="-Z build-std=core,alloc,compiler_builtins"
# 不用 stdbuf：其在 glibc 下依赖 LD_PRELOAD(libstdbuf)，在 Starry 访客里会异常退出/被报成 not found。
# 用 tee 把 cargo 输出打到串口 + /tmp，便于宿主侧看 results.txt 体积增长。
# **cargo 对匿名 pipe 常全缓冲**：可选 `M6_CARGO_PTY=1` 用 script(1) 分配伪终端以刷日志。
# 默认 **关闭**：在 Starry 访客 + musl cargo 下曾触发 axtask「atomic context sleep」panic（见 wait_queue.rs）。
# **断点续编**：`M6_RESUME=1` 时若 virtio 盘上已有阶段产物或 `.m6-done-*` 标记，则跳过已完成阶段（见下方）。
# 仅对 musl cargo 进程注入 LD_LIBRARY_PATH（勿污染当前 glibc bash）。
_run_cargo() {
    if [ "${M6_CARGO_PTY:-0}" = "1" ] && command -v script >/dev/null 2>&1; then
        _M6_CARGO_Q=$(printf ' %q' "$@")
        script -qefc "/usr/bin/env RUSTC_BOOTSTRAP=1 PATH=\"/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin\" LD_LIBRARY_PATH=\"/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib\" SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp TMPDIR=/opt/tgoskits/.m6-tmp /opt/alpine-rust/usr/bin/cargo${_M6_CARGO_Q}" /dev/null
    else
        env RUSTC_BOOTSTRAP=1 PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin" \
            LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib" \
            SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp \
            TMPDIR=/opt/tgoskits/.m6-tmp \
            "$CARGO" "$@"
    fi
}

# 快速子集：验证 guest 内 cargo 离线解析/索引可用与关键包可定位，不编整棵 starry-kernel。
# 由宿主 demo 注入 M6_MODE=subset（见 scripts/demo-m6-selfbuild.sh --subset）。
if [ "${M6_MODE:-full}" = "subset" ]; then
    echo "================================================================"
    echo "  StarryOS M6 — guest cargo SUBSET (quick smoke)"
    echo "================================================================"
    echo
    m6_ts "subset begin"
    cd /opt/tgoskits
    m6_ts "[subset-0] start cargo metadata --offline --no-deps"
    echo "[subset-0] cargo metadata --offline --no-deps (workspace 根解析)"
    _run_cargo metadata --offline --format-version 1 --no-deps > /tmp/m6-subset-meta.json
    RC0=$?
    m6_ts "metadata exit=$RC0"
    echo "metadata exit=$RC0"
    [ "$RC0" -eq 0 ] || exit "$RC0"
    m6_ts "[subset-1] start cargo pkgid -p riscv-h"
    echo "[subset-1] cargo pkgid -p riscv-h (关键包离线定位)"
    set -o pipefail
    _run_cargo pkgid --offline -p riscv-h 2>&1 | tee /tmp/m6-subset-riscv-h.log
    RC1=${PIPESTATUS[0]}
    set +o pipefail
    m6_ts "riscv-h pkgid exit=$RC1"
    echo "riscv-h pkgid exit=$RC1"
    [ "$RC1" -eq 0 ] || exit "$RC1"
    m6_ts "[subset-2] start cargo pkgid -p ax-cpu"
    echo "[subset-2] cargo pkgid -p ax-cpu (关键包离线定位)"
    set -o pipefail
    _run_cargo pkgid --offline -p ax-cpu 2>&1 | tee /tmp/m6-subset-ax-cpu.log
    RC2=${PIPESTATUS[0]}
    set +o pipefail
    m6_ts "ax-cpu pkgid exit=$RC2"
    echo "ax-cpu pkgid exit=$RC2"
    [ "$RC2" -eq 0 ] || exit "$RC2"
    m6_ts "[subset-3] start cargo pkgid -p ax-errno"
    echo "[subset-3] cargo pkgid -p ax-errno"
    set -o pipefail
    _run_cargo pkgid --offline -p ax-errno 2>&1 | tee /tmp/m6-subset-axerrno.log
    RC3=${PIPESTATUS[0]}
    set +o pipefail
    m6_ts "ax-errno pkgid exit=$RC3"
    echo "ax-errno pkgid exit=$RC3"
    [ "$RC3" -eq 0 ] || exit "$RC3"
    m6_ts "subset all steps OK"
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
m6_ts "full M6 selfbuild: toolchain + cargo phases (heartbeats every ${M6_GUEST_HEARTBEAT_SEC:-120}s during compile)"
echo "[0] toolchain sanity:"
# rustc --version 在部分 Starry+QEMU 组合下会在进程收尾阶段触发 __stack_chk_fail；直接进入构建。
echo "rustc binary: $RUSTC (skip --version)"
echo
cd /opt/tgoskits
m6_ts "[1] inspect tgoskits tree"
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
m6_ts "AX_* exported AX_TARGET=$AX_TARGET AX_PLATFORM=$AX_PLATFORM"

cd /opt/tgoskits

m6_ts "parallelism: CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS RAYON_NUM_THREADS=$RAYON_NUM_THREADS (override via env)"

# ---------- M6_RESUME：同一 rootfs 镜像上多次 QEMU，利用 cargo incremental ----------
# 宿主 demo 注入 M6_RESUME=1（默认 0）；若盘上已有产物则跳过已完成阶段（需上次运行已把 target/ 写入 virtio 盘）。
# 成功阶段结束时会 touch /opt/tgoskits/.m6-done-kernel-lib | .m6-done-pass1 | .m6-done-pass2；续跑时亦认产物（rlib / linker_*.lds）。
M6_RESUME="${M6_RESUME:-0}"
M6_DONE_K="/opt/tgoskits/.m6-done-kernel-lib"
M6_DONE_P1="/opt/tgoskits/.m6-done-pass1"
M6_DONE_P2="/opt/tgoskits/.m6-done-pass2"
LD="target/riscv64gc-unknown-none-elf/release/linker_${PLAT_NAME}.lds"
ELF="target/riscv64gc-unknown-none-elf/release/starryos"
RESUME_SKIP_KERNEL=0
RESUME_SKIP_PASS1=0
if [ "$M6_RESUME" = "1" ]; then
    m6_ts "M6_RESUME=1: scan target/ + .m6-done-* under /opt/tgoskits"
    if [ -f "$ELF" ]; then
        touch "$M6_DONE_P2" 2>/dev/null || true
        m6_ts "found $ELF — build already complete"
        ls -lh "$ELF" 2>&1 | head -2
        file "$ELF" 2>/dev/null | head -1 || true
        echo "================================================================"
        echo "===M6-SELFBUILD-PASS==="
        echo "  (resume: ELF already on virtio disk)"
        echo "================================================================"
        exit 0
    fi
    if [ -f "$LD" ]; then
        m6_ts "found $LD — skip [2][3], run [4] pass2 only"
        RESUME_SKIP_KERNEL=1
        RESUME_SKIP_PASS1=1
    elif [ -f "$M6_DONE_P1" ]; then
        m6_ts "resume: $M6_DONE_P1 without $LD — stale marker, will re-run from [3]"
    fi
    if [ "$RESUME_SKIP_KERNEL" != "1" ]; then
        LIB0=$(find target/riscv64gc-unknown-none-elf/release -maxdepth 3 -name "libstarry_kernel*.rlib" 2>/dev/null | head -1 || true)
        if [ -n "$LIB0" ] && [ -f "$LIB0" ]; then
            m6_ts "found kernel rlib — skip [2], run [3][4]"
            RESUME_SKIP_KERNEL=1
        elif [ -f "$M6_DONE_K" ]; then
            LIB0=$(find target/riscv64gc-unknown-none-elf/release -maxdepth 3 -name "libstarry_kernel*.rlib" 2>/dev/null | head -1 || true)
            if [ -n "$LIB0" ] && [ -f "$LIB0" ]; then
                m6_ts "resume: $M6_DONE_K + rlib — skip [2]"
                RESUME_SKIP_KERNEL=1
            else
                m6_ts "resume: $M6_DONE_K but no libstarry_kernel*.rlib — re-run [2]"
            fi
        fi
    fi
fi

m6_dump_syscall_stats

# 与宿主 scripts/build.sh 对齐：仅当树内 starry-kernel 声明了 smp feature 时才传 --features smp（旧 rootfs tarball 无此行时会失败）。
SK_KERNEL_FEAT=""
if grep -qE '^[[:space:]]*smp[[:space:]]*=' /opt/tgoskits/os/StarryOS/kernel/Cargo.toml 2>/dev/null; then
    SK_KERNEL_FEAT="--features smp"
    echo "[2] starry-kernel: enabling workspace feature smp (matches baked axconfig SMP)"
else
    echo "[2] starry-kernel: no 'smp' feature in Cargo.toml — building without --features smp (legacy rootfs)"
fi

RC=0
RC1=0
if [ "$RESUME_SKIP_KERNEL" != "1" ]; then
    m6_ts "[2] start cargo build -p starry-kernel (lib) — may run for a long time with no crate output"
    echo "[2] cargo build $_CARGO_V --offline -p starry-kernel (lib) $SK_KERNEL_FEAT RUSTFLAGS+=$M6_RUSTFLAGS_COMMON"
    export M6_PHASE=starry-kernel-lib
    export RUSTFLAGS="$M6_RUSTFLAGS_COMMON ${RUSTFLAGS:-}"
    m6_hb_start
    m6_syscall_stats_watch_start
    set -o pipefail
    _run_cargo build $_CARGO_V --offline -p starry-kernel \
        $SK_KERNEL_FEAT \
        --target riscv64gc-unknown-none-elf --release ${_BS_FLAG} 2>&1 | tee /tmp/m6-cargo-kernel.log
    RC=${PIPESTATUS[0]}
    set +o pipefail
    m6_syscall_stats_watch_stop
    m6_hb_stop
    m6_ts "[2] starry-kernel lib finished rc=$RC"
    echo "starry-kernel-build exit=$RC"
    if [ "$RC" -ne 0 ]; then
        exit "$RC"
    fi
    touch "$M6_DONE_K"
else
    m6_ts "[2] skipped (M6_RESUME: kernel stage already done or linker-only resume)"
    touch "$M6_DONE_K" 2>/dev/null || true
fi

LIB=$(find target/riscv64gc-unknown-none-elf/release -maxdepth 3 -name "libstarry_kernel*.rlib" 2>/dev/null | head -1 || true)
if [ -n "$LIB" ] && [ -f "$LIB" ]; then
    echo "produced rlib: $(ls -lh "$LIB" 2>&1 | head -1)"
else
    echo "produced rlib: (none — linker-only resume or clean tree)"
fi
echo

m6_dump_syscall_stats

if [ "$RESUME_SKIP_PASS1" != "1" ]; then
    m6_ts "[3] start pass1 starryos (generate linker_${PLAT_NAME}.lds)"
    echo "[3] pass1 starryos $_CARGO_V RUSTFLAGS+=$M6_RUSTFLAGS_COMMON"
    export M6_PHASE=starryos-pass1
    export RUSTFLAGS="$M6_RUSTFLAGS_COMMON ${RUSTFLAGS:-}"
    m6_hb_start
    m6_syscall_stats_watch_start
    set -o pipefail
    _run_cargo build $_CARGO_V --offline -p starryos \
        --target riscv64gc-unknown-none-elf --release \
        --features starryos/qemu,smp ${_BS_FLAG} 2>&1 | tee /tmp/m6-cargo-pass1.log
    RC1=${PIPESTATUS[0]}
    set +o pipefail
    m6_syscall_stats_watch_stop
    m6_hb_stop
    m6_ts "[3] starryos pass1 finished rc=$RC1"
    echo "starryos pass1 exit=$RC1"
    if [ "$RC1" -ne 0 ]; then
        exit "$RC1"
    fi
    if [ ! -f "$LD" ]; then
        echo "pass1 did not create $LD — reporting lib-only progress"
        echo "===M6-SELFBUILD-LIB-PASS==="
        exit 0
    fi
    touch "$M6_DONE_P1"
else
    m6_ts "[3] skipped (M6_RESUME: linker script already on disk)"
    if [ ! -f "$LD" ]; then
        echo "FATAL: resume expected $LD but missing"
        exit 2
    fi
    touch "$M6_DONE_P1" 2>/dev/null || true
fi

m6_dump_syscall_stats

m6_ts "[4] start pass2 starryos (final ELF link)"
echo "[4] pass2 starryos $_CARGO_V (RUSTFLAGS: debuginfo + linker script)"
export M6_PHASE=starryos-pass2
m6_hb_start
m6_syscall_stats_watch_start
set -o pipefail
export RUSTFLAGS="$M6_RUSTFLAGS_COMMON -C link-arg=-T$(pwd)/$LD -C link-arg=-no-pie -C link-arg=-znostart-stop-gc"
_run_cargo build $_CARGO_V --offline -p starryos \
    --target riscv64gc-unknown-none-elf --release \
    --features starryos/qemu,smp ${_BS_FLAG} 2>&1 | tee /tmp/m6-cargo-pass2.log
RC2=${PIPESTATUS[0]}
set +o pipefail
m6_syscall_stats_watch_stop
m6_hb_stop
m6_ts "[4] starryos pass2 finished rc=$RC2"
echo "starryos pass2 exit=$RC2"
if [ -f "$ELF" ]; then
    touch "$M6_DONE_P2"
    ls -lh "$ELF"
    file "$ELF" | head -1
    echo
    m6_dump_syscall_stats
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
xz -k -T0 -"$XZ_LEVEL" "$OUT_IMG"
ls -lh "$OUT_IMG" "$OUT_IMG.xz"
sha256sum "$OUT_IMG" > "$OUT_IMG.sha256"
sha256sum "$OUT_IMG.xz" > "$OUT_IMG.xz.sha256"

echo
echo "================================================================"
echo "  ✓ selfbuild rootfs ready"
echo "  raw : $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
echo "  xz  : $OUT_IMG.xz ($(du -h "$OUT_IMG.xz" | cut -f1))"
echo "================================================================"
