/*
 * Test: test_openat2_basic
 * Phase: selfhost, Task: T9
 *
 * Spec: openat2(AT_FDCWD, "/etc/hostname", open_how{O_RDONLY}, sizeof how) >= 0
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define TEST_NAME "test_openat2_basic"

struct open_how {
    uint64_t flags;
    uint64_t mode;
    uint64_t resolve;
};

#ifndef __NR_openat2
#if defined(__x86_64__)
#define __NR_openat2 437
#elif defined(__riscv) && __riscv_xlen == 64
#define __NR_openat2 437
#else
#error "define __NR_openat2 for this arch"
#endif
#endif

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
    struct open_how how = {.flags = O_RDONLY, .mode = 0, .resolve = 0};
    int fd = (int)syscall(__NR_openat2, AT_FDCWD, "/etc/hostname", &how, sizeof(how));
    if (fd < 0)
        fail("openat2: %s", strerror(errno));
    close(fd);
    pass();
}
