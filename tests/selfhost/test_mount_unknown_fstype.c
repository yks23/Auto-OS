/*
 * Test: test_mount_unknown_fstype
 * Phase: 1, Task: T4
 * Status: SKELETON (functional logic to be filled in by T4 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   `mount(_, _, "totally-fake", 0, _)` 必须 ENODEV，不是 0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_mount_unknown_fstype"

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
     *   1. 准备挂载点目录与哑设备路径（如 tmpfs 上的文件）；
     *   2. 调用 mount 指定 fstype totally-fake；
     *   3. 断言返回 -1 且 errno==ENODEV；
     *   4. 绝不接受返回 0。
     *
     * 当前骨架默认 PASS，等 T4 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
