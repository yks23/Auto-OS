# Self-host User-space Tests

每个 PR 必须附带至少 1 个 C/Sh 测试用例，放在这里。

## 命名

- C：`test_<feature>_<aspect>.c`
- Shell：`test_<feature>_<aspect>.sh`

## 输出格式（必须）

每个测试在最后必须 printf 一行：

```
[TEST] <name> PASS
```

或

```
[TEST] <name> FAIL: <reason>
```

并 `exit(0)` / `exit(1)` 跟随结果。

## 编译

C 测试用 musl-gcc 静态编译：

```sh
ARCH=riscv64 ${ARCH}-linux-musl-gcc -static -O0 test_x.c -o test_x
ARCH=x86_64  ${ARCH}-linux-musl-gcc -static -O0 test_x.c -o test_x
```

## 运行

由 `scripts/run-selfhost-tests.sh ARCH` 统一调度（D4 负责实现）。
