/* After TRACEME + exec trap, GETREGS PC should land in executable mapping. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>

/* Avoid relying on glibc-only `struct user_regs_struct` headers under musl. */
#if defined(__x86_64__)
enum { USER_REGS_N = 27, PC_WORD = 16 };
#elif defined(__riscv) && __riscv_xlen == 64
enum { USER_REGS_N = 32, PC_WORD = 0 };
#else
#error "unsupported arch for test_ptrace_getregs"
#endif

int main(void) {
	pid_t pid = fork();
	if (pid == 0) {
		if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0) {
			_exit(20);
		}
		execl("/bin/true", "true", (char *)NULL);
		_exit(21);
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
	unsigned long regs[USER_REGS_N];
	memset(regs, 0, sizeof(regs));
	if (ptrace(PTRACE_GETREGS, pid, NULL, regs) != 0) {
		perror("getregs");
		return 4;
	}
	unsigned long pc = regs[PC_WORD];
	if (pc == 0 || pc > 0x7fffffffffffUL) {
		fprintf(stderr, "bad pc %lx\n", pc);
		return 5;
	}
	return 0;
}
