/*
 * Test: test_fcntl_setlk_overlap
 * Phase: 1, Task: T2
 *
 * Spec (from TEST-MATRIX.md):
 *   进程 A 锁 [0,100) W，进程 B `F_GETLK` [50,200) 看到 conflict 信息
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

#define TEST_NAME "test_fcntl_setlk_overlap"

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
     *   1. A 用 struct flock F_SETLK 写锁覆盖字节 [0,100)；
     *   2. B 对重叠区间 [50,200) 调 F_GETLK；
     *   3. 校验 l_type/l_pid 等 conflict 字段指向 A；
     *   4. 释放锁并退出。
     */
    char path[] = "/tmp/starry_setlk_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        fail("mkstemp: %s", strerror(errno));
    if (write(fd, "x", 1) != 1)
        fail("write: %s", strerror(errno));

    int pfd[2];
    if (pipe(pfd) != 0)
        fail("pipe: %s", strerror(errno));

    pid_t pid = fork();
    if (pid < 0)
        fail("fork: %s", strerror(errno));

    if (pid == 0) {
        close(pfd[0]);
        int a = open(path, O_RDWR);
        if (a < 0)
            fail("child open: %s", strerror(errno));
        struct flock fl = {
            .l_type = F_WRLCK,
            .l_whence = SEEK_SET,
            .l_start = 0,
            .l_len = 100,
        };
        if (fcntl(a, F_SETLK, &fl) != 0)
            fail("child F_SETLK: %s", strerror(errno));
        pid_t me = getpid();
        if (write(pfd[1], &me, sizeof(me)) != (ssize_t)sizeof(me))
            fail("child write pid: %s", strerror(errno));
        close(pfd[1]);
        for (;;)
            pause();
        close(a);
        close(fd);
        exit(0);
    }

    close(pfd[1]);
    pid_t apid;
    if (read(pfd[0], &apid, sizeof(apid)) != (ssize_t)sizeof(apid))
        fail("parent read pid: %s", strerror(errno));

    int b = open(path, O_RDWR);
    if (b < 0)
        fail("parent open: %s", strerror(errno));

    struct flock g = {
        .l_type = F_WRLCK,
        .l_whence = SEEK_SET,
        .l_start = 50,
        .l_len = 150,
    };
    if (fcntl(b, F_GETLK, &g) != 0)
        fail("parent F_GETLK: %s", strerror(errno));
    if (g.l_type == F_UNLCK)
        fail("expected conflict, got F_UNLCK");
    if (g.l_type != F_WRLCK)
        fail("expected F_WRLCK conflict got %d", (int)g.l_type);
    if ((pid_t)g.l_pid != apid)
        fail("expected l_pid %d got %d", (int)apid, (int)g.l_pid);

    if (kill(pid, SIGKILL) != 0)
        fail("kill: %s", strerror(errno));
    if (waitpid(pid, NULL, 0) < 0)
        fail("waitpid: %s", strerror(errno));

    close(b);
    close(pfd[0]);
    close(fd);
    if (unlink(path) != 0)
        fail("unlink: %s", strerror(errno));
    pass();
    return 0;
}
