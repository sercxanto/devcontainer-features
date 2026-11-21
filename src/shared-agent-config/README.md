# Shared agent config (`shared-agent-config`)

Shares the config directories of agentic coding tools — settings, credentials,
skills, memory — across **all** dev containers on a machine, via one named Docker
volume. Log in once, and every container is logged in. Drop a skill in once, and
every container has it, without a rebuild.

Supported today: **Claude Code** and **opencode**. The layout is one
subdirectory per agent, so adding another is a small, local change (see
*Adding an agent*).

## Usage

This feature does **not** install any agent. Pair it with the agent's own
feature, which does that job well and handles version pinning:

```jsonc
// VS Code settings.json — applies to every dev container you open
"dev.containers.defaultFeatures": {
    "ghcr.io/devcontainers/features/node:1": {},
    "ghcr.io/anthropics/devcontainer-features/claude-code:1.0": {},
    // opencode: install it with whichever feature or image you prefer
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
| `/opt/shared-agent-config/opencode/{config,auth.json,mcp-auth.json}` | opencode has no such variable, so these are symlinked from its XDG paths (see *opencode*) |
| volume `shared-agent-config-opencode-${devcontainerId}` → `/opt/agent-state/opencode`, `OPENCODE_DB` | opencode's sessions: one volume per devcontainer, survives a rebuild, not shared (see *opencode*) |
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
pointing at an empty directory costs nothing, and neither does a symlink to an
empty one.

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

## opencode

**Only opencode 2.x is supported** — npm package `@opencode/cli`, not the
older `opencode-ai` (1.x). Measured against 2.3.2 with `opencode debug paths`
and real sessions. Nothing in it lives under a single directory you can point
a variable at:

| Path (XDG default) | Holds | Verdict |
|---|---|---|
| `~/.config/opencode/` | `opencode.json(c)`, agents, commands, plugins | **shared** — the whole directory is linked |
| `~/.local/share/opencode/auth.json` | provider credentials | **shared** — **log in once, logged in everywhere** |
| `~/.local/share/opencode/mcp-auth.json` | MCP OAuth tokens | **shared** |
| `~/.local/share/opencode/opencode.db` | sessions (SQLite) | **per devcontainer** — moved by `OPENCODE_DB` into its own volume, survives a rebuild, never shared with other containers |
| `~/.local/share/opencode/{snapshot,shell}/` | undo snapshots and the full output of commands, which sessions refer to | **per devcontainer** — symlinked into the same state volume as the database |
| `~/.local/state/opencode/` | TUI state: `model.json` (recent models), `prompt-history.jsonl`, `latest/tui/` (tabs, seen hints) — plus process state: `locks/`, `pty/`, `service.json` | **per devcontainer** — the whole directory is linked, process state is cleared when a container is created |
| `~/.config/opencode/service.json` | password of the local background service | **per devcontainer** — see below |
| `~/.local/share/opencode/{log,repos}`, `~/.local/state/`, `~/.cache/opencode/` | logs, clones, lock files, downloaded binaries | container-local, lost on rebuild |

Why it is done this way, and not the Claude way:

- **`OPENCODE_CONFIG_DIR` does not help.** It is *additive* — an extra directory
  searched for agents, commands and plugins. Credentials and the main config
  stay where they were, so it cannot give you "log in once".
- **`XDG_*_HOME` would work but is the wrong tool.** Pointing `XDG_DATA_HOME` at
  the volume relocates every other XDG-aware tool in the container as well,
  and moves `opencode.db` and the caches along with it.
- So the config directory and the two credential files are **symlinked**. These
  links are created regardless of `linkHome`: that option exists for tooling
  that hardcodes home paths, whereas here the link *is* the mechanism. The data
  directory itself is deliberately not linked — see the table.
- If `XDG_CONFIG_HOME` / `XDG_DATA_HOME` are set in the container, the links are
  made under those instead of `~/.config` and `~/.local/share`.

### Sessions: per devcontainer, surviving a rebuild

Sessions live in `opencode.db`, a SQLite database that opencode opens
read-write. Two containers writing one database file is a risk this feature does
not take on opencode's behalf, so — unlike Claude's `projects/` — sessions are
**not** shared across containers. They must, however, outlive a rebuild of the
same container, and a container-local path does not.

The answer is a second, separate volume whose name contains `${devcontainerId}`
(a variable of the devcontainer spec that the manifest is allowed to use in
`mounts`; it is not an option, so the "mounts are static" rule above stands).
The id is derived from the workspace folder and the config file, so:

- the same project gets the **same volume after every rebuild** — also when
  the feature is injected through `dev.containers.defaultFeatures` and the
  repo's `devcontainer.json` knows nothing about it;
- **another project gets another volume** and does not see these sessions.

A static `containerEnv` entry, `OPENCODE_DB=/opt/agent-state/opencode/opencode.db`,
points opencode at it — no symlink for the database, which would leave SQLite's
`-wal`/`-shm` files to chance. It is the same ownership trick as the shared
volume: `install.sh` creates and chowns the mount point at build time.

Limits of this:

- Moving or renaming the project folder changes the id; the sessions stay in
  the old volume and the new location starts empty.
- Volumes are never garbage-collected. List them with
  `docker volume ls --filter name=shared-agent-config-opencode-` and remove the
  ones of projects you no longer use.
- Carried: `opencode.db`, `snapshot/`, `shell/` and the whole state directory
  — the database, what its sessions point at, and the TUI's model, prompt and
  tab memory. Logs, clones and caches are rebuilt. If a later opencode renames those two directories, the links are harmless
  but the data is no longer kept.
- A database that already sits in the container's data directory when the
  state volume is first created is copied over once (`cp -n`).

### The state directory

Linking single files does not work here: opencode writes `model.json` through a
temp file and a rename (measured), which replaces a file symlink — the newest
model choice would then live only in the container and be lost on rebuild. So
the whole `~/.local/state/opencode` is linked, and the rename stays inside the
volume.

That directory also holds process state: `locks/` (and `<channel>/locks/`),
`pty/` and the background service's `service.json` with its pid and port. On
container creation nothing of an earlier container is running any more, so
`postCreateCommand` deletes exactly those names. Any new kind of process state
a later opencode adds there would survive a rebuild until it is added to
`clear_process_state` in `setup.sh`.

### `service.json` (password)

opencode starts a small background service on `127.0.0.1` and keeps its password in
`<config>/service.json`, next to the matching pid and port in
`<state>/service.json`. The config directory is shared, so a plain link would
give every container the same service password — a secret that belongs to one
container's process, in a pool meant for credentials. So the single file is
redirected: inside the shared config directory, `service.json` is a symlink to
`/opt/agent-state/opencode/config-service.json` in the per-devcontainer volume.
The link is identical for every container; each one resolves it to its own
volume, where opencode creates the file on first use. If you run 1.x anyway, the link simply dangles and does no harm — but 1.x
is not tested and its own paths (e.g. `tool-output/`) are not shared.

Because these are symlinks, a writer that saves by write-temp-then-rename
replaces the link with a real file. The `postStartCommand` hook notices and
restores it; the clobbered copy is merged with `cp -n`, so **what is already in
the volume wins** and a newer local token would be dropped. opencode is not
known to save `auth.json` that way (not measured), so this is a fallback.

## Options

| Option | Default | Description |
|---|---|---|
| `linkHome` | `false` | Also symlink each agent's conventional home path (`~/.claude`) into the volume, for tooling that hardcodes those paths. Off by default: the environment variables already cover the agents themselves, and `~/.claude` is also used by Claude's native installer for `downloads/` and `backups/` — per-image state that should not be shared. |

Turn `linkHome` on if you find a tool or extension that assumes `~/.claude`
literally. Anything already there is migrated into the volume with `cp -Rn`
before the path is replaced — existing shared state wins, the local copy only
fills gaps.

## Adding an agent

Always:

1. `install.sh` — the subdirectory name in `AGENT_DIRS`.
2. `setup.sh` — call the agent's setup from `main`.

Then, depending on what the agent offers:

- **A variable that relocates the whole config dir** (Claude): add it to
  `containerEnv` in `devcontainer-feature.json`, pointing at
  `/opt/shared-agent-config/<agent>`, and use `setup_agent "<agent>" "<home path>"`.
- **No such variable** (opencode): write a small `setup_<agent>` with
  `share_dir` / `share_file` for exactly the paths worth sharing. These links
  are unconditional, not behind `linkHome`.

Before adding one, measure what its config-dir variable actually relocates (the
`.claude.json` question above and opencode's additive `OPENCODE_CONFIG_DIR` are
exactly the kind of thing that only a measurement answers) and whether any
path you would share holds per-image state or a live database.

## Requirements and limits

- **Any base image with a POSIX shell.** No `apt`, no `curl`, no Node. Verified on
  `mcr.microsoft.com/devcontainers/base:ubuntu` and on `alpine:3.20` with BusyBox
  `sh` and no `sudo`.
- **One machine.** The volume is local to the Docker context. A second machine
  needs a different source of truth (a git repo of skills, for instance).
- **No locking.** Two containers writing the same settings file at once is
  last-write-wins. Rarely relevant, but this is shared state, not synchronised
  state.
- **Claude's session history is shared and grows monotonically.** Claude's `projects/`
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
