/*
 * Test: test_execve_fdcloexec
 * Phase: 1, Task: T1
 * Status: SKELETON (functional logic to be filled in by T1 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   open fd 不带 O_CLOEXEC、open fd 带 O_CLOEXEC，execve 后前者保留、后者关闭
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_execve_fdcloexec"

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
    /* TODO(T1): implement actual test
     *
     * Plan:
     *   1. open 两个临时文件，一个无 O_CLOEXEC，一个带 O_CLOEXEC；
     *   2. execve 到辅助程序或自测子 main，传入 fd 编号；
     *   3. 新映像里尝试 fcntl(F_GETFD) 或 write 验证保留/关闭语义；
     *   4. 对照内核行为与 POSIX 期望输出 PASS/FAIL。
     *
     * 当前骨架默认 PASS，等 T1 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
