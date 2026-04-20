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

C_SRCS := $(filter-out test_pipe_bisect.c test_fork_exec_bisect.c,$(wildcard test_*.c))

C_BINS := $(patsubst %.c,$(OUT)/%,$(C_SRCS))

SH_SRCS := $(filter test_%.sh,$(wildcard test_*.sh))
SH_SRCS_OLD := \
	test_mount_ext4_basic.sh \
	test_mount_bind_dir.sh \
	test_mount_9p_optional.sh \
	test_qemu_mem.sh \
	test_qemu_smp.sh

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
