/*
 * Test: test_rlimit_data_brk
 * Phase: 1, Task: T5
 *
 * Spec (from TEST-MATRIX.md):
 *   setrlimit DATA=64MB，brk 超过必须 ENOMEM
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/resource.h>

#define TEST_NAME "test_rlimit_data_brk"

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
    /* TODO(T5): implement actual test
     *
     * Plan:
     *   1. 记录程序 break 初值；
     *   2. setrlimit RLIMIT_DATA 到 64MiB；
     *   3. sbrk/brk 尝试把数据段顶到超过限制；
     *   4. 期望 brk 返回 -1 且 errno==ENOMEM；
     */
    void *cur = sbrk(0);
    if (cur == (void *)-1) {
        fail("sbrk(0) failed: %s", strerror(errno));
    }

    struct rlimit old_data;
    if (getrlimit(RLIMIT_DATA, &old_data) != 0) {
        fail("getrlimit DATA failed: %s", strerror(errno));
    }

    struct rlimit rl = {.rlim_cur = 64u * 1024u * 1024u, .rlim_max = 64u * 1024u * 1024u};
    if (setrlimit(RLIMIT_DATA, &rl) != 0) {
        fail("setrlimit failed: %s", strerror(errno));
    }

    uintptr_t target = (uintptr_t)cur + (64u * 1024u * 1024u) + 65536u;
    target = (target + 4095u) & ~4095u;

    if (brk((void *)target) != -1) {
        fail("brk beyond RLIMIT_DATA unexpectedly succeeded");
    }
    if (errno != ENOMEM) {
        fail("brk failed with errno=%d (%s), expected ENOMEM", errno, strerror(errno));
    }

    if (setrlimit(RLIMIT_DATA, &old_data) != 0) {
        fail("setrlimit restore DATA failed: %s", strerror(errno));
    }

    pass();
    return 0;
}
