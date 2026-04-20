/*
 * Test: test_execveat_dirfd
 * Phase: 1, Task: T1
 *
 * Spec (from TEST-MATRIX.md):
 *   用 `openat(AT_FDCWD, "/bin", O_DIRECTORY)` 的 fd 调 `execveat(fd, "echo", ...)` 成功
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
#include <sys/syscall.h>

/* musl 11.2 没有 execveat() libc wrapper，直接 syscall */
static int execveat(int dirfd, const char *pathname, char *const argv[],
                    char *const envp[], int flags) {
    return syscall(SYS_execveat, dirfd, pathname, argv, envp, flags);
}

#define TEST_NAME "test_execveat_dirfd"

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
    /* TODO(T1): implement actual test
     *
     * Plan:
     *   1. openat(AT_FDCWD, "/bin", O_DIRECTORY|O_RDONLY) 得到 dirfd；
     *   2. execveat(dirfd, "echo", argv, envp, 0) 或等价标志；
     *   3. 确认执行成功并收集退出状态；
     *   4. 关闭 fd，错误用 fail()。
     */
    int dirfd = openat(AT_FDCWD, "/bin", O_RDONLY | O_DIRECTORY);
    if (dirfd < 0)
        fail("openat /bin failed: %s", strerror(errno));

    int pfd[2];
    if (pipe(pfd) != 0) {
        close(dirfd);
        fail("pipe failed: %s", strerror(errno));
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(dirfd);
        close(pfd[0]);
        close(pfd[1]);
        fail("fork failed: %s", strerror(errno));
    }

    if (pid == 0) {
        close(pfd[0]);
        if (dup2(pfd[1], STDOUT_FILENO) < 0)
            _exit(111);
        close(pfd[1]);

        char *const argv[] = { "echo", "ok", NULL };
        char *const envp[] = { NULL };
        if (execveat(dirfd, "echo", argv, envp, 0) < 0)
            _exit(112);
        _exit(113);
    }

    close(dirfd);
    close(pfd[1]);

    char buf[64];
    ssize_t n = read(pfd[0], buf, sizeof(buf) - 1);
    close(pfd[0]);
    if (n < 0)
        fail("read failed: %s", strerror(errno));
    buf[n < 0 ? 0 : (size_t)n] = '\0';

    int st = 0;
    if (waitpid(pid, &st, 0) < 0)
        fail("waitpid failed: %s", strerror(errno));
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
        fail("child exit status unexpected: raw=%d", st);
    if (strstr(buf, "ok") == NULL)
        fail("stdout missing ok, got: %s", buf);

    pass();
    return 0;
}
