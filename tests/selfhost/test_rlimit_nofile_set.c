/*
 * Test: test_rlimit_nofile_set
 * Phase: 1, Task: T5
 * Status: SKELETON (functional logic to be filled in by T5 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   `setrlimit(NOFILE, {32,32})`，dup 第 32 个返回 EMFILE
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

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

int main(void) {
    /* TODO(T5): implement actual test
     *
     * Plan:
     *   1. setrlimit RLIMIT_NOFILE 软/硬均为 32；
     *   2. 从 stdin 或 /dev/null 起连续 dup 直到失败；
     *   3. 统计成功 fd 个数，期望第 32 个 dup 失败且 errno==EMFILE；
     *   4. 关闭所有临时 fd。
     *
     * 当前骨架默认 PASS，等 T5 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
