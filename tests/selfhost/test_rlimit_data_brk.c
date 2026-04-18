/*
 * Test: test_rlimit_data_brk
 * Phase: 1, Task: T5
 * Status: SKELETON (functional logic to be filled in by T5 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   setrlimit DATA=64MB，brk 超过必须 ENOMEM
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

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
     *   5. 恢复合理 limit 避免影响后续。
     *
     * 当前骨架默认 PASS，等 T5 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
