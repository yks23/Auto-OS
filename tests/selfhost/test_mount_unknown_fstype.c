/*
 * Test: test_mount_unknown_fstype
 * Phase: 1, Task: T4
 *
 * Spec (from TEST-MATRIX.md):
 *   `mount(_, _, "totally-fake", 0, _)` 必须 ENODEV，不是 0
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>

#define TEST_NAME "test_mount_unknown_fstype"

#define MNT_POINT "/tmp/starry_t4_unknown_fstype"

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

static void teardown(void) {
    umount2(MNT_POINT, MNT_DETACH | MNT_FORCE);
    rmdir(MNT_POINT);
}

int main(void) {
    /* TODO(T4): implement actual test
     *
     * Plan:
     *   1. 准备挂载点目录与哑设备路径（如 tmpfs 上的文件）；
     *   2. 调用 mount 指定 fstype totally-fake；
     *   3. 断言返回 -1 且 errno==ENODEV；
     *   4. 绝不接受返回 0。
     */
    teardown();
    if (mkdir(MNT_POINT, 0755) != 0 && errno != EEXIST) {
        fail("mkdir failed: %s", strerror(errno));
    }

    if (mount("none", MNT_POINT, "totally-fake", 0, NULL) == 0) {
        teardown();
        fail("mount unexpectedly succeeded for unknown fstype");
    }
    if (errno != ENODEV) {
        int saved = errno;
        teardown();
        fail("expected errno ENODEV (%d), got %d (%s)", ENODEV, saved, strerror(saved));
    }

    teardown();
    pass();
    return 0;
}
