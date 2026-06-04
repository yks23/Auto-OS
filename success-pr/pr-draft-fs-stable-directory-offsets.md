# PR Draft: fix(fs): use stable directory offsets for tmpfs and rsext4

## Summary

- tmpfs `read_dir` now returns stable per-entry cookies instead of HashMap enumeration indexes.
- tmpfs cross-directory `rename()` now allocates a destination-directory cookie instead of reusing the source entry cookie.
- rsext4 `read_dir` now returns raw ext4 directory byte offsets instead of live-entry counts.
- rsext4 offset calculation scans raw dirents directly so deleted/free entries still advance by their real `rec_len`.
- This fixes `rm -rf` leaving large directories non-empty when userland reads a directory in batches and unlinks entries between `getdents64` calls.

## Root Cause

Linux `getdents64` uses the returned directory offset as the next read position. Userland tools such as `rm -rf` commonly read a batch of names, unlink those names, and then continue reading from the saved offset.

The old tmpfs implementation used the current HashMap iteration index as the offset. The old rsext4 implementation used the current live-entry count, and its iterator skipped inode-zero free entries. Once entries were removed, those count-based offsets no longer pointed to the same logical position, so later names could be skipped and the final `rmdir` failed with `Directory not empty`.

After the first cookie fix, tmpfs still had one more unstable path: cross-directory `rename()` moved the source `InodeRef` directly into the destination directory. Because each directory owns its own cookie space, this could duplicate an existing destination cookie. Cargo uses temp-file rename patterns heavily, so duplicate `d_off` values in the destination directory can make later batched directory scans skip entries.

## Fix

tmpfs assigns a monotonically increasing cookie to each directory entry and returns `cookie + 1` as the next offset. The snapshot is sorted by cookie before being emitted. Create, hard-link, and rename all allocate the cookie from the directory that will contain the resulting entry.

rsext4 walks each directory block by raw dirent layout. It advances by `rec_len` for both live and deleted/free entries, filters using the raw byte cookie, and returns the next raw byte offset to userspace.

## Test Plan

- Added focused StarryOS regression:
  `/usr/bin/bug-dir-cookie-unlink-rmdir`.
  The test directly calls `getdents64` with a small buffer, unlinks every name
  from each returned batch, then asserts final `rmdir` succeeds. It covers both
  `/tmp` tmpfs and `/root` rootfs/ext4 paths.
  It also creates source/destination directories, renames many files into the
  destination directory, then repeats the batched `getdents64` + `unlinkat`
  cleanup to catch duplicate destination cookies.
- Before fix: SMP8 HVF probe with `FILE_COUNT=100` failed in tmpfs:
  `rm: can't remove '/tmp/hvf-probe-tmpfs': Directory not empty`.
- With tmpfs-only fix: tmpfs passed, but ext4 failed at `FILE_COUNT=1500`:
  `rm: can't remove '/root/hvf-probe-ext4': Directory not empty`.
- With tmpfs+rsext4 raw-offset fix:
  `CASE_NAME=smp8-dir-cookie-rawoffset-rm-1500 SMP=8 FILE_COUNT=1500 EXEC_COUNT=300`
  passed with `===HVF-PROBE-DONE case=smp8-dir-cookie-rawoffset-rm-1500 rc=0===`.
- With the tmpfs rename-cookie follow-up included, the new HVF SMP8 kernel
  `/Users/txc/code/Auto-OS/.guest-runs/aarch64-hvf/starryos-hvf-smp8-dir-cookie-rename-hvfopt-20260523.bin`
  passed:
  `CASE_NAME=smp8-dir-cookie-rename-rm-1500-ren512 SMP=8 FILE_COUNT=1500 RENAME_COUNT=512 EXEC_COUNT=300`,
  with `===HVF-PROBE-DONE case=smp8-dir-cookie-rename-rm-1500-ren512 rc=0===`.
  Log:
  `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-probe-smp8-dir-cookie-rename-rm-1500-ren512-20260523T202446.log`.
- Follow-up full-build A/B now gets past the earlier 164s `proc_macro2`
  rlib failure and reaches the late dependency tail. The remaining full-cargo
  issue is being tracked separately as a process wait/jobserver diagnostic, not
  as part of this filesystem PR.
- Build validation:
  `cargo xtask starry build --arch aarch64 -c /tmp/build-aarch64-hvf-smp8-mem4g.toml --smp 8`.
- Local test validation so far:
  `cc -fsyntax-only -Wall -Wextra -Werror -Wno-deprecated-declarations .../bug-dir-cookie-unlink-rmdir/c/src/main.c`;
  `cargo xtask starry test qemu --arch aarch64 -g normal -c bugfix --list`;
  `cargo xtask starry test qemu --arch riscv64 -g normal -c bugfix --list`;
  `git diff --check` on the new test and bugfix qemu configs.

## Remaining PR Work

- Rebase onto clean `origin/dev` / PR target `dev`.
- Replay the same fix onto a clean PR branch and rerun the short FS/rename probe there.
- Run the focused StarryOS bugfix case on Linux/CI after moving to a clean branch.
- Run `cargo fmt`, narrow clippy/build, and the focused test-suite case before push.
