/*
 * Test: test_ipv6_pure_v6_unreach
 * Phase: 1, Task: T3
 * Status: SKELETON (functional logic to be filled in by T3 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   connect 真 v6 地址（非 v4-mapped）必须 ENETUNREACH（fallback 模式）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_ipv6_pure_v6_unreach"

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
     *   1. 选择非映射的不可达全局/文档 v6 地址与端口；
     *   2. 非阻塞或带超时 connect；
     *   3. 断言 errno==ENETUNREACH（或文档约定的 fallback 行为）；
     *   4. 不误判为 ECONNREFUSED 除非环境要求。
     *
     * 当前骨架默认 PASS，等 T3 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
