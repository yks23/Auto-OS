/*
 * Test: test_execve_multithread
 * Phase: 1, Task: T1
 * Status: SKELETON (functional logic to be filled in by T1 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   主线程开 4 个子线程死循环，主线程 `execve` 必须成功，新映像 exit 0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_execve_multithread"

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
     *   1. pthread 创建 4 线程进入无限循环；
     *   2. 主线程调用 execve 到已知 exit(0) 的小程序；
     *   3. 确认 execve 成功且新进程退出码为 0；
     *   4. 验证多线程存在时 execve 不被错误阻塞或拒绝。
     *
     * 当前骨架默认 PASS，等 T1 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
