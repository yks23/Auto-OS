/*
 * Test: test_fcntl_unknown_cmd
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   `fcntl(fd, 12345, 0)` 必须 EINVAL，不是 0
 */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TEST_NAME "test_fcntl_unknown_cmd"

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

int main(void) {
    /* TODO(T2): implement actual test
     *
     * Plan:
     *   1. open 合法文件得 fd；
     *   2. 调用 fcntl(fd, 12345, 0)；
     *   3. 断言返回 -1 且 errno==EINVAL；
     *   4. 关闭 fd。
     */
    char path[] = "/tmp/starry_fcntl_bad_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        fail("mkstemp: %s", strerror(errno));
    if (fcntl(fd, 12345, 0) == 0)
        fail("expected fcntl unknown cmd to fail");
    if (errno != EINVAL)
        fail("expected EINVAL got %s", strerror(errno));
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
}
