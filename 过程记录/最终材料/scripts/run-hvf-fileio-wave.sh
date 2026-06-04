#!/usr/bin/env bash
set -euo pipefail

case_name="${CASE_NAME:-fileio-wave-smp${SMP:-8}-j${JOBS:-8}}"
kernel="${KERNEL:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-hvf-smp8-hvfopt-wake-local-20260524.bin}"
img="${IMG:-/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/rootfs-hvf-cargo-8g.img}"
smp="${SMP:-8}"
jobs="${JOBS:-8}"
mem="${MEM:-4096M}"
task_count="${TASK_COUNT:-4000}"
bytes_per_file="${BYTES_PER_FILE:-4096}"
guest_dir="${GUEST_DIR:-/tmp/fileio-wave}"
readback="${READBACK:-1}"
do_unlink="${DO_UNLINK:-1}"
shard_dirs="${SHARD_DIRS:-0}"
timeout_sec="${TIMEOUT_SEC:-180}"
log_dir="${LOG_DIR:-/Users/txc/code/Auto-OS/过程记录/最终材料/logs}"
stamp="${STAMP:-$(date +%Y%m%dT%H%M%S)}"
log="${LOG:-${log_dir}/hvf-aarch64-${case_name}-${stamp}.log}"

mkdir -p "$log_dir" /tmp/auto-os-hvf

probe_c="/tmp/auto-os-hvf/hvf-fileio-wave-${stamp}.c"
probe_bin="/tmp/auto-os-hvf/hvf-fileio-wave-${stamp}"
cat >"$probe_c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static long now_ms(void) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        return 0;
    }
    return tv.tv_sec * 1000L + tv.tv_usec / 1000L;
}

static int write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            errno = EIO;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

static int read_back_file(const char *path, char *buf, size_t len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return -1;
        }
        if (n == 0) {
            break;
        }
        got += (size_t)n;
    }
    close(fd);
    return got > 0 ? 0 : -1;
}

static int do_one(const char *dir, int idx, const char *payload, char *scratch,
                  size_t bytes, int readback, int do_unlink) {
    char tmp[256];
    char done[256];
    snprintf(tmp, sizeof(tmp), "%s/file-%06d.tmp", dir, idx);
    snprintf(done, sizeof(done), "%s/file-%06d.done", dir, idx);

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open(tmp)");
        return -1;
    }
    if (write_all(fd, payload, bytes) != 0) {
        perror("write");
        close(fd);
        return -1;
    }
    if (close(fd) != 0) {
        perror("close");
        return -1;
    }
    if (rename(tmp, done) != 0) {
        perror("rename");
        return -1;
    }
    if (readback && read_back_file(done, scratch, bytes) != 0) {
        perror("readback");
        return -1;
    }
    if (do_unlink && unlink(done) != 0) {
        perror("unlink");
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 8) {
        fprintf(stderr, "usage: %s DIR COUNT JOBS BYTES READBACK UNLINK SHARD_DIRS\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    int count = atoi(argv[2]);
    int jobs = atoi(argv[3]);
    size_t bytes = (size_t)strtoull(argv[4], NULL, 10);
    int readback = atoi(argv[5]);
    int do_unlink = atoi(argv[6]);
    int shard_dirs = atoi(argv[7]);
    if (count < 0 || jobs <= 0 || bytes == 0 || bytes > (16U << 20)) {
        fprintf(stderr, "bad args count=%d jobs=%d bytes=%zu\n", count, jobs, bytes);
        return 2;
    }

    mkdir(dir, 0777);
    char *payload = malloc(bytes);
    char *scratch = malloc(bytes);
    if (!payload || !scratch) {
        perror("malloc");
        return 2;
    }
    for (size_t i = 0; i < bytes; i++) {
        payload[i] = (char)('A' + (i % 26));
    }

    printf("===FILEIO-WAVE-BEGIN count=%d jobs=%d bytes=%zu dir=%s readback=%d unlink=%d shard_dirs=%d===\n",
           count, jobs, bytes, dir, readback, do_unlink, shard_dirs);
    fflush(stdout);

    long start = now_ms();
    pid_t *pids = calloc((size_t)jobs, sizeof(pid_t));
    if (!pids) {
        perror("calloc");
        return 2;
    }

    for (int w = 0; w < jobs; w++) {
        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            return 1;
        }
        if (pid == 0) {
            int local_count = 0;
            char worker_dir[256];
            const char *target_dir = dir;
            if (shard_dirs) {
                snprintf(worker_dir, sizeof(worker_dir), "%s/worker-%02d", dir, w);
                mkdir(worker_dir, 0777);
                target_dir = worker_dir;
            }
            for (int i = w; i < count; i += jobs) {
                if (do_one(target_dir, i, payload, scratch, bytes, readback, do_unlink) != 0) {
                    fprintf(stderr, "worker=%d failed index=%d\n", w, i);
                    _exit(1);
                }
                local_count++;
            }
            printf("===FILEIO-WORKER-DONE worker=%d count=%d===\n", w, local_count);
            fflush(stdout);
            _exit(0);
        }
        pids[w] = pid;
    }

    int rc = 0;
    for (int w = 0; w < jobs; w++) {
        int status = 0;
        if (waitpid(pids[w], &status, 0) < 0) {
            perror("waitpid");
            rc = 1;
            continue;
        }
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            fprintf(stderr, "worker=%d status=0x%x\n", w, status);
            rc = 1;
        }
    }
    long end = now_ms();
    long elapsed = end - start;
    printf("===FILEIO-WAVE-END rc=%d elapsed_ms=%ld elapsed=%ld===\n", rc, elapsed, (elapsed + 999) / 1000);
    if (rc == 0) {
        printf("===FILEIO-WAVE-PASS elapsed_ms=%ld elapsed=%ld===\n", elapsed, (elapsed + 999) / 1000);
    } else {
        printf("===FILEIO-WAVE-FAIL rc=%d elapsed_ms=%ld elapsed=%ld===\n", rc, elapsed, (elapsed + 999) / 1000);
    }
    return rc;
}
EOF

/opt/homebrew/bin/zig cc -target aarch64-linux-musl -O2 -static "$probe_c" -o "$probe_bin"

guest_auto="/tmp/auto-os-hvf/hvf-fileio-auto-${stamp}.sh"
cat >"$guest_auto" <<EOF
#!/bin/sh
set -u
echo "===FILEIO-WAVE-AUTO-BEGIN==="
echo "cpu_count=\$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
rm -rf "$guest_dir"
mkdir -p "$guest_dir"
/opt/hvf-fileio-wave "$guest_dir" "$task_count" "$jobs" "$bytes_per_file" "$readback" "$do_unlink" "$shard_dirs"
rc=\$?
echo "===FILEIO-WAVE-AUTO-END rc=\$rc==="
exit "\$rc"
EOF
chmod +x "$guest_auto"

debugfs_cmd="/tmp/auto-os-hvf/debugfs-fileio-wave-${stamp}.cmd"
cat >"$debugfs_cmd" <<EOF
rm /opt/hvf-auto.sh
rm /opt/hvf-fileio-wave
write $guest_auto /opt/hvf-auto.sh
write $probe_bin /opt/hvf-fileio-wave
sif /opt/hvf-auto.sh mode 0100755
sif /opt/hvf-fileio-wave mode 0100755
EOF
/opt/homebrew/opt/e2fsprogs/sbin/debugfs -w -f "$debugfs_cmd" "$img" >/tmp/auto-os-hvf/debugfs-fileio-wave.out 2>&1 || {
  cat /tmp/auto-os-hvf/debugfs-fileio-wave.out
  exit 1
}

echo "log=$log"
echo "case=$case_name smp=$smp jobs=$jobs count=$task_count bytes=$bytes_per_file dir=$guest_dir readback=$readback unlink=$do_unlink shard_dirs=$shard_dirs timeout_sec=$timeout_sec kernel=$kernel"

/opt/homebrew/bin/qemu-system-aarch64 \
  -snapshot \
  -nographic \
  -accel hvf \
  -machine virt,gic-version=3 \
  -cpu host \
  -m "$mem" \
  -smp "$smp" \
  -device virtio-blk-pci,drive=disk0 \
  -drive "id=disk0,if=none,format=raw,file=$img,file.locking=off" \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  -kernel "$kernel" \
  -monitor none \
  -serial mon:stdio \
  >"$log" 2>&1 &

qemu_pid=$!
start_epoch="$(date +%s)"
deadline=$((start_epoch + timeout_sec))
rc=124
while kill -0 "$qemu_pid" 2>/dev/null; do
  if grep -qa '===FILEIO-WAVE-PASS' "$log"; then
    rc=0
    break
  fi
  if grep -qa '===FILEIO-WAVE-FAIL' "$log"; then
    rc=1
    break
  fi
  if grep -qaiE 'panicked at|Kernel panic|Unhandled trap|Segmentation fault|FATAL' "$log"; then
    rc=1
    break
  fi
  now_epoch="$(date +%s)"
  if [ "$now_epoch" -ge "$deadline" ]; then
    rc=124
    break
  fi
  sleep 1
done

if kill -0 "$qemu_pid" 2>/dev/null; then
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
else
  wait "$qemu_pid" || rc=$?
fi

grep -aE 'smp =|cpu_count=|FILEIO-WAVE|FILEIO-WORKER|panicked at|Kernel panic|Unhandled trap|Segmentation fault|FATAL' "$log" | tail -160 || true
exit "$rc"
