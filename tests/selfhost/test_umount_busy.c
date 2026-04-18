/*
 * Test: test_umount_busy
 * Phase: 1, Task: T4
 * Status: SKELETON (functional logic to be filled in by T4 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   open 一个文件，umount 必须 EBUSY；MNT_DETACH 必须成功
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_umount_busy"

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
    /* TODO(T4): implement actual test
     *
     * Plan:
     *   1. 在测试挂载点下 open 文件保持 fd；
     *   2. umount 该点，期望 EBUSY；
     *   3. 使用 MNT_DETACH 标志 umount2 应成功；
     *   4. 关闭 fd 并清理挂载点。
     *
     * 当前骨架默认 PASS，等 T4 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
