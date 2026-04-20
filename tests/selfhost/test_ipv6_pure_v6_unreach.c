/*
 * Test: test_ipv6_pure_v6_unreach
 * Phase: 1, Task: T3
 *
 * Spec (from TEST-MATRIX.md):
 *   connect 真 v6 地址（非 v4-mapped）必须 ENETUNREACH（fallback 模式）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

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
     */
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) {
        fail("socket failed: %s", strerror(errno));
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        fail("fcntl F_GETFL failed: %s", strerror(errno));
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        fail("fcntl F_SETFL O_NONBLOCK failed: %s", strerror(errno));
    }

    struct sockaddr_in6 sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin6_family = AF_INET6;
    sa.sin6_port = htons(80);
    if (inet_pton(AF_INET6, "2001:db8::1", &sa.sin6_addr) != 1) {
        close(fd);
        fail("inet_pton failed: %s", strerror(errno));
    }

    int cr = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    if (cr == 0) {
        close(fd);
        fail("connect unexpectedly succeeded");
    }

    if (errno == ENETUNREACH) {
        if (close(fd) != 0) {
            fail("close failed: %s", strerror(errno));
        }
        pass();
        return 0;
    }

    if (errno != EINPROGRESS) {
        int e = errno;
        close(fd);
        fail("connect expected ENETUNREACH or EINPROGRESS, got errno=%d (%s)", e,
             strerror(e));
    }

    struct pollfd pfd;
    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = fd;
    pfd.events = POLLOUT;
    int pr = poll(&pfd, 1, 800);
    if (pr < 0) {
        fail("poll failed: %s", strerror(errno));
    }

    int so_err = 0;
    socklen_t elen = sizeof(so_err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &elen) != 0) {
        fail("getsockopt SO_ERROR failed: %s", strerror(errno));
    }

    if (close(fd) != 0) {
        fail("close failed: %s", strerror(errno));
    }

    if (so_err == ENETUNREACH) {
        pass();
        return 0;
    }

    fail("expected ENETUNREACH from connect/SO_ERROR, got %d (%s)", so_err,
         so_err ? strerror(so_err) : "no error");
    return 1;
}
