/*
 * Test: test_ipv6_bind_getsockname
 * Phase: 1, Task: T3
 *
 * Spec (from TEST-MATRIX.md):
 *   bind `[::]:0` 后 `getsockname` family == AF_INET6
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

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
     */
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) {
        fail("socket failed: %s", strerror(errno));
    }

    struct sockaddr_in6 bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin6_family = AF_INET6;
    bind_addr.sin6_port = htons(0);
    bind_addr.sin6_addr = in6addr_any;

    if (bind(fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) != 0) {
        fail("bind failed: %s", strerror(errno));
    }

    struct sockaddr_storage ss;
    socklen_t sslen = sizeof(ss);
    memset(&ss, 0, sizeof(ss));
    if (getsockname(fd, (struct sockaddr *)&ss, &sslen) != 0) {
        fail("getsockname failed: %s", strerror(errno));
    }

    if (ss.ss_family != AF_INET6) {
        fail("expected ss_family AF_INET6, got %d", (int)ss.ss_family);
    }

    struct sockaddr_in6 *out = (struct sockaddr_in6 *)&ss;
    if (ntohs(out->sin6_port) == 0) {
        fail("expected ephemeral port != 0 after bind");
    }

    if (close(fd) != 0) {
        fail("close failed: %s", strerror(errno));
    }
    pass();
    return 0;
}
