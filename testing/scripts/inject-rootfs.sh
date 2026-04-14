#!/usr/bin/env bash
# 将编译好的测试程序注入 rootfs 镜像
# 用法: ./testing/scripts/inject-rootfs.sh [ARCH] [ROOTFS_IMG]

set -e
ARCH="${1:-riscv64}"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$DIR/testing/build/$ARCH/l1"
ROOTFS="${2:-$DIR/starry-os/rootfs-${ARCH}.img}"

if [ ! -f "$ROOTFS" ]; then
    echo "rootfs 不存在: $ROOTFS"
    echo "请先运行: cd starry-os && make ARCH=$ARCH rootfs"
    exit 1
fi

if [ ! -d "$BUILD" ] || [ -z "$(ls $BUILD/test_* 2>/dev/null)" ]; then
    echo "测试程序未编译，先运行: ./testing/scripts/build-tests.sh $ARCH"
    exit 1
fi

MNT=$(mktemp -d)
echo "挂载 $ROOTFS → $MNT"
sudo mount -o loop "$ROOTFS" "$MNT"

sudo mkdir -p "$MNT/bin/tests"
COUNT=0
for bin in "$BUILD"/test_*; do
    sudo cp "$bin" "$MNT/bin/tests/"
    COUNT=$((COUNT + 1))
done

# 生成运行脚本
sudo bash -c "cat > '$MNT/bin/run-tests.sh'" << 'SCRIPT'
#!/bin/sh
echo "=== Auto-OS L1 测试 ==="
PASS=0
FAIL=0
TOTAL=0
for test in /bin/tests/test_*; do
    [ -x "$test" ] || continue
    TOTAL=$((TOTAL + 1))
    name=$(basename "$test")
    echo "--- $name ---"
    if timeout 30 "$test" 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done
echo ""
echo "=== 总计: $PASS/$TOTAL 通过, $FAIL 失败 ==="
SCRIPT
sudo chmod +x "$MNT/bin/run-tests.sh"

sudo umount "$MNT"
rmdir "$MNT"

echo "注入完成: $COUNT 个测试程序 → $ROOTFS:/bin/tests/"
echo "在 QEMU 中运行: /bin/run-tests.sh"
