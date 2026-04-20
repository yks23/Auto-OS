/*
 * Test: test_umount_busy
 * Phase: 1, Task: T4
 *
 * Spec (from TEST-MATRIX.md):
 *   open 一个文件，umount 必须 EBUSY；MNT_DETACH 必须成功
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <unistd.h>

#define TEST_NAME "test_umount_busy"

#define MNT_POINT "/tmp/starry_t4_umount_busy"
#define MARKER "marker"

static void pass(void) {
    printf("[TEST] %s PASS\n", TEST_NAME);
    exit(0);
}

static void fail(const char *fmt, ...) {
    va_list ap;
    printf("[TEST] %s FAIL: ", TEST_NAME);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    exit(1);
}

static void cleanup_all(int fd) {
    if (fd >= 0) {
        close(fd);
    }
    umount2(MNT_POINT, MNT_DETACH | MNT_FORCE);
    unlink(MNT_POINT "/" MARKER);
    rmdir(MNT_POINT);
}

int main(void) {
    /* TODO(T4): implement actual test
     *
     * Plan:
     *   1. 在测试挂载点下 open 文件保持 fd；
     *   2. umount 该点，期望 EBUSY；
     *   3. 使用 MNT_DETACH 标志 umount2 应成功；
     *   4. 关闭 fd 并清理挂载点。
     */
    int fd = -1;
    cleanup_all(-1);

    if (mkdir(MNT_POINT, 0755) != 0) {
        fail("mkdir failed: %s", strerror(errno));
    }
    if (mount("tmpfs", MNT_POINT, "tmpfs", 0, NULL) != 0) {
        fail("mount tmpfs failed: %s", strerror(errno));
    }

    char path[256];
    snprintf(path, sizeof(path), "%s/%s", MNT_POINT, MARKER);
    fd = open(path, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        cleanup_all(-1);
        fail("open failed: %s", strerror(errno));
    }

    if (umount2(MNT_POINT, 0) == 0) {
        cleanup_all(fd);
        fail("umount2 without flags unexpectedly succeeded (expected EBUSY)");
    }
    if (errno != EBUSY) {
        int e = errno;
        cleanup_all(fd);
        fail("expected errno EBUSY (%d), got %d (%s)", EBUSY, e, strerror(e));
    }

    if (umount2(MNT_POINT, MNT_DETACH) != 0) {
        int e = errno;
        cleanup_all(fd);
        fail("umount2 MNT_DETACH failed: %s", strerror(e));
    }

    if (close(fd) != 0) {
        fail("close failed: %s", strerror(errno));
    }
    fd = -1;

    umount2(MNT_POINT, MNT_FORCE);
    unlink(path);
    if (rmdir(MNT_POINT) != 0 && errno != ENOENT) {
        fail("rmdir failed: %s", strerror(errno));
    }

    pass();
    return 0;
}
