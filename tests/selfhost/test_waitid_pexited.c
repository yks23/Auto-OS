/*
 * Test: test_waitid_pexited
 * Phase: selfhost, Task: T9
 *
 * Spec: child _exit(42); waitid(P_PID, child, &si, WEXITED); si.si_status == 42
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

#define TEST_NAME "test_waitid_pexited"

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
    if (pid == 0)
        _exit(42);

    siginfo_t si;
    memset(&si, 0xab, sizeof(si));
    if (waitid(P_PID, pid, &si, WEXITED) != 0)
        fail("waitid: %s", strerror(errno));
    if (si.si_signo != SIGCHLD)
        fail("si_signo=%d want SIGCHLD", (int)si.si_signo);
    if (si.si_status != 42)
        fail("si_status=%d want 42", (int)si.si_status);
    pass();
}
