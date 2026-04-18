/*
 * Test: test_flock_excl_block
 * Phase: 1, Task: T2
 * Status: SKELETON (functional logic to be filled in by T2 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   子进程拿 LOCK_EX，父进程 LOCK_EX 阻塞；子 close 后父立刻拿到
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_flock_excl_block"

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
     *   1. 父子各 open 同一文件；子 flock(LOCK_EX)；
     *   2. 父记录时间戳后 flock(LOCK_EX) 应阻塞；
     *   3. 子进程 sleep 后 close(fd) 释放锁；
     *   4. 父进程应在子 close 后很快返回成功；
     *   5. 用超时/线程或管道同步验证阻塞与解除顺序。
     *
     * 当前骨架默认 PASS，等 T2 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
