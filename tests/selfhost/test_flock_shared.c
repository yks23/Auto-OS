/*
 * Test: test_flock_shared
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   两个 LOCK_SH 可以共存；其中任一升级 LOCK_EX 阻塞另一个
 */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define TEST_NAME "test_flock_shared"

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
     *   1. 进程 A、B 各 open 同文件并 flock LOCK_SH，应均成功；
     *   2. A 尝试 LOCK_EX 升级，应阻塞直到 B 释放 SH；
     *   3. 或 B 升级阻塞 A，按设计交替验证；
     *   4. 记录 errno 与返回顺序，最后释放全部锁。
     */
    char path[] = "/tmp/starry_flock_sh_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        fail("mkstemp: %s", strerror(errno));
    if (write(fd, "x", 1) != 1)
        fail("write: %s", strerror(errno));

    int ra[2], rb[2], done[2];
    if (pipe(ra) != 0 || pipe(rb) != 0 || pipe(done) != 0)
        fail("pipe: %s", strerror(errno));

    pid_t c1 = fork();
    if (c1 < 0)
        fail("fork1: %s", strerror(errno));
    if (c1 == 0) {
        close(ra[0]);
        close(rb[0]);
        close(rb[1]);
        close(done[1]);
        close(fd);
        int a = open(path, O_RDWR);
        if (a < 0)
            fail("c1 open: %s", strerror(errno));
        if (flock(a, LOCK_SH) != 0)
            fail("c1 LOCK_SH: %s", strerror(errno));
        char x = 1;
        if (write(ra[1], &x, 1) != 1)
            fail("c1 ready: %s", strerror(errno));
        if (read(done[0], &x, 1) != 1)
            fail("c1 done read: %s", strerror(errno));
        if (flock(a, LOCK_UN) != 0)
            fail("c1 unlock: %s", strerror(errno));
        close(a);
        close(ra[1]);
        close(done[0]);
        exit(0);
    }

    pid_t c2 = fork();
    if (c2 < 0)
        fail("fork2: %s", strerror(errno));
    if (c2 == 0) {
        close(ra[1]);
        close(rb[0]);
        close(done[1]);
        close(fd);
        char x;
        if (read(ra[0], &x, 1) != 1)
            fail("c2 sync: %s", strerror(errno));
        close(ra[0]);
        int b = open(path, O_RDWR);
        if (b < 0)
            fail("c2 open: %s", strerror(errno));
        if (flock(b, LOCK_SH) != 0)
            fail("c2 LOCK_SH: %s", strerror(errno));
        if (write(rb[1], &x, 1) != 1)
            fail("c2 ready: %s", strerror(errno));
        if (read(done[0], &x, 1) != 1)
            fail("c2 done read: %s", strerror(errno));
        if (flock(b, LOCK_UN) != 0)
            fail("c2 unlock: %s", strerror(errno));
        close(b);
        close(rb[1]);
        close(done[0]);
        exit(0);
    }

    close(ra[1]);
    close(rb[1]);
    close(done[0]);
    char x;
    if (read(rb[0], &x, 1) != 1)
        fail("parent wait c2: %s", strerror(errno));
    close(rb[0]);
    close(ra[0]);

    int pfd = open(path, O_RDWR);
    if (pfd < 0)
        fail("parent open: %s", strerror(errno));

    if (flock(pfd, LOCK_EX | LOCK_NB) == 0)
        fail("expected parent LOCK_EX|LOCK_NB to fail");
    if (errno != EWOULDBLOCK)
        fail("expected EWOULDBLOCK got %s", strerror(errno));

    if (write(done[1], &x, 1) != 1)
        fail("parent done c1: %s", strerror(errno));
    if (write(done[1], &x, 1) != 1)
        fail("parent done c2: %s", strerror(errno));
    close(done[1]);

    int st;
    if (waitpid(c1, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("c1 exit");
    if (waitpid(c2, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("c2 exit");

    if (flock(pfd, LOCK_EX) != 0)
        fail("parent LOCK_EX: %s", strerror(errno));
    if (flock(pfd, LOCK_UN) != 0)
        fail("parent unlock: %s", strerror(errno));
    close(pfd);
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
}
