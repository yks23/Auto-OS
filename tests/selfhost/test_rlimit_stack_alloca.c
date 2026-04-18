/*
 * Test: test_rlimit_stack_alloca
 * Phase: 1, Task: T5
 * Status: SKELETON (functional logic to be filled in by T5 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   递归 alloca 4 MiB 不爆栈
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

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

int main(void) {
    /* TODO(T5): implement actual test
     *
     * Plan:
     *   1. 确认栈 rlimit 足够大；
     *   2. 递归函数每层 alloca(4MiB) 或分摊到多层累计 4MiB；
     *   3. 触碰页面确保映射；
     *   4. 正常返回不 SIGSEGV；
     *   5. 深度与大小可按栈上限调整。
     *
     * 当前骨架默认 PASS，等 T5 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
