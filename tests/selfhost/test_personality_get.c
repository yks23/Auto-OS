/*
 * Test: test_personality_get
 * Phase: selfhost, Task: T9
 *
 * Spec: personality(0xFFFFFFFF) returns 0 (PER_LINUX)
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/personality.h>
#include <unistd.h>

#define TEST_NAME "test_personality_get"

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
    unsigned long r = personality(0xffffffffu);
    if (r == (unsigned long)-1 && errno != 0)
        fail("personality: %s", strerror(errno));
    if (r != 0UL)
        fail("personality(QUERY)=%lu want 0", r);
    pass();
}
