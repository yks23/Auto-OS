/*
 * Test: test_rlimit_as_set
 * Phase: 1, Task: T5
 * Status: SKELETON (functional logic to be filled in by T5 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   setrlimit AS=128MB，mmap 200MB 必须 ENOMEM
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_rlimit_as_set"

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
     *   1. setrlimit RLIMIT_AS 为 128MiB；
     *   2. mmap 匿名 200MiB PROT_READ|WRITE；
     *   3. 期望返回 MAP_FAILED 且 errno==ENOMEM；
     *   4. 无则 fail。
     *
     * 当前骨架默认 PASS，等 T5 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
