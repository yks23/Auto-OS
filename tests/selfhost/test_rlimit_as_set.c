/*
 * Test: test_rlimit_as_set
 * Phase: 1, Task: T5
 *
 * Spec (from TEST-MATRIX.md):
 *   setrlimit AS=128MB，mmap 200MB 必须 ENOMEM
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

#define TEST_NAME "test_rlimit_as_set"

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
    /* TODO(T5): implement actual test
     *
     * Plan:
     *   1. setrlimit RLIMIT_AS 为 128MiB；
     *   2. mmap 匿名 200MiB PROT_READ|WRITE；
     *   3. 期望返回 MAP_FAILED 且 errno==ENOMEM；
     */
    struct rlimit old_as;
    if (getrlimit(RLIMIT_AS, &old_as) != 0) {
        fail("getrlimit AS failed: %s", strerror(errno));
    }

    struct rlimit rl = {.rlim_cur = 128u * 1024u * 1024u, .rlim_max = 128u * 1024u * 1024u};
    if (setrlimit(RLIMIT_AS, &rl) != 0) {
        fail("setrlimit failed: %s", strerror(errno));
    }

    size_t sz = 200u * 1024u * 1024u;
    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p != MAP_FAILED) {
        munmap(p, sz);
        fail("mmap 200MiB unexpectedly succeeded under RLIMIT_AS=128MiB");
    }
    if (errno != ENOMEM) {
        fail("mmap failed with errno=%d (%s), expected ENOMEM", errno, strerror(errno));
    }

    if (setrlimit(RLIMIT_AS, &old_as) != 0) {
        fail("setrlimit restore AS failed: %s", strerror(errno));
    }

    pass();
    return 0;
}
