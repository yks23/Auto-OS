/*
 * Test: test_rlimit_stack_default
 * Phase: 1, Task: T5
 *
 * Spec (from TEST-MATRIX.md):
 *   `getrlimit(RLIMIT_STACK).rlim_cur >= 8*1024*1024`
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <limits.h>
#include <sys/resource.h>

#define TEST_NAME "test_rlimit_stack_default"

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
     *   1. getrlimit(RLIMIT_STACK, &rl)；
     *   2. 比较 rlim_cur 是否 >= 8MiB；
     *   3. 不满足则 fail 打印当前值。
     */
    struct rlimit rl;
    if (getrlimit(RLIMIT_STACK, &rl) != 0) {
        fail("getrlimit failed: %s", strerror(errno));
    }
    const rlim_t need = (rlim_t)8 * 1024 * 1024;
    if (rl.rlim_cur < need) {
        fail("RLIMIT_STACK rlim_cur=%llu < 8MiB", (unsigned long long)rl.rlim_cur);
    }
    pass();
    return 0;
}
