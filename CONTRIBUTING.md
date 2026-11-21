# Contributing

For humans and agents alike. Kept short because agents load it every session.

## What this repo is

A collection of Dev Container Features (`src/<id>/`), published to
`ghcr.io/sercxanto/devcontainer-features/<id>`. The layout `src/<id>` +
`test/<id>` is dictated by the devcontainer tooling; do not restructure it.

Each feature's `README.md` is its user documentation and is what ghcr.io
renders. The root `README.md` is only the map. Design rationale lives in the
feature README, next to the behaviour it explains.

## Invariants

These hold for every feature here. Breaking one is a bug, not a style choice.

- **`install.sh` and hooks are POSIX `sh`.** No bashisms, no `apt`, no `curl`,
  no Node. They must run on Alpine/BusyBox without `sudo`. The Alpine case is
  in `run-local.sh`; keep it green.
- **Hooks never fail the container.** A broken share is reported with a
  `WARNING:`, then the hook exits 0. Blocking someone's dev environment is
  worse than a missing feature.
- **Everything is idempotent.** Double installation is a real case (a repo
  pins the feature *and* it is a default feature). `mkdir -p`, `ln -sfn`,
  `cp -Rn`; never assume a clean slate.
- **No recursive walks on the hot path.** `postStartCommand` is O(1). A
  recursive `chown` may run once per (volume, uid), gated — never per start.
- **`mounts` and `containerEnv` in a manifest are static.** There is no option
  interpolation. Do not add an option that pretends to switch one of them off.
  The one variable a mount may use is the spec's `${devcontainerId}` — it is
  how per-project state (opencode's sessions) gets a volume of its own that
  survives a rebuild without being shared. It is not an option and does not
  contradict this rule.
- **Shared state wins over local state** during migration. `cp -n`, never
  `cp -f`; the volume is the source of truth.
- **Nothing per-image goes into the shared volume.** Before sharing a path,
  check what actually lives there (Claude's `~/.claude.json` carries
  `installMethod`; that is why it is never linked). Per-container secrets and
  process state go to the per-devcontainer volume instead (opencode's
  `service.json`, its state directory).
- **Measure, then link.** Which paths an agent writes, and *how* it writes them,
  decides the mechanism. opencode's `model.json` is saved by rename, which
  replaces a file symlink; that is why its state directory is linked as a
  whole. Do not guess from another version: only opencode 2.x is supported.

## Testing

```bash
./test/shared-agent-config/run-local.sh      # plain Docker; cross-container, migration, Alpine
./test/shared-agent-config/run-harness.sh    # standard harness on an isolated copy
./test/shared-agent-config/verify-claude-json.sh
```

Never run `devcontainer features test` on `src/` directly: the manifest names
the production volume and the tests would write into it. `run-harness.sh`
exists to prevent exactly that. On Colima/Lima the harness needs `TMPDIR`
under `$HOME`; the wrapper sets it.

Both suites must be green before a change is considered done. A change in
behaviour without a test that would have caught the old behaviour is
incomplete.

For what a script cannot show — a real login, a real TUI session, a rebuild in
VS Code — there is a manual test project: `manual-test/opencode/`. Its README
lists the steps. One trap: if the published feature is in your
`dev.containers.defaultFeatures`, VS Code injects it next to the local copy and
it wins, including your production volume. Comment it out for the test.

## Changing a feature

- Keep the feature README in step with the code. If a paragraph explains
  *why* something is the way it is and you change the *what*, rewrite the
  paragraph — do not leave it describing the old design.
- Adding an agent: follow *Adding an agent* in the feature README, and measure
  what the agent's config-dir variable actually relocates before trusting it.
- Adding a feature: `src/<id>/` and `test/<id>/` with `run-local.sh` and
  `run-harness.sh`; CI picks both up by glob.

## Versions and publishing

The `version` field in `devcontainer-feature.json` (semver) is the release
trigger — there are no git tags. A merge to `main` runs the publish workflow,
and the CLI publishes exactly the features whose version does not exist in
`ghcr.io/sercxanto/devcontainer-features` yet; everything else is skipped.

So:

- A change without a bump merges fine and publishes nothing. That is a valid
  way to batch several PRs into one release. The PR check reports it as a
  notice so it is a choice, not an oversight.
- A bump publishes on merge. Bump in the same PR as the change, or in a PR of
  its own — both are fine.
- A bumped version that is not greater than `main`'s, or that already exists
  in the registry, fails the PR check: publishing would silently skip it.

Published versions are immutable. Users pin by major (`:0`), so a breaking
change means a new major.
