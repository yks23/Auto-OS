/*
 * Test: test_ipv6_v4mapped_loopback
 * Phase: 1, Task: T3
 *
 * Spec (from TEST-MATRIX.md):
 *   v4 server bind 127.0.0.1:N，v6 client connect `[::ffff:127.0.0.1]:N` 通
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/wait.h>
#include <signal.h>

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
     */
    signal(SIGPIPE, SIG_IGN);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        fail("server socket failed: %s", strerror(errno));
    }

    int on = 1;
    if (setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) != 0) {
        fail("setsockopt SO_REUSEADDR failed: %s", strerror(errno));
    }

    struct sockaddr_in s4;
    memset(&s4, 0, sizeof(s4));
    s4.sin_family = AF_INET;
    s4.sin_port = htons(0);
    if (inet_pton(AF_INET, "127.0.0.1", &s4.sin_addr) != 1) {
        close(srv);
        fail("inet_pton 127.0.0.1 failed: %s", strerror(errno));
    }

    if (bind(srv, (struct sockaddr *)&s4, sizeof(s4)) != 0) {
        fail("server bind failed: %s", strerror(errno));
    }

    socklen_t slen = sizeof(s4);
    if (getsockname(srv, (struct sockaddr *)&s4, &slen) != 0) {
        fail("server getsockname failed: %s", strerror(errno));
    }
    uint16_t port = ntohs(s4.sin_port);

    if (listen(srv, 1) != 0) {
        fail("listen failed: %s", strerror(errno));
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(srv);
        fail("fork failed: %s", strerror(errno));
    }

    if (pid == 0) {
        int cfd = accept(srv, NULL, NULL);
        if (cfd < 0) {
            _exit(1);
        }
        char b = 0;
        ssize_t n = recv(cfd, &b, 1, 0);
        if (n != 1 || b != 'x') {
            close(cfd);
            close(srv);
            _exit(2);
        }
        if (send(cfd, "y", 1, 0) != 1) {
            close(cfd);
            close(srv);
            _exit(3);
        }
        close(cfd);
        close(srv);
        _exit(0);
    }

    close(srv);

    int cli = socket(AF_INET6, SOCK_STREAM, 0);
    if (cli < 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        fail("client socket failed: %s", strerror(errno));
    }

    struct sockaddr_in6 c6;
    memset(&c6, 0, sizeof(c6));
    c6.sin6_family = AF_INET6;
    c6.sin6_port = htons(port);
    if (inet_pton(AF_INET6, "::ffff:127.0.0.1", &c6.sin6_addr) != 1) {
        close(cli);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        fail("inet_pton ::ffff:127.0.0.1 failed: %s", strerror(errno));
    }

    if (connect(cli, (struct sockaddr *)&c6, sizeof(c6)) != 0) {
        int e = errno;
        close(cli);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        fail("connect failed: %s", strerror(e));
    }

    if (send(cli, "x", 1, 0) != 1) {
        fail("client send failed: %s", strerror(errno));
    }
    char r = 0;
    if (recv(cli, &r, 1, 0) != 1 || r != 'y') {
        fail("client recv failed or wrong payload");
    }

    if (close(cli) != 0) {
        fail("client close failed: %s", strerror(errno));
    }

    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        fail("waitpid failed: %s", strerror(errno));
    }
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fail("child exited abnormally, status=%d", st);
    }

    pass();
    return 0;
}
