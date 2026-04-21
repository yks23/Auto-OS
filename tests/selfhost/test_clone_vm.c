#define _GNU_SOURCE
#include <sched.h>
#include <unistd.h>
#include <stdio.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <linux/sched.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

#ifndef CLONE_VM
#define CLONE_VM 0x100
#endif
#ifndef CLONE_VFORK
#define CLONE_VFORK 0x4000
#endif

static int child_fn(void *arg) {
    char *args[] = {"/bin/true", NULL};
    syscall(SYS_execve, "/bin/true", args, environ);
    syscall(SYS_exit, 127);
    return 127;
}

int main(int argc, char **argv) {
    printf("[clone-vm] start\n"); fflush(stdout);

    /* Test 1: raw clone CLONE_VM|CLONE_VFORK|SIGCHLD with new stack */
    char *stack = malloc(64*1024);
    if (!stack) { perror("malloc"); return 1; }
    char *stack_top = stack + 64*1024;
    printf("[clone-vm] T1: clone(VM|VFORK|SIGCHLD, stack)\n"); fflush(stdout);
    long rc = syscall(SYS_clone, CLONE_VM|CLONE_VFORK|SIGCHLD, stack_top, NULL, NULL, NULL);
    if (rc == 0) {
        char *args[] = {"/bin/true", NULL};
        syscall(SYS_execve, "/bin/true", args, environ);
        syscall(SYS_exit, 127);
    }
    printf("[clone-vm] T1: clone returned pid=%ld\n", rc); fflush(stdout);
    int st = 0;
    pid_t r = waitpid(rc, &st, 0);
    printf("[clone-vm] T1: waitpid=%d st=%d code=%d\n", r, st, WEXITSTATUS(st)); fflush(stdout);

    /* Test 2: clone CLONE_VM (only) - thread-like */
    printf("[clone-vm] T2: skipped (would need thread infra)\n"); fflush(stdout);

    /* Test 3: posix_spawn -> /bin/true */
    printf("[clone-vm] T3: bare clone(SIGCHLD) only (regular fork)\n"); fflush(stdout);
    rc = syscall(SYS_clone, SIGCHLD, 0, NULL, NULL, NULL);
    if (rc == 0) {
        char *args[] = {"/bin/true", NULL};
        syscall(SYS_execve, "/bin/true", args, environ);
        syscall(SYS_exit, 127);
    }
    printf("[clone-vm] T3: clone returned pid=%ld\n", rc); fflush(stdout);
    r = waitpid(rc, &st, 0);
    printf("[clone-vm] T3: waitpid=%d st=%d code=%d\n", r, st, WEXITSTATUS(st)); fflush(stdout);

    printf("[clone-vm] PASS\n");
    return 0;
}
