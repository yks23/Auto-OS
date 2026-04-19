/*
 * Test: test_rlimit_stack_alloca
 * Phase: 1, Task: T5
 *
 * Spec (from TEST-MATRIX.md):
 *   递归 alloca 4 MiB 不爆栈
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <alloca.h>
#include <stdint.h>
#include <limits.h>
#include <sys/resource.h>

#define TEST_NAME "test_rlimit_stack_alloca"

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

static void touch_stack(volatile char *p, size_t n) {
    for (size_t i = 0; i < n; i += 4096) {
        p[i] = (char)(i & 0xff);
    }
}

int main(void) {
    /* TODO(T5): implement actual test
     *
     * Plan:
     *   1. 确认栈 rlimit 足够大；
     *   2. 递归函数每层 alloca(4MiB) 或分摊到多层累计 4MiB；
     *   3. 触碰页面确保映射；
     *   4. 正常返回不 SIGSEGV；
     */
    struct rlimit rl;
    if (getrlimit(RLIMIT_STACK, &rl) != 0) {
        fail("getrlimit failed: %s", strerror(errno));
    }
    const size_t need = 4u * 1024u * 1024u;
    if (rl.rlim_cur != RLIM_INFINITY
        && (rlim_t)need + (rlim_t)(64 * 1024) > rl.rlim_cur) {
        fail("RLIMIT_STACK rlim_cur=%llu too small for 4MiB alloca",
             (unsigned long long)rl.rlim_cur);
    }

    volatile char *p = (volatile char *)alloca(need);
    touch_stack(p, need);
    pass();
    return 0;
}
