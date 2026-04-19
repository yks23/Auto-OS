/*
 * Test: test_ipv6_bind_getsockname
 * Phase: 1, Task: T3
 * Status: SKELETON (functional logic to be filled in by T3 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   bind `[::]:0` 后 `getsockname` family == AF_INET6
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_ipv6_bind_getsockname"

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
     *   1. 创建 AF_INET6 SOCK_STREAM socket；
     *   2. bind 全零地址端口 0；
     *   3. getsockname 填充 sockaddr_storage；
     *   4. 校验 ss_family==AF_INET6 且端口非 0。
     *
     * 当前骨架默认 PASS，等 T3 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
