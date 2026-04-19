/*
 * Test: test_execve_fdcloexec
 * Phase: 1, Task: T1
 *
 * Spec (from TEST-MATRIX.md):
 *   open fd 不带 O_CLOEXEC、open fd 带 O_CLOEXEC，execve 后前者保留、后者关闭
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>

#define TEST_NAME "test_execve_fdcloexec"

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

static void run_check_phase(int fd_keep, int fd_cloexec)
{
    int fl = fcntl(fd_keep, F_GETFD);
    if (fl < 0)
        fail("fcntl F_GETFD fd_keep: %s", strerror(errno));
    if (fl & FD_CLOEXEC)
        fail("fd_keep unexpectedly has FD_CLOEXEC");

    if (fcntl(fd_cloexec, F_GETFD) >= 0)
        fail("fd_cloexec still open after execve");
    if (errno != EBADF)
        fail("fcntl fd_cloexec expected EBADF, got errno=%d", errno);

    if (close(fd_keep) != 0)
        fail("close fd_keep: %s", strerror(errno));

    pass();
}

int main(int argc, char **argv)
{
    /* TODO(T1): implement actual test
     *
     * Plan:
     *   1. open 两个临时文件，一个无 O_CLOEXEC，一个带 O_CLOEXEC；
     *   2. execve 到辅助程序或自测子 main，传入 fd 编号；
     *   3. 新映像里尝试 fcntl(F_GETFD) 或 write 验证保留/关闭语义；
     *   4. 对照内核行为与 POSIX 期望输出 PASS/FAIL。
     */
    if (argc >= 4 && strcmp(argv[1], "__T1_CHK") == 0) {
        int a = atoi(argv[2]);
        int b = atoi(argv[3]);
        run_check_phase(a, b);
        return 0;
    }

    char selfpath[4096];
    ssize_t nl = readlink("/proc/self/exe", selfpath, sizeof(selfpath) - 1);
    if (nl < 0)
        fail("readlink /proc/self/exe: %s", strerror(errno));
    selfpath[nl] = '\0';

    char tmpl[] = "/tmp/t1ecveXXXXXX";
    int fd_keep = mkstemp(tmpl);
    if (fd_keep < 0)
        fail("mkstemp: %s", strerror(errno));
    if (unlink(tmpl) != 0) {
        close(fd_keep);
        fail("unlink temp: %s", strerror(errno));
    }

    int fl = fcntl(fd_keep, F_GETFD);
    if (fl < 0) {
        close(fd_keep);
        fail("fcntl F_GETFD: %s", strerror(errno));
    }
    if (fcntl(fd_keep, F_SETFD, fl & ~FD_CLOEXEC) < 0) {
        close(fd_keep);
        fail("clear CLOEXEC on fd_keep: %s", strerror(errno));
    }

    char tmpl2[] = "/tmp/t1ecvfXXXXXX";
    int fd_clo = mkstemp(tmpl2);
    if (fd_clo < 0) {
        close(fd_keep);
        fail("mkstemp2: %s", strerror(errno));
    }
    if (unlink(tmpl2) != 0) {
        close(fd_keep);
        close(fd_clo);
        fail("unlink temp2: %s", strerror(errno));
    }
    fl = fcntl(fd_clo, F_GETFD);
    if (fl < 0) {
        close(fd_keep);
        close(fd_clo);
        fail("fcntl fd_clo: %s", strerror(errno));
    }
    if (fcntl(fd_clo, F_SETFD, fl | FD_CLOEXEC) < 0) {
        close(fd_keep);
        close(fd_clo);
        fail("set CLOEXEC: %s", strerror(errno));
    }

    char sa[32], sb[32];
    snprintf(sa, sizeof(sa), "%d", fd_keep);
    snprintf(sb, sizeof(sb), "%d", fd_clo);

    char *const av[] = { selfpath, "__T1_CHK", sa, sb, NULL };
    char *const ep[] = { NULL };

    execve(selfpath, av, ep);

    int e = errno;
    close(fd_keep);
    close(fd_clo);
    fail("execve failed: %s", strerror(e));
}
