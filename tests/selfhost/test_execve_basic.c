/*
 * Test: test_execve_basic
 * Phase: 1, Task: T1
 *
 * Spec (from TEST-MATRIX.md):
 *   单线程 `execve("/bin/echo", {"echo","ok"}, ...)` exit 0，stdout 含 "ok"
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>

#define TEST_NAME "test_execve_basic"

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
     *   1. 准备 argv/envp，指向 /bin/echo 与参数 ok；
     *   2. execve 后在新映像里读 stdout（或父 wait 子）确认输出；
     *   3. 校验 exit status == 0；
     *   4. 失败路径用 fail() 打印原因。
     */
    int pfd[2];
    if (pipe(pfd) != 0)
        fail("pipe failed: %s", strerror(errno));

    pid_t pid = fork();
    if (pid < 0) {
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
        execve("/bin/echo", argv, envp);
        _exit(112);
    }

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
