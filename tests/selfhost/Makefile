# Self-host Phase 1 tests: static musl binaries + shell helpers.
#
# Usage:
#   make ARCH=x86_64
#   make ARCH=riscv64
#   make clean
#   make ARCH=x86_64 clean

ARCH ?= x86_64

ifeq ($(ARCH),x86_64)
  MUSL_CC := x86_64-linux-musl-gcc
else ifeq ($(ARCH),riscv64)
  MUSL_CC := riscv64-linux-musl-gcc
else
  $(error Unsupported ARCH='$(ARCH)'. Use x86_64 or riscv64.)
endif

OUT := out-$(ARCH)

CFLAGS := -static -O0 -Wall -Wextra -Wno-unused-parameter

C_SRCS := \
	test_execve_basic.c \
	test_execve_multithread.c \
	test_execveat_dirfd.c \
	test_execve_fdcloexec.c \
	test_flock_excl_block.c \
	test_flock_nonblock.c \
	test_flock_shared.c \
	test_flock_close_release.c \
	test_fcntl_setlk_overlap.c \
	test_fcntl_setlkw_signal.c \
	test_fcntl_ofd_fork.c \
	test_fcntl_unknown_cmd.c \
	test_ipv6_socket_basic.c \
	test_ipv6_bind_getsockname.c \
	test_ipv6_v4mapped_loopback.c \
	test_ipv6_pure_v6_unreach.c \
	test_ipv6_v6only_setsockopt.c \
	test_mount_unknown_fstype.c \
	test_umount_busy.c \
	test_umount_force.c \
	test_rlimit_stack_default.c \
	test_rlimit_stack_alloca.c \
	test_rlimit_nofile_set.c \
	test_rlimit_nofile_inherit.c \
	test_rlimit_as_set.c \
	test_rlimit_data_brk.c \
	test_proc_self_exe.c

C_BINS := $(patsubst %.c,$(OUT)/%,$(C_SRCS))

SH_SRCS := \
	test_mount_ext4_basic.sh \
	test_mount_bind_dir.sh \
	test_mount_9p_optional.sh \
	test_qemu_mem.sh \
	test_qemu_smp.sh \
	test_proc_cpuinfo.sh \
	test_proc_meminfo.sh \
	test_proc_random_uuid.sh \
	test_proc_loadavg.sh

SH_OUT := $(patsubst %.sh,$(OUT)/%,$(SH_SRCS))

.PHONY: all clean

all: musl-check $(OUT) $(C_BINS) $(SH_OUT)

musl-check:
	@command -v $(MUSL_CC) >/dev/null 2>&1 || { \
		echo "ERROR: musl cross compiler not found: $(MUSL_CC)"; \
		echo "Install a musl cross toolchain and ensure it is on PATH."; \
		echo "Prebuilt toolchains (example): https://musl.cc/"; \
		echo "  x86_64: https://musl.cc/x86_64-linux-musl-cross.tgz"; \
		echo "  riscv64: https://musl.cc/riscv64-linux-musl-cross.tgz"; \
		exit 127; \
	}

$(OUT):
	mkdir -p "$(OUT)"

$(OUT)/%: %.c
	$(MUSL_CC) $(CFLAGS) -o "$@" "$<"

$(OUT)/%: %.sh
	cp -f "$<" "$@"
	chmod +x "$@"

clean:
	rm -rf "$(OUT)"
