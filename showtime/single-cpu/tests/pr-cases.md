# PR Test Cases

## robust futex cleanup

- related PR: #692
- source path:
  - `test-suit/starryos/normal/qemu-smp1/syscall/test-futex-robust-list/c/src/main.c`
- expected coverage:
  - `set_robust_list`/`get_robust_list` ABI
  - owner death wake
  - invalid user pointer returns/records fault without kernel fatal
- PR evidence to collect:
  - case output
  - QEMU log tail
  - kernel log around robust list cleanup

## vfork child-stack clone

- related PR: #693
- source path:
  - `test-suit/starryos/normal/qemu-smp1/syscall/test-vfork/c/src/main.c`
- expected coverage:
  - normal vfork wait behavior remains usable
  - child-stack clone does not force parent into vfork wait path
  - `posix_spawn` style behavior is not blocked

## IPv4-mapped IPv6 sockets

- related PR: #694
- source path:
  - `test-suit/starryos/normal/qemu-smp1/bugfix/bug-af-inet6-v4mapped/c/src/main.c`
- expected coverage:
  - bind/connect using IPv4-mapped IPv6 address
  - accept peer address conversion
  - `getsockname`/`getpeername` style address reporting where applicable

## rsext4 inode bitmap reuse

- related PR: #695
- source path:
  - TODO
- expected coverage:
  - allocate inode from group with uninit inode bitmap
  - verify bitmap initialization/reuse does not corrupt allocation state
  - create/unlink/recreate loop if a higher-level FS test is easier

