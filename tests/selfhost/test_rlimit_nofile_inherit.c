/*
 * Test: test_rlimit_nofile_inherit
 * Phase: 1, Task: T5
 * Status: SKELETON (functional logic to be filled in by T5 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   setrlimit 后 fork，子 getrlimit 同值
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_rlimit_nofile_inherit"

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
     *   1. 父 setrlimit NOFILE 到指定值；
     *   2. fork 子进程；
     *   3. 子 getrlimit 读软/硬上限；
     *   4. 与父设置逐字段比较；
     *   5. waitpid 回收子进程。
     *
     * 当前骨架默认 PASS，等 T5 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
