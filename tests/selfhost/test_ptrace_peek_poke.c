/* PTRACE_ATTACH + PEEKDATA/POKEDATA on child buffer. */
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
	int fd[2];
	if (pipe(fd) != 0) {
		perror("pipe");
		return 1;
	}
	volatile char secret[] = "hello";
	pid_t pid = fork();
	if (pid == 0) {
		close(fd[0]);
		uintptr_t p = (uintptr_t)(void *)secret;
		if (write(fd[1], &p, sizeof(p)) != (ssize_t)sizeof(p)) {
			_exit(10);
		}
		close(fd[1]);
		while (1) {
			pause();
		}
	}
	close(fd[1]);
	uintptr_t addr = 0;
	if (read(fd[0], &addr, sizeof(addr)) != (ssize_t)sizeof(addr)) {
		perror("read");
		return 2;
	}
	close(fd[0]);

	if (ptrace(PTRACE_ATTACH, pid, NULL, NULL) != 0) {
		perror("attach");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return 3;
	}
	int st = 0;
	if (waitpid(pid, &st, __WALL | WUNTRACED) != pid) {
		perror("waitpid attach");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return 4;
	}
	if (!WIFSTOPPED(st)) {
		fprintf(stderr, "expected stopped after attach\n");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return 5;
	}

	long w = ptrace(PTRACE_PEEKDATA, pid, (void *)(addr & ~(sizeof(long) - 1)), NULL);
	if (w < 0) {
		perror("peek");
		ptrace(PTRACE_DETACH, pid, NULL, NULL);
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return 6;
	}
	unsigned char buf[sizeof(long)];
	memcpy(buf, &w, sizeof(buf));
	size_t off = (size_t)(addr & (sizeof(long) - 1));
	if (memcmp(buf + off, "hello", 5) != 0) {
		fprintf(stderr, "peek mismatch\n");
		ptrace(PTRACE_DETACH, pid, NULL, NULL);
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return 7;
	}

	unsigned long val = (unsigned long)w;
	unsigned char *bp = (unsigned char *)&val;
	bp[off] = 'J';
	if (ptrace(PTRACE_POKEDATA, pid, (void *)(addr & ~(sizeof(long) - 1)),
		   (void *)(uintptr_t)val) != 0) {
		perror("poke");
		ptrace(PTRACE_DETACH, pid, NULL, NULL);
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return 8;
	}
	w = ptrace(PTRACE_PEEKDATA, pid, (void *)(addr & ~(sizeof(long) - 1)), NULL);
	memcpy(buf, &w, sizeof(buf));
	if (buf[off] != 'J' || memcmp(buf + off + 1, "ello", 4) != 0) {
		fprintf(stderr, "poke mismatch\n");
		ptrace(PTRACE_DETACH, pid, NULL, NULL);
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return 9;
	}

	ptrace(PTRACE_DETACH, pid, NULL, (void *)(uintptr_t)SIGCONT);
	kill(pid, SIGKILL);
	waitpid(pid, NULL, 0);
	return 0;
}
