/*
 * Test: test_prctl_keepcaps
 * Task: T7 — PR_SET/GET_KEEPCAPS no-op path
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define TEST_NAME "test_prctl_keepcaps"

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
    if (prctl(PR_SET_KEEPCAPS, 1) != 0) {
        fail("PR_SET_KEEPCAPS 1: %s", strerror(errno));
    }
    int v = prctl(PR_GET_KEEPCAPS);
    if (v < 0) {
        fail("PR_GET_KEEPCAPS: %s", strerror(errno));
    }
    if (v != 1) {
        fail("expected keepcaps 1 after SET 1, got %d", v);
    }
    if (prctl(PR_SET_KEEPCAPS, 0) != 0) {
        fail("PR_SET_KEEPCAPS 0: %s", strerror(errno));
    }
    v = prctl(PR_GET_KEEPCAPS);
    if (v != 0) {
        fail("expected keepcaps 0 after SET 0, got %d", v);
    }
    pass();
    return 0;
}
