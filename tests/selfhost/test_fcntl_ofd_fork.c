/*
 * Test: test_fcntl_ofd_fork
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   父 F_OFD_SETLK 后 fork，子的同 fd 看到 OFD 锁是"自己的"
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

#define TEST_NAME "test_fcntl_ofd_fork"

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
#ifndef F_OFD_SETLK
    printf("[TEST] %s SKIP (no F_OFD_SETLK)\n", TEST_NAME);
    return 0;
#else
    /* TODO(T2): implement actual test
     *
     * Plan:
     *   1. 父进程 open 文件并 fcntl F_OFD_SETLK 加锁；
     *   2. fork 后父子共享 fd；
     *   3. 子进程查询/再次加锁行为应符合 OFD 语义（锁随进程）；
     *   4. 对照 Linux 参考行为写断言；
     *   5. 父子协调退出。
     */
    char path[] = "/tmp/starry_ofd_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        fail("mkstemp: %s", strerror(errno));
    if (write(fd, "x", 1) != 1)
        fail("write: %s", strerror(errno));

    struct flock l = {
        .l_type = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 64,
    };
    if (fcntl(fd, F_OFD_SETLK, &l) != 0)
        fail("parent F_OFD_SETLK: %s", strerror(errno));

    pid_t pid = fork();
    if (pid < 0)
        fail("fork: %s", strerror(errno));

    if (pid == 0) {
        struct flock g = {
            .l_type = F_WRLCK,
            .l_whence = SEEK_SET,
            .l_start = 0,
            .l_len = 64,
        };
        if (fcntl(fd, F_OFD_GETLK, &g) != 0)
            fail("child F_OFD_GETLK: %s", strerror(errno));
        if (g.l_type != F_UNLCK)
            fail("expected child F_OFD_GETLK F_UNLCK got type %d", (int)g.l_type);
        close(fd);
        exit(0);
    }

    int st;
    if (waitpid(pid, &st, 0) < 0)
        fail("waitpid: %s", strerror(errno));
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("child exit bad");

    struct flock u = {
        .l_type = F_UNLCK,
        .l_whence = SEEK_SET,
        .l_start = 0,
        .l_len = 64,
    };
    if (fcntl(fd, F_OFD_SETLK, &u) != 0)
        fail("parent F_OFD unlock: %s", strerror(errno));
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
#endif
}
