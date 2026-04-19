/* After exec SIGTRAP, CONT lets child exit; parent sees WEXITED. */
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
			_exit(30);
		}
		execl("/bin/true", "true", (char *)NULL);
		_exit(31);
	}
	if (pid < 0) {
		perror("fork");
		return 1;
	}
	int st = 0;
	if (waitpid(pid, &st, __WALL | WUNTRACED) != pid) {
		return 2;
	}
	if (!WIFSTOPPED(st) || WSTOPSIG(st) != SIGTRAP) {
		return 3;
	}
	if (ptrace(PTRACE_CONT, pid, NULL, NULL) != 0) {
		perror("cont");
		return 4;
	}
	if (waitpid(pid, &st, 0) != pid) {
		return 5;
	}
	if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
		fprintf(stderr, "unexpected exit st=%d exited=%d code=%d\n", st,
			WIFEXITED(st), WIFEXITED(st) ? WEXITSTATUS(st) : -1);
		return 6;
	}
	return 0;
}
