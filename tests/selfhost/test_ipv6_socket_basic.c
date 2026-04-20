/*
 * Test: test_ipv6_socket_basic
 * Phase: 1, Task: T3
 *
 * Spec (from TEST-MATRIX.md):
 *   `socket(AF_INET6, SOCK_STREAM, 0)` ≥ 0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/socket.h>

#define TEST_NAME "test_ipv6_socket_basic"

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
     *   1. 调用 socket(AF_INET6, SOCK_STREAM, 0)；
     *   2. 断言 fd>=0；
     *   3. close 套接字。
     */
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) {
        fail("socket failed: %s", strerror(errno));
    }
    if (close(fd) != 0) {
        fail("close failed: %s", strerror(errno));
    }
    pass();
    return 0;
}
