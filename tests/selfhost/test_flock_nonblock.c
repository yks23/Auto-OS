/*
 * Test: test_flock_nonblock
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   子进程拿 LOCK_EX，父进程 LOCK_NB|LOCK_EX 必须 EWOULDBLOCK
 */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

#define TEST_NAME "test_flock_nonblock"

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
     *   1. 子 flock LOCK_EX 占锁；
     *   2. 父 flock LOCK_NB|LOCK_EX，期望立即返回 -1 且 errno==EWOULDBLOCK；
     *   3. 子释放锁后父可正常加锁；
     *   4. 清理子进程与 fd。
     */
    char path[] = "/tmp/starry_flock_nb_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        fail("mkstemp: %s", strerror(errno));
    if (write(fd, "x", 1) != 1)
        fail("write: %s", strerror(errno));

    int sync_p[2];
    if (pipe(sync_p) != 0)
        fail("pipe: %s", strerror(errno));

    pid_t pid = fork();
    if (pid < 0)
        fail("fork: %s", strerror(errno));

    if (pid == 0) {
        close(sync_p[0]);
        close(fd);
        int cfd = open(path, O_RDWR);
        if (cfd < 0)
            fail("child open: %s", strerror(errno));
        if (flock(cfd, LOCK_EX) != 0)
            fail("child flock LOCK_EX: %s", strerror(errno));
        char b = 1;
        if (write(sync_p[1], &b, 1) != 1)
            fail("child write sync: %s", strerror(errno));
        close(sync_p[1]);
        int pfd0 = open(path, O_RDWR);
        if (pfd0 < 0)
            fail("child second open: %s", strerror(errno));
        if (read(pfd0, &b, 1) != 1)
            fail("child read wait: %s", strerror(errno));
        close(pfd0);
        if (flock(cfd, LOCK_UN) != 0)
            fail("child flock LOCK_UN: %s", strerror(errno));
        close(cfd);
        exit(0);
    }

    close(sync_p[1]);
    char b;
    if (read(sync_p[0], &b, 1) != 1)
        fail("parent read sync: %s", strerror(errno));
    close(sync_p[0]);

    int pfd = open(path, O_RDWR);
    if (pfd < 0)
        fail("parent open: %s", strerror(errno));

    if (flock(pfd, LOCK_EX | LOCK_NB) == 0)
        fail("expected parent LOCK_NB|LOCK_EX to fail");
    if (errno != EWOULDBLOCK)
        fail("expected errno EWOULDBLOCK, got %s", strerror(errno));

    if (write(pfd, "y", 1) != 1)
        fail("parent wake child write: %s", strerror(errno));

    int st;
    if (waitpid(pid, &st, 0) < 0)
        fail("waitpid: %s", strerror(errno));
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("child exit status unexpected");

    if (flock(pfd, LOCK_EX) != 0)
        fail("parent flock LOCK_EX after unlock: %s", strerror(errno));
    if (flock(pfd, LOCK_UN) != 0)
        fail("parent flock LOCK_UN: %s", strerror(errno));
    close(pfd);
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
}
