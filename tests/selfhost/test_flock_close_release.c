/*
 * Test: test_flock_close_release
 * Phase: 1, Task: T2
 * Status: SKELETON (functional logic to be filled in by T2 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   close fd 后锁立即释放，另一进程能拿
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_flock_close_release"

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
     *   1. 进程 A open+flock LOCK_EX；
     *   2. 进程 B 尝试加锁应阻塞或失败（视时序）；
     *   3. A close(fd) 不传显式解锁；
     *   4. B 应立即 flock 成功；
     *   5. 无死锁，清理资源。
     *
     * 当前骨架默认 PASS，等 T2 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
