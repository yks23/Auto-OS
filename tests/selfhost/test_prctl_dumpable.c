/*
 * Test: test_prctl_dumpable
 * Task: T7 — PR_GET/SET_DUMPABLE
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define TEST_NAME "test_prctl_dumpable"

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
    int v = prctl(PR_GET_DUMPABLE);
    if (v < 0) {
        fail("PR_GET_DUMPABLE: %s", strerror(errno));
    }
    if (v != 1) {
        fail("expected default dumpable 1, got %d", v);
    }
    if (prctl(PR_SET_DUMPABLE, 0) != 0) {
        fail("PR_SET_DUMPABLE 0: %s", strerror(errno));
    }
    v = prctl(PR_GET_DUMPABLE);
    if (v != 0) {
        fail("expected dumpable 0 after SET 0, got %d", v);
    }
    if (prctl(PR_SET_DUMPABLE, 2) != 0) {
        fail("PR_SET_DUMPABLE 2: %s", strerror(errno));
    }
    v = prctl(PR_GET_DUMPABLE);
    if (v != 2) {
        fail("expected dumpable 2 after SET 2, got %d", v);
    }
    pass();
    return 0;
}
