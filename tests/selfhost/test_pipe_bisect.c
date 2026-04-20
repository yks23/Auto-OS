/*
 * F-γ：pipe + dup2 + execve 三阶段 bisect（-DSTAGE=1|2|3 → test_pipe_bisect_{1,2,3}）
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

#ifndef STAGE
#error STAGE must be set to 1, 2, or 3 when compiling this file
#endif

static void chain_next(int n)
{
	char path[96];
	snprintf(path, sizeof path, "/opt/selfhost-tests/test_pipe_bisect_%d", n);
	execl(path, path, (char *)NULL);
	dprintf(2, "execl %s: %s\n", path, strerror(errno));
	_exit(126);
}

static void step1(void)
{
	int pfd[2];
	if (pipe(pfd) != 0) {
		perror("pipe");
		_exit(1);
	}
	pid_t p = fork();
	if (p < 0) {
		perror("fork");
		_exit(1);
	}
	if (p == 0) {
		close(pfd[0]);
		if (write(pfd[1], "x", 1) != 1)
			_exit(2);
		close(pfd[1]);
		_exit(0);
	}
	close(pfd[1]);
	char c;
	ssize_t n = read(pfd[0], &c, 1);
	close(pfd[0]);
	int ws = 0;
	waitpid(p, &ws, 0);
	printf("[BISECT-PIPE-1] read=%zd c=%c wait_ok\n", n, n == 1 ? c : '?');
	fflush(stdout);
}

static void step2(void)
{
	int pfd[2];
	if (pipe(pfd) != 0) {
		perror("pipe");
		_exit(1);
	}
	pid_t p = fork();
	if (p < 0) {
		perror("fork");
		_exit(1);
	}
	if (p == 0) {
		close(pfd[0]);
		if (dup2(pfd[1], STDOUT_FILENO) < 0)
			_exit(10);
		close(pfd[1]);
		if (write(STDOUT_FILENO, "y", 1) != 1)
			_exit(11);
		_exit(0);
	}
	close(pfd[1]);
	char c;
	ssize_t n = read(pfd[0], &c, 1);
	close(pfd[0]);
	int ws = 0;
	waitpid(p, &ws, 0);
	printf("[BISECT-PIPE-2] read=%zd c=%c\n", n, n == 1 ? c : '?');
	fflush(stdout);
}

static void step3(void)
{
	int pfd[2];
	if (pipe(pfd) != 0) {
		perror("pipe");
		_exit(1);
	}
	pid_t p = fork();
	if (p < 0) {
		perror("fork");
		_exit(1);
	}
	if (p == 0) {
		close(pfd[0]);
		if (dup2(pfd[1], STDOUT_FILENO) < 0)
			_exit(20);
		close(pfd[1]);
		char *const argv[] = { "echo", "hi", NULL };
		char *const envp[] = { NULL };
		execve("/bin/echo", argv, envp);
		_exit(99);
	}
	close(pfd[1]);
	char buf[64];
	ssize_t n = read(pfd[0], buf, sizeof buf - 1);
	close(pfd[0]);
	int ws = 0;
	waitpid(p, &ws, 0);
	if (n < 0)
		n = 0;
	buf[n] = '\0';
	printf("[BISECT-PIPE-3] read=%zd buf=%.*s ws=0x%x\n", n, (int)n, buf, (unsigned)ws);
	fflush(stdout);
}

int main(void)
{
#if STAGE == 1
	step1();
	chain_next(2);
#elif STAGE == 2
	step2();
	chain_next(3);
#elif STAGE == 3
	step3();
#else
#error STAGE must be 1, 2, or 3
#endif
	return 0;
}
