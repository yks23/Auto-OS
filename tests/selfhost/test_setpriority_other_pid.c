/*
 * Test: test_setpriority_other_pid
 * Phase: selfhost, Task: T9
 *
 * Spec: fork → child sleep; parent setpriority(PRIO_PROCESS, child, 10);
 *       getpriority(PRIO_PROCESS, child) reflects new nice (+20 offset).
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

#define TEST_NAME "test_setpriority_other_pid"

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
    pid_t pid = fork();
    if (pid < 0)
        fail("fork: %s", strerror(errno));
    if (pid == 0) {
        sleep(60);
        _exit(0);
    }

    if (setpriority(PRIO_PROCESS, (id_t)pid, 10) != 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        fail("setpriority: %s", strerror(errno));
    }

    int g = getpriority(PRIO_PROCESS, (id_t)pid);
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);

    if (g != 10 + 20)
        fail("getpriority got %d want %d", g, 10 + 20);
    pass();
}
