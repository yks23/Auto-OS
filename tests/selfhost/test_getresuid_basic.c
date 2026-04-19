#define _GNU_SOURCE
/*
 * Test: test_getresuid_basic
 * Phase: selfhost, Task: T9
 *
 * Spec: getresuid(&r,&e,&s); three == 0 as root in selfhost guest.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TEST_NAME "test_getresuid_basic"

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
    uid_t r, e, s;
    if (getresuid(&r, &e, &s) != 0)
        fail("getresuid: %s", strerror(errno));
    if (r != 0 || e != 0 || s != 0)
        fail("uids %u %u %u (want 0 0 0)", (unsigned)r, (unsigned)e, (unsigned)s);
    pass();
}
