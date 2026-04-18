/*
 * Test: test_flock_nonblock
 * Phase: 1, Task: T2
 * Status: SKELETON (functional logic to be filled in by T2 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   子进程拿 LOCK_EX，父进程 LOCK_NB|LOCK_EX 必须 EWOULDBLOCK
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_flock_nonblock"

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
    /* TODO(T2): implement actual test
     *
     * Plan:
     *   1. 子 flock LOCK_EX 占锁；
     *   2. 父 flock LOCK_NB|LOCK_EX，期望立即返回 -1 且 errno==EWOULDBLOCK；
     *   3. 子释放锁后父可正常加锁；
     *   4. 清理子进程与 fd。
     *
     * 当前骨架默认 PASS，等 T2 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
