/*
 * Test: test_ipv6_v6only_setsockopt
 * Phase: 1, Task: T3
 *
 * Spec (from TEST-MATRIX.md):
 *   `IPV6_V6ONLY` getset 不报错
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define TEST_NAME "test_ipv6_v6only_setsockopt"

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
     *   1. socket(AF_INET6, ...)；
     *   2. getsockopt IPV6_V6ONLY 读初值；
     *   3. setsockopt 切换 0/1 再读回；
     *   4. 各步返回 0，失败则 fail()。
     */
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) {
        fail("socket failed: %s", strerror(errno));
    }

    int v = -1;
    socklen_t len = sizeof(v);
    if (getsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v, &len) != 0) {
        fail("getsockopt IPV6_V6ONLY failed: %s", strerror(errno));
    }
    if (len != sizeof(int)) {
        fail("unexpected getsockopt optlen %u", (unsigned)len);
    }

    int one = 1;
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one)) != 0) {
        fail("setsockopt IPV6_V6ONLY=1 failed: %s", strerror(errno));
    }

    v = -1;
    len = sizeof(v);
    if (getsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v, &len) != 0) {
        fail("getsockopt IPV6_V6ONLY (after set 1) failed: %s", strerror(errno));
    }

    int zero = 0;
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero)) != 0) {
        fail("setsockopt IPV6_V6ONLY=0 failed: %s", strerror(errno));
    }

    v = -1;
    len = sizeof(v);
    if (getsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v, &len) != 0) {
        fail("getsockopt IPV6_V6ONLY (after set 0) failed: %s", strerror(errno));
    }

    if (close(fd) != 0) {
        fail("close failed: %s", strerror(errno));
    }
    pass();
    return 0;
}
