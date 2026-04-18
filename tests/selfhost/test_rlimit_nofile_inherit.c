/*
 * Test: test_rlimit_nofile_inherit
 * Phase: 1, Task: T5
 *
 * Spec (from TEST-MATRIX.md):
 *   setrlimit 后 fork，子 getrlimit 同值
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <stdint.h>
#include <string.h>

#define TEST_NAME "test_rlimit_nofile_inherit"

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
    /* TODO(T5): implement actual test
     *
     * Plan:
     *   1. 父 setrlimit NOFILE 到指定值；
     *   2. fork 子进程；
     *   3. 子 getrlimit 读软/硬上限；
     *   4. 与父设置逐字段比较；
     *   5. waitpid 回收子进程。
     */
    const rlim_t want_cur = 55;
    const rlim_t want_max = 60;
    struct rlimit rl = {.rlim_cur = want_cur, .rlim_max = want_max};
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) {
        fail("setrlimit failed: %s", strerror(errno));
    }

    int p[2];
    if (pipe(p) != 0) {
        fail("pipe failed: %s", strerror(errno));
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(p[0]);
        close(p[1]);
        fail("fork failed: %s", strerror(errno));
    }

    if (pid == 0) {
        close(p[0]);
        struct rlimit g;
        if (getrlimit(RLIMIT_NOFILE, &g) != 0) {
            _exit(23);
        }
        unsigned char buf[sizeof(rlim_t) * 2];
        memcpy(buf, &g.rlim_cur, sizeof(rlim_t));
        memcpy(buf + sizeof(rlim_t), &g.rlim_max, sizeof(rlim_t));
        ssize_t w = write(p[1], buf, sizeof buf);
        close(p[1]);
        _exit(w == (ssize_t)sizeof buf ? 0 : 24);
    }

    close(p[1]);
    unsigned char buf[sizeof(rlim_t) * 2];
    ssize_t r = read(p[0], buf, sizeof buf);
    close(p[0]);
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        fail("waitpid failed: %s", strerror(errno));
    }
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fail("child exit status %d", st);
    }
    if (r != (ssize_t)sizeof buf) {
        fail("short read from pipe: %zd", r);
    }
    rlim_t c = 0, m = 0;
    memcpy(&c, buf, sizeof(rlim_t));
    memcpy(&m, buf + sizeof(rlim_t), sizeof(rlim_t));
    if (c != want_cur || m != want_max) {
        fail("child rlimit mismatch: cur=%llu max=%llu (want %llu/%llu)",
             (unsigned long long)c, (unsigned long long)m,
             (unsigned long long)want_cur, (unsigned long long)want_max);
    }

    struct rlimit restore = {.rlim_cur = 4096, .rlim_max = 8192};
    if (setrlimit(RLIMIT_NOFILE, &restore) != 0) {
        fail("setrlimit restore failed: %s", strerror(errno));
    }

    pass();
    return 0;
}
