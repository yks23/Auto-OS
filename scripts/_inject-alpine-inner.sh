#!/bin/bash
# Inner script for Alpine musl injection - runs inside Docker container.
set -euo pipefail

ROOTFS="$1"
MNT="/tmp/inject-mnt-$$"
mkdir -p "$MNT"
mount -o loop,rw "$ROOTFS" "$MNT"

# Check if already installed
if [[ -x "$MNT/opt/alpine-rust/usr/bin/cargo" ]]; then
  echo "[inject] Alpine musl cargo already installed"
  umount "$MNT"
  exit 0
fi

ALPINE_DOT="3.21.0"
ALPINE_REL="v3.21"
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_DOT}-riscv64.tar.gz"
ALPINE_BASE_URL="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_REL}/releases/riscv64"

echo "[inject] downloading Alpine minirootfs..."
ALPINE_TGZ="/tmp/$ALPINE_TARBALL"
if [[ ! -f "$ALPINE_TGZ" ]]; then
  curl -fL -o "$ALPINE_TGZ" "${ALPINE_BASE_URL}/${ALPINE_TARBALL}"
fi
ls -lh "$ALPINE_TGZ"

echo "[inject] extracting Alpine stage..."
ALPINE_STAGE="$(mktemp -d /tmp/alpine-rust-stage.XXXXXX)"
tar xzf "$ALPINE_TGZ" -C "$ALPINE_STAGE" --no-same-owner --no-same-permissions
cp /usr/bin/qemu-riscv64-static "$ALPINE_STAGE/usr/bin/"
cp /etc/resolv.conf "$ALPINE_STAGE/etc/resolv.conf"
mount -t proc /proc "$ALPINE_STAGE/proc"
mount --rbind /dev "$ALPINE_STAGE/dev"
mount --rbind /sys "$ALPINE_STAGE/sys"

run_alpine() { chroot "$ALPINE_STAGE" /bin/sh -c "$*"; }

echo "[inject] installing rust/cargo via apk..."
run_alpine "echo https://dl-cdn.alpinelinux.org/alpine/edge/main >> /etc/apk/repositories"
run_alpine "echo https://dl-cdn.alpinelinux.org/alpine/edge/community >> /etc/apk/repositories"
run_alpine "/sbin/apk update"
run_alpine "/sbin/apk add --no-cache rust cargo rust-src"

ALPINE_FULL_VER="$(chroot "$ALPINE_STAGE" /bin/sh -c "grep -A1 '^P:rust$' /lib/apk/db/installed | grep '^V:' | head -1 | sed 's/^V://'")"
ALPINE_RUSTC_VER="$(printf '%s\n' "$ALPINE_FULL_VER" | sed 's/-r[0-9]*$//')"
echo "[inject] Alpine rust V:$ALPINE_FULL_VER -> rust-std=$ALPINE_RUSTC_VER"

umount "$ALPINE_STAGE/proc" 2>/dev/null || true
umount -lR "$ALPINE_STAGE/dev" "$ALPINE_STAGE/sys" 2>/dev/null || true

echo "[inject] copying Alpine rust to /opt/alpine-rust..."
mkdir -p "$MNT/opt/alpine-rust/lib" "$MNT/opt/alpine-rust/usr/bin" "$MNT/opt/alpine-rust/usr/lib"

for x in "$ALPINE_STAGE"/lib/ld-musl*.so.1 "$ALPINE_STAGE"/lib/libc.musl*.so.1; do
  [[ -e "$x" ]] && cp -a "$x" "$MNT/opt/alpine-rust/lib/"
done

cp -a "$ALPINE_STAGE/usr/lib/." "$MNT/opt/alpine-rust/usr/lib/"

while IFS= read -r -d '' link; do
  t=$(readlink "$link" || true)
  [[ "$t" == /lib/* ]] && ln -sf "/opt/alpine-rust/lib/${t#/lib/}" "$link"
done < <(find "$MNT/opt/alpine-rust/usr/lib" -type l -print0 2>/dev/null || true)
while IFS= read -r -d '' link; do
  t=$(readlink "$link" || true)
  [[ "$t" == /usr/lib/* ]] && ln -sf "/opt/alpine-rust/usr/lib/${t#/usr/lib/}" "$link"
done < <(find "$MNT/opt/alpine-rust/lib" -type l -print0 2>/dev/null || true)

cp -a "$ALPINE_STAGE/usr/bin/rustc" "$ALPINE_STAGE/usr/bin/cargo" "$MNT/opt/alpine-rust/usr/bin/"
for _b in rust-lld rust-lld-wrapper lld; do
  [[ -x "$ALPINE_STAGE/usr/bin/$_b" ]] && cp -a "$ALPINE_STAGE/usr/bin/$_b" "$MNT/opt/alpine-rust/usr/bin/"
done

[[ -n "$(ls "$MNT/opt/alpine-rust/lib"/ld-musl*.so.1 2>/dev/null)" ]] || { echo "error: no ld-musl"; exit 1; }

echo "[inject] installing musl dynamic linker into guest /lib..."
for x in "$MNT/opt/alpine-rust/lib"/ld-musl*.so.1 "$MNT/opt/alpine-rust/lib"/libc.musl*.so.1; do
  [[ -e "$x" ]] || continue
  cp -a "$x" "$MNT/lib/$(basename "$x")"
done

mkdir -p "$MNT/etc"
cat > "$MNT/etc/ld-musl-riscv64.path" <<'LDP'
/opt/alpine-rust/lib
/opt/alpine-rust/usr/lib
/lib
/usr/lib
LDP

echo "[inject] installing rust-std for riscv64gc-unknown-none-elf..."
STD_VER="${ALPINE_RUSTC_VER}"
STD_TARBALL="rust-std-${STD_VER}-riscv64gc-unknown-none-elf.tar.xz"
STD_URL="https://static.rust-lang.org/dist/${STD_TARBALL}"
STD_TGZ="/tmp/$STD_TARBALL"
if [[ ! -f "$STD_TGZ" ]]; then
  echo "[inject] downloading $STD_URL ..."
  if ! curl -fL "$STD_URL" -o "$STD_TGZ" 2>/dev/null; then
    STD_VER="${ALPINE_RUSTC_VER%%-nightly}"
    STD_TARBALL="rust-std-${STD_VER}-riscv64gc-unknown-none-elf.tar.xz"
    STD_URL="https://static.rust-lang.org/dist/${STD_TARBALL}"
    curl -fL "$STD_URL" -o "$STD_TGZ" || true
  fi
fi
if [[ -f "$STD_TGZ" ]]; then
  STD_EXTRACT="$(mktemp -d /tmp/rust-std-extract.XXXXXX)"
  tar xJf "$STD_TGZ" -C "$STD_EXTRACT" --strip-components=1
  ( cd "$STD_EXTRACT" && ./install.sh --prefix="$MNT/opt/alpine-rust/usr" >/dev/null )
  rm -rf "$STD_EXTRACT"
  echo "[inject] rust-std installed"
else
  echo "[inject] WARNING: could not download rust-std; build may fail for no_std targets"
fi

rm -f "$MNT/usr/local/bin/rustc" "$MNT/usr/local/bin/cargo" "$MNT/usr/local/bin/rustdoc" \
    "$MNT/usr/local/bin/rust-lld" "$MNT/usr/local/bin/cargo-clippy" 2>/dev/null || true

echo "[inject] Alpine musl rustc/cargo installed!"
echo "[inject]   /opt/alpine-rust/usr/bin/cargo"
echo "[inject]   /opt/alpine-rust/usr/bin/rustc"

rm -rf "$ALPINE_STAGE"
umount "$MNT" || true
echo "[inject] done."
