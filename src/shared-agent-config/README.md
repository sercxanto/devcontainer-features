# Shared agent config (`shared-agent-config`)

Shares the config directories of agentic coding tools — settings, credentials,
skills, memory — across **all** dev containers on a machine, via one named Docker
volume. Log in once, and every container is logged in. Drop a skill in once, and
every container has it, without a rebuild.

Supported today: **Claude Code**. The layout is one subdirectory per agent, so
adding another is a small, local change (see *Adding an agent*).

## Usage

This feature does **not** install any agent. Pair it with the agent's own
feature, which does that job well and handles version pinning:

```jsonc
// VS Code settings.json — applies to every dev container you open
"dev.containers.defaultFeatures": {
    "ghcr.io/devcontainers/features/node:1": {},
    "ghcr.io/anthropics/devcontainer-features/claude-code:1.0": {},
    "ghcr.io/sercxanto/devcontainer-features/shared-agent-config:0": {}
}
```

The `node` feature is not optional for Claude Code. The official feature only
*tries* to install Node via `apt` when it is missing, and that fallback breaks
on images whose distro ships `nodejs` without `npm` (Ubuntu 26.04 does); it then
aborts and tells you to add the `node` feature. Listing it up front avoids a
failed container build on exactly the "arbitrary repo" this setup is meant for.

`dev.containers.defaultFeatures` is what makes this work on repos you do not
control — no `devcontainer.json` is touched. It belongs to the VS Code Dev
Containers extension, though, and is **not** part of the devcontainer spec: with
the `devcontainer` CLI or in Codespaces the feature has to be listed explicitly.

## How it works

| Piece | Role |
|---|---|
| named volume `shared-agent-config` → `/opt/shared-agent-config` | the one storage location every container mounts |
| `/opt/shared-agent-config/<agent>/` | one subdirectory per agent |
| `CLAUDE_CONFIG_DIR=/opt/shared-agent-config/claude` | Claude writes its whole config tree there — no symlink needed |
| build-time `chown` in `install.sh` | makes the volume land owned by the remote user (see below) |
| `postCreateCommand` | migration + ownership repair, once per container |
| `postStartCommand` | one `readlink` per agent, repairs a clobbered symlink |

A feature is the only mechanism that can inject a `mounts` entry into a container
whose `devcontainer.json` you cannot edit. That is why this is a feature and not
an image or a template.

There are no per-agent on/off options, and that is deliberate: `mounts` and
`containerEnv` in a feature manifest are static, so an option `claude: false`
could not actually stop `CLAUDE_CONFIG_DIR` from being set — it would be a lie.
Instead the feature prepares the environment for every agent it knows, and
which of them is in use is decided by what is installed. An environment variable
pointing at an empty directory costs nothing.

### The ownership trick

A fresh named volume is root-owned, and a non-root `vscode`/`node` user cannot
write to it. Rather than `chmod -R 777` at every start, this feature leans on a
documented Docker behaviour: **mounting an empty named volume over a path that
already has content copies that content into the volume, owner and mode
included.** So `install.sh` creates and chowns `/opt/shared-agent-config` at
build time, while the volume is *not* mounted — and the first container that
ever populates the volume gets the right ownership for free.

The runtime hook still handles the case where a volume was populated by a
different image whose remote user has another UID. That recursive `chown` is
gated on a UID comparison of the volume root, so it runs at most once per
(volume, user) pair — this matters, because session-history directories grow
without bound and a per-start recursive walk over them gets slow.

## Claude Code

Shared, because it lives under `CLAUDE_CONFIG_DIR`:

- `settings.json` — model, permissions, statusline, hooks
- `.credentials.json` — **log in once, logged in everywhere**
- `skills/`, `agents/`, `commands/`, global `CLAUDE.md`, memory
- `.claude.json` — onboarding/trust state (see below)
- `projects/` — session history

Deliberately not shared:

- **`~/.claude.json`** — see below.
- **The Claude binary and its version** — frozen per image. Updating means
  bumping the CLI feature's version and rebuilding.
- **Project-scope config** (`.claude/` in the repo) — stays with the repo, which
  is correct.

### The `.claude.json` question

`.claude.json` holds the onboarding state. If it is missing, Claude behaves like
a fresh install even when the credentials are present — which is the failure mode
that makes symlink-only sharing (e.g. `agent-persistence`) frustrating.

Measured against Claude Code 2.1.267, with `CLAUDE_CONFIG_DIR` set, two files
exist and they are **not** the same thing:

| File | Keys | Verdict |
|---|---|---|
| `$CLAUDE_CONFIG_DIR/.claude.json` | `userID`, `machineID`, `firstStartTime`, `migrationVersion`, `seenNotifications` | shared — this is the state that matters |
| `~/.claude.json` | the above **plus** `installMethod`, `autoUpdates`, `autoUpdatesProtectedForNative` | container-local — describes the install in *this* image |

So `CLAUDE_CONFIG_DIR` does what we need, and this feature **never symlinks
`~/.claude.json`**. Doing so would funnel per-image installer metadata into the
same file that carries the shared state — two writers with different semantics
in one file, and a mess as soon as two containers install Claude differently.

Re-run the measurement yourself with
`test/shared-agent-config/verify-claude-json.sh`.

## Options

| Option | Default | Description |
|---|---|---|
| `linkHome` | `false` | Also symlink each agent's conventional home path (`~/.claude`) into the volume, for tooling that hardcodes those paths. Off by default: the environment variables already cover the agents themselves, and `~/.claude` is also used by Claude's native installer for `downloads/` and `backups/` — per-image state that should not be shared. |

Turn `linkHome` on if you find a tool or extension that assumes `~/.claude`
literally. Anything already there is migrated into the volume with `cp -Rn`
before the path is replaced — existing shared state wins, the local copy only
fills gaps.

## Adding an agent

Three edits, all local to this feature:

1. `devcontainer-feature.json` — the agent's config-dir environment variable in
   `containerEnv`, pointing at `/opt/shared-agent-config/<agent>`.
2. `install.sh` — the subdirectory name in `AGENT_DIRS`.
3. `setup.sh` — one `setup_agent "<agent>" "<home path>"` line in `main`.

Before adding one, check what its config-dir variable actually relocates (the
`.claude.json` question above is exactly the kind of thing that only a
measurement answers) and whether its home path holds per-image state that must
not be shared.

## Requirements and limits

- **Any base image with a POSIX shell.** No `apt`, no `curl`, no Node. Verified on
  `mcr.microsoft.com/devcontainers/base:ubuntu` and on `alpine:3.20` with BusyBox
  `sh` and no `sudo`.
- **One machine.** The volume is local to the Docker context. A second machine
  needs a different source of truth (a git repo of skills, for instance).
- **No locking.** Two containers writing the same settings file at once is
  last-write-wins. Rarely relevant, but this is shared state, not synchronised
  state.
- **Session history is shared and grows monotonically.** Claude's `projects/`
  accumulates history from every project in one directory. Harmless
  functionally, and the reason the ownership walk is gated rather than
  unconditional. Making it per-container is not offered as an option, because
  the switch would have to live in the shared volume itself and would therefore
  apply to every container — last one to start wins, which is worse than not
  offering it.

## Security

**The volume is a machine-wide credential pool.** Every container that mounts it
— including one from a repo you have not read, which is exactly what happens when
this runs as a default feature — inherits authenticated sessions and permission
allowlists. That is the deliberate trade of this design. If you want an escape
hatch for a specific repo, override the feature in that repo's
`devcontainer.json`, or point the agent's config-dir variable elsewhere there.

Each agent's directory is `chmod 700`, so it is at least not readable by other
users inside the container.
