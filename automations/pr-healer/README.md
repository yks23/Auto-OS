# PR Healer Harness

`run.sh` watches open TGOSKit PRs authored by the current GitHub user.

It records:

- open PR number, title, branch, and URL;
- non-green GitHub Actions checks;
- merged PRs under `success-pr/pr-<number>.txt`.

If `AUTO_FIX_CMD` is configured, the command runs in a dedicated TGOSKit PR
worktree under `.harness-worktrees/pr-healer/pr-<number>`. This keeps automated
CI fixes away from the dirty Auto-OS root and away from unrelated experiments.

Default mode is report-only:

```bash
automations/pr-healer/run.sh
```

To enable an explicit local fix command:

```bash
AUTO_FIX_CMD='cargo fmt && cargo xtask clippy --package starry-kernel' \
  automations/pr-healer/run.sh
```

The launchd environment on macOS often has a minimal `PATH`, so the script
prepends Homebrew and system paths before looking for `gh` and `jq`.
