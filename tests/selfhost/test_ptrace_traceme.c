/* PTRACE_TRACEME + execve: parent waitpid must see SIGTRAP (post-exec). */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
	pid_t pid = fork();
	if (pid == 0) {
		if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0) {
			perror("traceme");
			_exit(111);
		}
		execl("/bin/true", "true", (char *)NULL);
		perror("execl");
		_exit(112);
	}
	if (pid < 0) {
		perror("fork");
		return 1;
	}
	int st = 0;
	if (waitpid(pid, &st, __WALL | WUNTRACED) != pid) {
		perror("waitpid");
		return 2;
	}
	if (!WIFSTOPPED(st) || WSTOPSIG(st) != SIGTRAP) {
		fprintf(stderr, "unexpected status st=%d stopped=%d sig=%d\n", st,
			WIFSTOPPED(st), WIFSTOPPED(st) ? WSTOPSIG(st) : -1);
		return 3;
	}
	return 0;
}
