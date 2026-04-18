/*
 * Test: test_ipv6_v4mapped_loopback
 * Phase: 1, Task: T3
 * Status: SKELETON (functional logic to be filled in by T3 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   v4 server bind 127.0.0.1:N，v6 client connect `[::ffff:127.0.0.1]:N` 通
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_ipv6_v4mapped_loopback"

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
    /* TODO(T3): implement actual test
     *
     * Plan:
     *   1. v4 socket bind 127.0.0.1 动态端口；
     *   2. listen/accept 一侧；
     *   3. v6 client connect ::ffff:127.0.0.1:该端口；
     *   4. 收发一字节或 shutdown 验证连通；
     *   5. 关闭所有 fd。
     *
     * 当前骨架默认 PASS，等 T3 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
