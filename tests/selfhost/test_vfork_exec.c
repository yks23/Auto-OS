#include <unistd.h>
#include <sys/wait.h>
#include <stdio.h>
#include <spawn.h>
#include <string.h>
extern char **environ;
int main(int argc, char **argv) {
    printf("[vfork-test] start\n"); fflush(stdout);
    pid_t pid = vfork();
    if (pid == 0) {
        char *args[] = {"/bin/true", NULL};
        execve("/bin/true", args, environ);
        _exit(127);
    } else if (pid > 0) {
        printf("[vfork-test] parent: child pid=%d, waiting\n", pid); fflush(stdout);
        int st = 0;
        pid_t r = waitpid(pid, &st, 0);
        printf("[vfork-test] waitpid=%d, st=%d, exited=%d, code=%d\n",
               r, st, WIFEXITED(st), WEXITSTATUS(st));
    } else {
        perror("vfork"); return 1;
    }
    printf("[vfork-test] now posix_spawn /bin/true\n"); fflush(stdout);
    pid_t p2;
    char *args[] = {"/bin/true", NULL};
    int rc = posix_spawn(&p2, "/bin/true", NULL, NULL, args, environ);
    printf("[vfork-test] posix_spawn rc=%d, child=%d\n", rc, p2); fflush(stdout);
    if (rc == 0) {
        int st = 0;
        pid_t r = waitpid(p2, &st, 0);
        printf("[vfork-test] waitpid2=%d, st=%d\n", r, st);
    }
    printf("[vfork-test] PASS\n");
    return 0;
}
