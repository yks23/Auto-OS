/*
 * Test: test_prctl_no_new_privs
 * Task: T7 — PR_SET_NO_NEW_PRIVS cannot be cleared
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define TEST_NAME "test_prctl_no_new_privs"

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
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        fail("PR_SET_NO_NEW_PRIVS 1: %s", strerror(errno));
    }
    int g = prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
    if (g != 1) {
        fail("PR_GET_NO_NEW_PRIVS expected 1, got %d", g);
    }
    errno = 0;
    if (prctl(PR_SET_NO_NEW_PRIVS, 0, 0, 0, 0) != -1) {
        fail("PR_SET_NO_NEW_PRIVS 0 should fail");
    }
    if (errno != EINVAL) {
        fail("expected EINVAL clearing NNP, got errno=%d (%s)", errno, strerror(errno));
    }
    pass();
    return 0;
}
