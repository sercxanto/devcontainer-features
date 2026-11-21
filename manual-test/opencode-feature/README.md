# Manual test: the `opencode` feature

Checks in a real VS Code Dev Containers setup what the scripts only simulate:
that the **local copy of the feature** installs opencode 2.x, offers the VS Code
extension, and that a rebuild picks up changes.

## Before you start: disable the published feature

If `dev.containers.defaultFeatures` in your VS Code user settings contains
`ghcr.io/sercxanto/devcontainer-features/opencode:0`, VS Code injects the
**published** feature next to the local copy; the two install the same binary and
you would test the wrong one. Comment that entry out for the test, rebuild, and
put it back afterwards. (A `shared-agent-config` default feature does no harm
here: this project does not use it.)

## Steps

1. Generate the feature copy (re-run after any change in `src/opencode`):

   ```bash
   ./manual-test/opencode-feature/prepare.sh
   ```

2. In VS Code: *Dev Containers: Open Folder in Container…* → this directory
   (`manual-test/opencode-feature`). The first build downloads ~250 MB.

3. In the container terminal:

   ```bash
   opencode --version                 # opencode v2.x
   command -v opencode                # /usr/local/bin/opencode
   ls -A ~ | grep -i opencode         # nothing: the installer left no files in home
   ```

4. Extensions view: **opencode** (`sst-dev.opencode`) is installed in the
   container. Start it from the Command Palette (search "opencode") or the
   editor toolbar button (not verified which of the two your version offers): a
   terminal named `opencode` starts the TUI.

5. Pin a version: set `"version": "2.3.1"` in `.devcontainer/devcontainer.json`,
   *Dev Containers: Rebuild Container*, and check `opencode --version`.

6. Pick up a new release with `"latest"`: *Rebuild Container Without Cache*
   (a plain rebuild may reuse the cached layer and keep the old version).

7. Optional: free models work without login. In the TUI, pick an `opencode/…`
   free model and send a message.

## What to look for

- The version matches what you asked for; `latest` is a 2.x, never 1.x.
- The extension shows up without you installing it by hand.
- A failed build says what is missing (`curl`/`tar`/`bash`) rather than failing
  somewhere inside the installer. To see it, switch the image to `debian:12-slim`.

## Cleanup

Stop and remove the container in VS Code. The project has no volumes.
