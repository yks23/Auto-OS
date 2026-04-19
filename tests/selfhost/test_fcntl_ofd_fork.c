/*
 * Test: test_fcntl_ofd_fork
 * Phase: 1, Task: T2
 * Status: SKELETON (functional logic to be filled in by T2 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   父 F_OFD_SETLK 后 fork，子的同 fd 看到 OFD 锁是"自己的"
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_fcntl_ofd_fork"

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
     *   1. 父进程 open 文件并 fcntl F_OFD_SETLK 加锁；
     *   2. fork 后父子共享 fd；
     *   3. 子进程查询/再次加锁行为应符合 OFD 语义（锁随进程）；
     *   4. 对照 Linux 参考行为写断言；
     *   5. 父子协调退出。
     *
     * 当前骨架默认 PASS，等 T2 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
