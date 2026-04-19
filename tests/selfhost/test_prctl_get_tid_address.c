/*
 * Test: test_prctl_get_tid_address
 * Task: T7 — PR_GET_TID_ADDRESS matches set_tid_address
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define TEST_NAME "test_prctl_get_tid_address"

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
    int tid_word = 0;
    long st = syscall(SYS_set_tid_address, &tid_word);
    if (st < 0) {
        fail("set_tid_address: %s", strerror(errno));
    }
    (void)st;
    unsigned long got = (unsigned long)prctl(PR_GET_TID_ADDRESS, 0, 0, 0, 0);
    if (got != (unsigned long)(uintptr_t)(void *)&tid_word) {
        fail("PR_GET_TID_ADDRESS %p != &tid_word %p", (void *)got, (void *)&tid_word);
    }
    pass();
    return 0;
}
