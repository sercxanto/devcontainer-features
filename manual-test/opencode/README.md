# Manual test: opencode in `shared-agent-config`

Checks by hand what the automated tests can only simulate: that **opencode's
login and sessions survive a container rebuild** in a real VS Code Dev
Containers setup, and that sessions stay **per project**.

The project uses a generated local copy of the feature with **test volume
names** (`sac-manual-test`, `sac-manual-test-opencode-<id>`). Your production
volume `shared-agent-config` is not mounted here.

## Before you start: disable the default feature

If `dev.containers.defaultFeatures` in your VS Code user settings contains
`ghcr.io/sercxanto/devcontainer-features/shared-agent-config:0`, VS Code injects
the **published** feature next to the local copy. Both install the same hook
path and mount the same target, and the published one wins: the container then
has the old `setup.sh` and mounts your **production** volume. Comment that one
entry out for the test, rebuild, and put it back afterwards. Check with:

```bash
grep -c setup_opencode /usr/local/share/shared-agent-config/setup.sh   # must be > 0
```

## Steps

1. Generate the feature copy (re-run after any change in `src/`):

   ```bash
   ./manual-test/opencode/prepare.sh                       # opencode 2.x (@opencode/cli)
   ./manual-test/opencode/prepare.sh @opencode/cli@2.3.1   # or any npm spec
   ```

   Only opencode 2.x is supported. If you tested with `opencode-ai` (1.x)
   before, remove the volumes first (see *Cleanup*): its database and state
   files are not what 2.x expects.

2. In VS Code: *Dev Containers: Open Folder in Container…* → this directory
   (`manual-test/opencode`). Wait for `postCreateCommand` (installs opencode).

3. In the container terminal:

   ```bash
   env | grep OPENCODE_DB                       # /opt/agent-state/opencode/opencode.db
   ls -l ~/.config/opencode ~/.local/share/opencode
   opencode auth login                          # or: use a free model, no login needed
   opencode                                     # TUI: pick a model, chat, ask for a long command output
   ```

   For `shell/`, ask for something with very long output, e.g.
   *"run `seq 1 20000` with the bash tool"*. Switch models and quit the TUI.

4. Note what exists before rebuilding:

   ```bash
   ls -l ~/.local/share/opencode ~/.local/state/opencode
   ls -A /opt/agent-state/opencode
   opencode session list
   ```

5. *Dev Containers: Rebuild Container* (not just reopen).

6. After the rebuild:

   ```bash
   opencode session list                        # your session is still there
   ls -l ~/.local/share/opencode                # snapshot, shell -> /opt/agent-state/opencode/...
   ls -l ~/.config/opencode                     # 2.x: service.json -> /opt/agent-state/opencode/config-service.json
   ls -A ~/.local/state/opencode                # what did the TUI leave here? is it gone now?
   opencode auth list                           # still logged in (shared volume)
   ```

   In the TUI, open the old session and try **undo/revert**.

7. Optional, "other project": open a second, different folder with the same
   feature copy. `opencode session list` must be empty there, while
   `opencode auth list` shows the same login.

## What to look for

- Sessions, revert and long tool outputs of the old session work after rebuild.
- `~/.local/state/opencode` after a TUI session: files like model favourites or
  prompt history that disappear on rebuild. If you miss them, that directory is
  the candidate for the next link.
- 2.x: `~/.config/opencode/service.json` is a link into the state volume, and
  a second project does **not** see the first one's service password.
- Anything unexpected in `/opt/agent-state/opencode`.

## Cleanup

```bash
# stop/remove the container in VS Code, then:
docker volume ls --filter name=sac-manual-test
docker volume ls -q --filter name=sac-manual-test | xargs docker volume rm
```
