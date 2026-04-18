# T-skel：Phase 1 测试用例骨架（D4 任务）

## 目标仓库
- **工作仓**：`https://github.com/yks23/Auto-OS`（你 push 到这里）
- **PR 目标**：`yks23/Auto-OS` 的 `main` 分支
- **交付物**：`tests/selfhost/test_*.c` 与 `test_*.sh` 骨架文件 + `tests/selfhost/Makefile`

## 背景

按 `selfhost-orchestrator/TEST-MATRIX.md` 与 `ROADMAP.md`，Phase 1 有 5 个并发任务（T1-T5），每个都需要附带测试。直接让 5 个 subagent 各自从零写测试容易出现：
- 输出格式不统一
- 跨架构编译失败
- 数量偷工

**你的任务**：在 fan-out Phase 1 之前，先把 Phase 1 全部 ~30 个测试用例的**骨架**写出来。骨架 = 编译能过、main 能 link、有标准 `[TEST] <name> PASS|FAIL: <reason>` 输出格式、但**功能验证留空（写 TODO 或最简单的占位 PASS）**。等到 T1-T5 的 subagent 实现对应内核功能时，他们只需要把测试逻辑填进骨架，不必从零起。

## 你必须创建的文件

### Phase 1 测试用例骨架（按 TEST-MATRIX.md §Phase 1 列表全套创建）

T1 多线程 execve（4 个）：
- `tests/selfhost/test_execve_basic.c`
- `tests/selfhost/test_execve_multithread.c`
- `tests/selfhost/test_execveat_dirfd.c`
- `tests/selfhost/test_execve_fdcloexec.c`

T2 文件锁（8 个）：
- `tests/selfhost/test_flock_excl_block.c`
- `tests/selfhost/test_flock_nonblock.c`
- `tests/selfhost/test_flock_shared.c`
- `tests/selfhost/test_flock_close_release.c`
- `tests/selfhost/test_fcntl_setlk_overlap.c`
- `tests/selfhost/test_fcntl_setlkw_signal.c`
- `tests/selfhost/test_fcntl_ofd_fork.c`
- `tests/selfhost/test_fcntl_unknown_cmd.c`

T3 IPv6 socket（5 个）：
- `tests/selfhost/test_ipv6_socket_basic.c`
- `tests/selfhost/test_ipv6_bind_getsockname.c`
- `tests/selfhost/test_ipv6_v4mapped_loopback.c`
- `tests/selfhost/test_ipv6_pure_v6_unreach.c`
- `tests/selfhost/test_ipv6_v6only_setsockopt.c`

T4 mount（6 个，含 .sh）：
- `tests/selfhost/test_mount_ext4_basic.sh`
- `tests/selfhost/test_mount_unknown_fstype.c`
- `tests/selfhost/test_mount_bind_dir.sh`
- `tests/selfhost/test_umount_busy.c`
- `tests/selfhost/test_umount_force.c`
- `tests/selfhost/test_mount_9p_optional.sh`

T5 资源限制（8 个）：
- `tests/selfhost/test_rlimit_stack_default.c`
- `tests/selfhost/test_rlimit_stack_alloca.c`
- `tests/selfhost/test_rlimit_nofile_set.c`
- `tests/selfhost/test_rlimit_nofile_inherit.c`
- `tests/selfhost/test_rlimit_as_set.c`
- `tests/selfhost/test_rlimit_data_brk.c`
- `tests/selfhost/test_qemu_mem.sh`
- `tests/selfhost/test_qemu_smp.sh`

### 一份 Makefile

`tests/selfhost/Makefile`，能：
- `make ARCH=x86_64`：用 `x86_64-linux-musl-gcc -static -O0` 把所有 C 测试编出来到 `out-x86_64/`
- `make ARCH=riscv64`：同上 `riscv64-linux-musl-`
- `make clean` / `make ARCH=... clean`
- 检测 musl-gcc 不在 PATH 时给出**清晰的错误**与下载提示
- `.sh` 文件复制到 `out-<arch>/` 并 `chmod +x`

### 一个 README

`tests/selfhost/PHASE1.md`：列出 Phase 1 所有测试用例索引，每个一行写"骨架已就位 / 等待 T<N> 填充功能"。

## 骨架代码规范（每个 .c 必须长这样）

```c
/*
 * Test: <name>
 * Phase: 1, Task: T<N>
 * Status: SKELETON (functional logic to be filled in by T<N> implementer)
 *
 * Spec (from TEST-MATRIX.md):
 *   <把 TEST-MATRIX.md 里这个测试的"预期"原文复制进来>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
/* 其他必要 header */

#define TEST_NAME "<name>"

static void pass(void) {
    printf("[TEST] %s PASS\n", TEST_NAME);
    exit(0);
}

static void fail(const char *fmt, ...) {
    va_list ap;
    printf("[TEST] %s FAIL: ", TEST_NAME);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    exit(1);
}

int main(void) {
    /* TODO(T<N>): implement actual test
     *
     * Plan:
     *   1. <一句话步骤>
     *   2. <一句话步骤>
     *   ...
     *
     * 当前骨架默认 PASS，等 T<N> 实现者把上面 TODO 替换为真实验证逻辑。
     */
    pass();
    return 0;
}
```

`fail()` 用 `va_list` 是为了支持格式化参数。如果你担心 `<stdarg.h>` 兼容性问题，可以提供两个 `fail` 重载（`fail_msg(const char*)` + 复杂版本），但**统一**最重要。

`.sh` 骨架统一格式：

```sh
#!/bin/sh
# Test: <name>
# Phase: 1, Task: T<N>
# Status: SKELETON
#
# Spec: <从 TEST-MATRIX.md 复制>
TEST_NAME="<name>"

# TODO(T<N>): implement actual checks
# Plan:
#   1. ...

echo "[TEST] $TEST_NAME PASS"
exit 0
```

## 验收标准（acceptance criteria）

1. **文件齐全**：上面列出的 31 个测试文件 + Makefile + PHASE1.md 全部存在。
2. **格式统一**：每个 .c 都用上面规范的模板（标准 header、TEST_NAME、pass/fail 函数、TODO 注释含步骤、main 默认 pass()）。
3. **从 TEST-MATRIX.md 复制 Spec**：每个文件顶部 spec 注释必须从 TEST-MATRIX.md 对应 Phase 1 行的"预期"列原样复制（不要自己改写）。
4. **TODO 步骤具体**：每个文件的 TODO 必须列 **2-5 步具体计划**，不是空话（例如 `test_flock_excl_block` 的 TODO 必须写明"open + flock LOCK_EX + fork + 子等待 + 父尝试 LOCK_EX 阻塞 + 子 close + 父拿到锁"这种步骤）。
5. **Makefile 可用**：在 host 上 `cd tests/selfhost && make ARCH=x86_64`（如 musl-gcc 在 PATH）必须能编出 `out-x86_64/test_*` 全部产物。**如果 host 没装 musl-gcc，Makefile 必须打印清晰的 error 与下载链接，但不要 fail silently**。
6. **musl headers 兼容**：所有 .c 仅用 musl 标准 header（不依赖 glibc 扩展），用 `-static` 编。
7. **不要碰 patches/ 或 scripts/**：你只动 `tests/selfhost/`。
8. **单 commit 或拆 commit 都行**：建议 1 个 commit "test(selfhost): phase-1 test skeletons (31 cases)" + 1 个 commit "test(selfhost): add Makefile and PHASE1 index"。

## 提交策略

1. `cd <你的 worktree>`，确认在 Auto-OS 仓的任务分支上。
2. 创建上述所有文件。
3. 本地验证：
   - `python3 -c "import os; ... 列出 tests/selfhost/test_*.{c,sh} 数量 == 31"`
   - 试 `cd tests/selfhost && make ARCH=x86_64`（musl-gcc 不在没关系，看是不是优雅 fallback）
4. `git add tests/selfhost/`
5. `git commit -m "test(selfhost): phase-1 test skeletons (31 cases)"`
6. `git commit -m "test(selfhost): add Makefile and PHASE1 index"`（如果分两个 commit）
7. `git push -u origin <branch>`
8. `gh pr create --base main --head <branch> --repo yks23/Auto-OS --title "test(selfhost): Phase 1 test skeletons (31 cases)" --body "..."`

PR body 必须含：
- 文件清单
- "下一步：T1-T5 的实现者填 TODO"
- acceptance criteria 自检表

## 输出格式（最后一条消息）

```json
{
  "task_id": "T-skel",
  "auto_os_branch": "<branch>",
  "files_created": ["tests/selfhost/test_xxx.c", "..."],
  "n_tests": 31,
  "n_makefile": 1,
  "n_index": 1,
  "auto_os_commits": ["sha1", "..."],
  "pr_url": "https://github.com/yks23/Auto-OS/pull/N",
  "host_make_test": "PASS|SKIP_NO_MUSL|FAIL",
  "acceptance_criteria": [
    {"item": "31 test files exist", "status": "PASS|FAIL", "note": "..."},
    {"item": "spec copied from TEST-MATRIX", "status": "PASS|FAIL", "note": "..."},
    {"item": "TODO has 2-5 concrete steps", "status": "PASS|FAIL", "note": "..."},
    {"item": "Makefile builds with musl-gcc", "status": "PASS|SKIP|FAIL", "note": "..."},
    {"item": "format unified (header/macro/pass/fail)", "status": "PASS|FAIL", "note": "..."}
  ],
  "blocked_by": [],
  "decisions_needed": []
}
```

## 重要提示

- **本任务不动 tgoskits 子模块、不动 patches/、不动 scripts/、不动 .github/。** 只动 `tests/selfhost/`。
- 不要在 `main()` 里写"实际功能验证"——那是 T1-T5 实现者的事。你只搭骨架。
- 但**TODO 注释里的步骤必须详细**——这是给后续 subagent 看的合同。
- 31 个文件中 .sh 共 4 个，其余 27 个 .c。
