/*
 * Test: test_flock_excl_block
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   子进程拿 LOCK_EX，父进程 LOCK_EX 阻塞；子 close 后父立刻拿到
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

#define TEST_NAME "test_flock_excl_block"

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
     *   1. 父子各 open 同一文件；子 flock(LOCK_EX)；
     *   2. 父记录时间戳后 flock(LOCK_EX) 应阻塞；
     *   3. 子进程 sleep 后 close(fd) 释放锁；
     *   4. 父进程应在子 close 后很快返回成功；
     *   5. 用超时/线程或管道同步验证阻塞与解除顺序。
     */
    char path[] = "/tmp/starry_flock_blk_XXXXXX";
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
        usleep(200000);
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

    if (write(go[1], &b, 1) != 1)
        fail("parent write go: %s", strerror(errno));
    close(go[1]);

    if (flock(pfd, LOCK_EX) != 0)
        fail("parent flock LOCK_EX: %s", strerror(errno));

    int st;
    if (waitpid(pid, &st, 0) < 0)
        fail("waitpid: %s", strerror(errno));
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("child bad exit");

    if (flock(pfd, LOCK_UN) != 0)
        fail("parent unlock: %s", strerror(errno));
    close(pfd);
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
}
