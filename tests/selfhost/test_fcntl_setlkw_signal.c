/*
 * Test: test_fcntl_setlkw_signal
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   F_SETLKW 阻塞时收到 SIGUSR1，返回 EINTR
 */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define TEST_NAME "test_fcntl_setlkw_signal"

static volatile sig_atomic_t usr1_seen;

static void on_usr1(int s) {
    (void)s;
    usr1_seen = 1;
}

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
    /* TODO(T2): implement actual test
     *
     * Plan:
     *   1. 安装 SIGUSR1 空处理或标记；
     *   2. 线程/子进程先占互斥锁，使父 F_SETLKW 阻塞；
     *   3. 另一上下文向阻塞线程发 SIGUSR1；
     *   4. 确认 fcntl 返回 -1 且 errno==EINTR；
     *   5. 恢复锁状态与信号掩码。
     */
    char path[] = "/tmp/starry_setlkw_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        fail("mkstemp: %s", strerror(errno));
    if (write(fd, "x", 1) != 1)
        fail("write: %s", strerror(errno));

    int ready[2], rel[2], kgo[2];
    if (pipe(ready) != 0 || pipe(rel) != 0 || pipe(kgo) != 0)
        fail("pipe: %s", strerror(errno));

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_usr1;
    if (sigaction(SIGUSR1, &sa, NULL) != 0)
        fail("sigaction: %s", strerror(errno));

    pid_t locker = fork();
    if (locker < 0)
        fail("fork locker: %s", strerror(errno));
    if (locker == 0) {
        close(ready[0]);
        close(rel[1]);
        close(fd);
        int a = open(path, O_RDWR);
        if (a < 0)
            fail("locker open: %s", strerror(errno));
        struct flock fl = {
            .l_type = F_WRLCK,
            .l_whence = SEEK_SET,
            .l_start = 0,
            .l_len = 1,
        };
        if (fcntl(a, F_SETLK, &fl) != 0)
            fail("locker F_SETLK: %s", strerror(errno));
        char b = 1;
        if (write(ready[1], &b, 1) != 1)
            fail("locker ready: %s", strerror(errno));
        if (read(rel[0], &b, 1) != 1)
            fail("locker rel: %s", strerror(errno));
        struct flock u = {
            .l_type = F_UNLCK,
            .l_whence = SEEK_SET,
            .l_start = 0,
            .l_len = 1,
        };
        if (fcntl(a, F_SETLK, &u) != 0)
            fail("locker unlock: %s", strerror(errno));
        close(a);
        close(ready[1]);
        close(rel[0]);
        exit(0);
    }

    pid_t killer = fork();
    if (killer < 0)
        fail("fork killer: %s", strerror(errno));
    if (killer == 0) {
        close(ready[0]);
        close(ready[1]);
        close(rel[0]);
        close(rel[1]);
        close(kgo[1]);
        close(fd);
        char b;
        if (read(kgo[0], &b, 1) != 1)
            fail("killer read go: %s", strerror(errno));
        close(kgo[0]);
        usleep(200000);
        if (kill(getppid(), SIGUSR1) != 0)
            fail("killer kill: %s", strerror(errno));
        exit(0);
    }

    close(ready[1]);
    close(rel[0]);
    close(kgo[0]);
    char b;
    if (read(ready[0], &b, 1) != 1)
        fail("parent wait locker: %s", strerror(errno));
    close(ready[0]);

    int pfd = open(path, O_RDWR);
    if (pfd < 0)
        fail("parent open: %s", strerror(errno));

    if (write(kgo[1], &b, 1) != 1)
        fail("parent killer go: %s", strerror(errno));
    close(kgo[1]);

    struct flock w = {
        .l_type = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 1,
    };
    int r = fcntl(pfd, F_SETLKW, &w);
    if (r == 0)
        fail("expected F_SETLKW to be interrupted");
    if (errno != EINTR)
        fail("expected errno EINTR got %s", strerror(errno));
    if (!usr1_seen)
        fail("handler not run");

    if (write(rel[1], &b, 1) != 1)
        fail("parent release locker: %s", strerror(errno));
    close(rel[1]);

    int st;
    if (waitpid(locker, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("locker exit");
    if (waitpid(killer, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("killer exit");

    struct flock u = {
        .l_type = F_UNLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 1,
    };
    if (fcntl(pfd, F_SETLK, &u) != 0)
        fail("parent unlock: %s", strerror(errno));
    close(pfd);
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
}
