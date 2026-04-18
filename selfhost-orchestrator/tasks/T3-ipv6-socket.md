# T3：AF_INET6 socket 支持

## 目标仓库
- **上游**：`https://github.com/rcore-os/tgoskits`
- **基线分支**：`dev`
- **PR 目标分支**：`dev`
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

PR 标题：`feat(starry/net): basic AF_INET6 socket support (v4-mapped fallback)`，目标 `rcore-os/tgoskits` 的 `dev` 分支。

## 备注

如果你判断方案 B 更合适且时间允许，请在 PR 描述里说明并开第二个 PR 单独追踪。
