# F-α 自检说明（Auto-OS 侧）

- 复现与根因分析全文位于 `patches/F-alpha/` 中 `docs` patch 所添加的 `tgoskits/os/StarryOS/starryos/docs/F-alpha-debug.md`（apply patch 后可在子模块内查看）。
- 本目录 `test_fork_exec_bisect.c` 生成 `test_bisect_{1,2,3}`，需拷入 guest `/opt/selfhost-tests/` 后启动内核（`init.sh` 会在 shebang 后 `exec` 链）。
