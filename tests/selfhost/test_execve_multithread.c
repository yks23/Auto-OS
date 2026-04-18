/*
 * Test: test_execve_multithread
 * Phase: 1, Task: T1
 *
 * Spec (from TEST-MATRIX.md):
 *   主线程开 4 个子线程死循环，主线程 `execve` 必须成功，新映像 exit 0
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>

#define TEST_NAME "test_execve_multithread"
#define NWORK 4

static volatile int spin_go = 1;

static void *worker(void *arg)
{
    (void)arg;
    while (spin_go)
        sched_yield();
    return NULL;
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
     * 使用 /bin/sh -c 串联 echo 与 PASS 行，满足 harness 对 PASS 行的解析；
     * 核心仍覆盖主线程在多线程进程中 execve 的路径。
     */
    pthread_t th[NWORK];
    for (int i = 0; i < NWORK; i++) {
        int rc = pthread_create(&th[i], NULL, worker, NULL);
        if (rc != 0)
            fail("pthread_create failed: %s", strerror(rc));
    }

    /* 给 worker 一点时间全部进入循环（无 sleep：依赖调度） */
    for (volatile int j = 0; j < 100000; j++)
        ;

    char *const argv[] = {
        "sh",
        "-c",
        "echo ok && printf '[TEST] test_execve_multithread PASS\\n'",
        NULL,
    };
    char *const envp[] = { NULL };

    execve("/bin/sh", argv, envp);
    spin_go = 0;
    for (int i = 0; i < NWORK; i++)
        pthread_join(th[i], NULL);
    fail("execve failed: %s", strerror(errno));
}
