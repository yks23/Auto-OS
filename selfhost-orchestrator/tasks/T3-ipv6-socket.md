# T3：AF_INET6 socket 支持

## 目标仓库
- **工作仓**：`https://github.com/yks23/Auto-OS`（你 push 到这里）
- **tgoskits 子模块**：只读，pin 在 PIN.toml 指定的 commit；**不 push tgoskits**
- **PR 目标**：`yks23/Auto-OS` 的 `main` 分支
- **交付物**：`patches/Tn-slug/*.patch` + `tests/selfhost/test_*.c`
- **你的工作分支**：`cursor/selfhost-ipv6-7c9d`

## 当前缺陷
`tgoskits/os/StarryOS/kernel/src/syscall/net/socket.rs:31-56` 的 `match domain` 没有 `AF_INET6` 分支，导致 `socket(AF_INET6, ...)` 直接 `EAFNOSUPPORT`。

`getaddrinfo` 默认走 dual-stack，cargo registry / crates.io / 多数 git remote 已经 v6-first，guest 拉取 crate 失败。

## 验收标准

### A. 选择实现方案（按可行度从小到大）

**优先方案 A：v6-mapped fallback**（约 100-200 行，本任务首选）
- `socket(AF_INET6, SOCK_STREAM/DGRAM, ...)` 返回真实 socket（内部 sockaddr 用 v6 表示，underlying transport 仍是 v4 only）。
- `bind(sockaddr_in6)`：
  - 若地址是 `::ffff:x.x.x.x`（v6-mapped v4），转换成 v4 调底层 bind。
  - 若是 `::`（任意），按 v4 `0.0.0.0` 处理。
  - 若是真 v6（其他地址），返回 `EADDRNOTAVAIL`。
- `connect(sockaddr_in6)` 同上。
- `getsockname / getpeername` 必须返回 `sockaddr_in6`（即使底层是 v4，也要 v6-map 回去），保证 glibc/musl 不混乱。
- `setsockopt(IPPROTO_IPV6, IPV6_V6ONLY, ...)`：可接受 set/get，行为可以是 no-op（始终 dual-stack）。

**方案 B：smoltcp 真 v6**（推荐做但成本高）
- 在 `axnet` 子树启用 smoltcp 的 IPv6 + ICMPv6 feature。
- 需要在 `Cargo.toml` 改 feature flag、补 IPv6 路由表、补 NDP（neighbor discovery）。
- 估算 800-1500 行，跨 `axnet` + `ax-driver` + `kernel/syscall/net`。

**本任务以方案 A 为最低交付，方案 B 列为 stretch goal**。

### B. 必须改的文件

- `tgoskits/os/StarryOS/kernel/src/syscall/net/socket.rs`：加 `AF_INET6` 分支。
- `tgoskits/os/StarryOS/kernel/src/syscall/net/addr.rs`：补 `from_sockaddr_in6`、`to_sockaddr_in6`、v4↔v6-mapped 转换。
- `tgoskits/os/StarryOS/kernel/src/syscall/net/opt.rs`：加 `IPV6_V6ONLY` setsockopt/getsockopt。

### C. 测试

新增 C 测试：
- `test_ipv6_socket.c`：`socket(AF_INET6, SOCK_STREAM, 0)` 必须 ≥0；`bind` 到 `::1:0` 后 `getsockname` 返回的 family 必须是 `AF_INET6`。
- `test_ipv6_v4mapped.c`：v6 socket connect 到 `::ffff:127.0.0.1:N`（先开个 v4 server）必须能通。

### D. 构建与回归

- `make ARCH=riscv64 build && make ARCH=x86_64 build` 通过。
- 现有 v4 网络测试不能 regression（CI workflow 通过）。

## 提交策略

1. `feat(starry/net): add AF_INET6 socket with v4-mapped fallback`
2. `test(starry/net): add IPv6 socket test cases`

PR 标题：`feat(starry/net): basic AF_INET6 socket support (v4-mapped fallback)`，目标 `yks23/Auto-OS` 的 `main` 分支。

## 备注

如果你判断方案 B 更合适且时间允许，请在 PR 描述里说明并开第二个 PR 单独追踪。

---

## 🧪 测试填充责任（强制）

**重要更新（Director, 2026-04-18）**：本任务 PR #2 已经把测试**骨架**写好了
（ 全部 main 默认 `pass()`，含 TODO Plan）。
你必须在你的 PR 里**填满**与 T3 相关的所有骨架文件，让 main 真正
验证对应 syscall 的行为。

### 你必须填充的骨架文件

见 `selfhost-orchestrator/DETAILED-TEST-MATRIX.md` 的 §T3：AF_INET6 socket（v4-mapped fallback 模式） 章节。

**对每个测试**：
1. 打开 `tests/selfhost/test_xxx.c`（或 .sh）
2. 把 main 里 `/* TODO(T3): ... */` 注释保留作为 plan 文档
3. **删掉** `pass(); return 0;` 占位
4. 按 DETAILED-TEST-MATRIX 的 Action / Expected return / Expected errno / Side effect 四列实现真正的验证逻辑
5. 用 `fail("...")` 在任意 assert 失败时立即 exit 1
6. 全部 assert 通过才 `pass();`

### 质量硬指标

- 每个 syscall 调用都必须**检查返回值**，失败时 `fail("syscall_name failed: %s", strerror(errno))`
- **errno 必须精确匹配**（不能用 `errno != 0` 这种宽松检查）
- **所有创建的临时文件、子进程、fd 在 fail/pass 前必须清理**（不要污染下一个测试的环境）
- 测试**幂等**：连续跑两次结果一致
- 不要依赖测试间顺序，每个测试自己 setup 自己 teardown

### Spec 引用

骨架文件顶部已经从 TEST-MATRIX.md 复制了 Spec 注释。如果你的实现细节
与 DETAILED-TEST-MATRIX 不一致（例如 errno 选择不同），**优先服从
DETAILED-TEST-MATRIX**，并在 PR 描述里说明理由。

### 测试与实现同 PR 提交

测试代码与 patches/T3-*/ 内的实现代码必须在**同一个 PR** 内提交。
review 时会要求测试 PASS 才合并。本机 `make ARCH=...` 编测试可能
因 musl-gcc 缺失 SKIP，那就在 PR 里说明，CI 上验证。

### Commit 拆分建议

1. `feat(patches/T3): <实现>`
2. `test(selfhost/T3): fill in skeleton test_<xxx>.c`（每填一组测试可以一个 commit）
3. （可选）`docs(T3): note any deviation from DETAILED-TEST-MATRIX`

