/*
 * Test: test_flock_close_release
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   close fd 后锁立即释放，另一进程能拿
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

#define TEST_NAME "test_flock_close_release"

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
     *   1. 进程 A open+flock LOCK_EX；
     *   2. 进程 B 尝试加锁应阻塞或失败（视时序）；
     *   3. A close(fd) 不传显式解锁；
     *   4. B 应立即 flock 成功；
     *   5. 无死锁，清理资源。
     */
    char path[] = "/tmp/starry_flock_cls_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        fail("mkstemp: %s", strerror(errno));
    if (write(fd, "x", 1) != 1)
        fail("write: %s", strerror(errno));

    int ready[2], go[2];
    if (pipe(ready) != 0 || pipe(go) != 0)
        fail("pipe: %s", strerror(errno));

    pid_t pid = fork();
    if (pid < 0)
        fail("fork: %s", strerror(errno));

    if (pid == 0) {
        close(ready[0]);
        close(go[1]);
        int cfd = open(path, O_RDWR);
        if (cfd < 0)
            fail("child open: %s", strerror(errno));
        if (flock(cfd, LOCK_EX) != 0)
            fail("child flock: %s", strerror(errno));
        char b = 1;
        if (write(ready[1], &b, 1) != 1)
            fail("child ready: %s", strerror(errno));
        if (read(go[0], &b, 1) != 1)
            fail("child read go: %s", strerror(errno));
        close(cfd);
        close(ready[1]);
        close(go[0]);
        close(fd);
        exit(0);
    }

    close(ready[1]);
    close(go[0]);
    char b;
    if (read(ready[0], &b, 1) != 1)
        fail("parent read ready: %s", strerror(errno));
    close(ready[0]);

    int pfd = open(path, O_RDWR);
    if (pfd < 0)
        fail("parent open: %s", strerror(errno));

    if (flock(pfd, LOCK_EX | LOCK_NB) == 0)
        fail("expected LOCK_NB to fail before child close");
    if (errno != EWOULDBLOCK)
        fail("expected EWOULDBLOCK got %s", strerror(errno));

    if (write(go[1], &b, 1) != 1)
        fail("parent go: %s", strerror(errno));
    close(go[1]);

    int st;
    if (waitpid(pid, &st, 0) < 0)
        fail("waitpid: %s", strerror(errno));
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("child exit bad");

    if (flock(pfd, LOCK_EX) != 0)
        fail("parent flock after child close: %s", strerror(errno));
    if (flock(pfd, LOCK_UN) != 0)
        fail("parent unlock: %s", strerror(errno));
    close(pfd);
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
}
