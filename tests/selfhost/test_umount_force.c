/*
 * Test: test_umount_force
 * Phase: 1, Task: T4
 *
 * Spec (from TEST-MATRIX.md):
 *   MNT_FORCE 即使有 open fd 也 umount
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

#define TEST_NAME "test_umount_force"

#define MNT_POINT "/tmp/starry_t4_umount_force"
#define MARKER "openfile"

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
     *   1. 挂载测试文件系统到 /mnt 或临时目录；
     *   2. open 其下文件不关闭；
     *   3. umount2(MNT_FORCE) 应成功；
     *   4. 确认挂载点状态与内核无泄漏（按环境可简化）。
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

    if (umount2(MNT_POINT, MNT_FORCE) != 0) {
        int e = errno;
        cleanup_all(fd);
        fail("umount2 MNT_FORCE failed: %s", strerror(e));
    }

    if (close(fd) != 0) {
        fail("close failed: %s", strerror(errno));
    }

    unlink(path);
    if (rmdir(MNT_POINT) != 0 && errno != ENOENT) {
        fail("rmdir failed: %s", strerror(errno));
    }

    pass();
    return 0;
}
