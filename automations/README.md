# Auto-OS Harnesses

This directory keeps the local automation harnesses used during the StarryOS
BigLab-B workflow. They are intentionally small wrappers around git, gh, and
focused validation commands; large logs, rootfs images, kernels, and QEMU output
should stay outside commits.

## Harnesses

- `dev-sync/`: daily dev-baseline sync. It fetches TGOSKit dev, refreshes a
  dedicated sync worktree/branch, and can optionally merge that sync branch into
  the local development branch.
- `pr-healer/`: PR status watcher. It checks open TGOSKit PRs by the current
  GitHub user, records non-green checks, archives merged PRs, and can run a
  configured auto-fix command in a dedicated TGOSKit worktree.

## Rules

- TGOSKit PR branches are based on dev.
- OS fixes must include a focused test-suite or reproduction note.
- CI failures are investigated from GitHub Actions logs before changing code.
- Confirmed OS bugs become TGOSKit PR candidates, not only showtime notes.
