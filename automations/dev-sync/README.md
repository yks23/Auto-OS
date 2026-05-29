# Daily TGOSKit Dev Sync Harness

This harness keeps a local sync branch close to TGOSKit `dev` so experiments and
PR branches do not drift away from the collaboration baseline.

Default behavior:

1. Fetch `upstream/dev` and `origin/dev` in the `tgoskits` submodule.
2. Refresh a dedicated worktree under `.harness-worktrees/tgoskits-dev-sync`.
3. Reset `sync/dev-live` to the configured dev baseline.
4. Push `sync/dev-live` to the fork remote.

The default canonical baseline is `upstream/dev` because this repository names
`rcore-os/tgoskits` as `upstream` and the personal fork as `origin`. If a local
clone uses different remote names, override `CANONICAL_REMOTE` or `BASE_REF`.

Example:

```bash
automations/dev-sync/run.sh
```

Launchd/cron schedule used by the project:

```text
0 9 * * *
```

To also merge the sync branch into a local development branch, opt in:

```bash
MERGE_INTO_DEV=1 DEV_BRANCH=dev automations/dev-sync/run.sh
```

The merge step is disabled by default to avoid mutating an active dirty worktree.
