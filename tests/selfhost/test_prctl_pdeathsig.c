/*
 * Test: test_prctl_pdeathsig
 * Task: T7 — PR_SET_PDEATHSIG / parent exit delivers signal to child.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define TEST_NAME "test_prctl_pdeathsig"

static volatile sig_atomic_t caught;

static void on_usr1(int signo) {
    (void)signo;
    caught = 1;
}

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
    if (pid < 0) {
        fail("fork: %s", strerror(errno));
    }
    if (pid == 0) {
        struct sigaction sa;
        sa.sa_handler = on_usr1;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        if (sigaction(SIGUSR1, &sa, NULL) != 0) {
            fail("sigaction: %s", strerror(errno));
        }
        if (prctl(PR_SET_PDEATHSIG, SIGUSR1) != 0) {
            fail("PR_SET_PDEATHSIG: %s", strerror(errno));
        }
        /* Parent exits shortly after; we wait for possible delivery. */
        for (int i = 0; i < 200 && !caught; i++) {
            usleep(10000);
        }
        if (!caught) {
            fail("expected SIGUSR1 after parent exit");
        }
        pass();
        return 0;
    }

    usleep(200000);
    _exit(0);
}
