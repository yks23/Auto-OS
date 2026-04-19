/*
 * Test: test_rlimit_nofile_set
 * Phase: 1, Task: T5
 *
 * Spec (from TEST-MATRIX.md):
 *   `setrlimit(NOFILE, {32,32})`，dup 第 32 个返回 EMFILE
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/resource.h>

#define TEST_NAME "test_rlimit_nofile_set"

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

static int count_open_fds(void) {
    int c = 0;
    for (int i = 0; i < 8192; i++) {
        if (fcntl(i, F_GETFD) >= 0) {
            c++;
        }
    }
    return c;
}

int main(void) {
    /* TODO(T5): implement actual test
     *
     * Plan:
     *   1. setrlimit RLIMIT_NOFILE 软/硬均为 32；
     *   2. 从 stdin 或 /dev/null 起连续 dup 直到失败；
     *   3. 统计成功 fd 个数，期望第 32 个 dup 失败且 errno==EMFILE；
     *   4. 关闭所有临时 fd。
     */
    int base = open("/dev/null", O_RDWR);
    if (base < 0) {
        fail("open /dev/null failed: %s", strerror(errno));
    }

    int before = count_open_fds();
    if (before < 1) {
        close(base);
        fail("count_open_fds unexpected: %d", before);
    }

    struct rlimit rl = {.rlim_cur = 32, .rlim_max = 32};
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) {
        close(base);
        fail("setrlimit failed: %s", strerror(errno));
    }

    int fds[128];
    int n = 0;

    for (;;) {
        int d = dup(base);
        if (d < 0) {
            if (errno != EMFILE) {
                for (int i = 0; i < n; i++) {
                    close(fds[i]);
                }
                close(base);
                fail("dup failed with errno=%d (%s), expected EMFILE", errno, strerror(errno));
            }
            if (before + n != 32) {
                for (int i = 0; i < n; i++) {
                    close(fds[i]);
                }
                close(base);
                fail("expected EMFILE when hitting 32 total fds (had %d+%d)", before, n);
            }
            break;
        }
        if (n >= (int)(sizeof fds / sizeof fds[0])) {
            for (int i = 0; i < n; i++) {
                close(fds[i]);
            }
            close(base);
            fail("internal: fd buffer too small");
        }
        fds[n++] = d;
    }

    struct rlimit restore = {.rlim_cur = 4096, .rlim_max = 8192};
    if (setrlimit(RLIMIT_NOFILE, &restore) != 0) {
        for (int i = 0; i < n; i++) {
            close(fds[i]);
        }
        close(base);
        fail("setrlimit restore failed: %s", strerror(errno));
    }

    for (int i = 0; i < n; i++) {
        if (close(fds[i]) != 0) {
            fail("close dup fd failed: %s", strerror(errno));
        }
    }
    if (close(base) != 0) {
        fail("close base failed: %s", strerror(errno));
    }

    pass();
    return 0;
}
