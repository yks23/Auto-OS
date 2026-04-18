/*
 * Test: test_execve_basic
 * Phase: 1, Task: T1
 * Status: SKELETON (functional logic to be filled in by T1 implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   单线程 `execve("/bin/echo", {"echo","ok"}, ...)` exit 0，stdout 含 "ok"
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

#define TEST_NAME "test_execve_basic"

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
     *   1. 准备 argv/envp，指向 /bin/echo 与参数 ok；
     *   2. execve 后在新映像里读 stdout（或父 wait 子）确认输出；
     *   3. 校验 exit status == 0；
     *   4. 失败路径用 fail() 打印原因。
     *
     * 当前骨架默认 PASS，等 T1 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
