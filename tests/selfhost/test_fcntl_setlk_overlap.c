/*
 * Test: test_fcntl_setlk_overlap
 * Phase: 1, Task: T2
 * Status: SKELETON (functional logic to be filled in by T2 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   进程 A 锁 [0,100) W，进程 B `F_GETLK` [50,200) 看到 conflict 信息
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_fcntl_setlk_overlap"

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
     *   1. A 用 struct flock F_SETLK 写锁覆盖字节 [0,100)；
     *   2. B 对重叠区间 [50,200) 调 F_GETLK；
     *   3. 校验 l_type/l_pid 等 conflict 字段指向 A；
     *   4. 释放锁并退出。
     *
     * 当前骨架默认 PASS，等 T2 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
