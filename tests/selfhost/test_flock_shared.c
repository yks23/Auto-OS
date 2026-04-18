/*
 * Test: test_flock_shared
 * Phase: 1, Task: T2
 * Status: SKELETON (functional logic to be filled in by T2 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   两个 LOCK_SH 可以共存；其中任一升级 LOCK_EX 阻塞另一个
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_flock_shared"

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
     *   1. 进程 A、B 各 open 同文件并 flock LOCK_SH，应均成功；
     *   2. A 尝试 LOCK_EX 升级，应阻塞直到 B 释放 SH；
     *   3. 或 B 升级阻塞 A，按设计交替验证；
     *   4. 记录 errno 与返回顺序，最后释放全部锁。
     *
     * 当前骨架默认 PASS，等 T2 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
