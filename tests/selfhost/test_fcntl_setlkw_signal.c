/*
 * Test: test_fcntl_setlkw_signal
 * Phase: 1, Task: T2
 * Status: SKELETON (functional logic to be filled in by T2 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   F_SETLKW 阻塞时收到 SIGUSR1，返回 EINTR
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_fcntl_setlkw_signal"

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
     *   1. 安装 SIGUSR1 空处理或标记；
     *   2. 线程/子进程先占互斥锁，使父 F_SETLKW 阻塞；
     *   3. 另一上下文向阻塞线程发 SIGUSR1；
     *   4. 确认 fcntl 返回 -1 且 errno==EINTR；
     *   5. 恢复锁状态与信号掩码。
     *
     * 当前骨架默认 PASS，等 T2 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
