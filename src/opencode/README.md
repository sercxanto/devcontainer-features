# opencode (Dev Container Feature)

Installs the **opencode 2.x** CLI system-wide, and registers the opencode VS Code
extension (`sst-dev.opencode`). Only 2.x is supported — the `opencode-ai` 1.x
line is not.

```jsonc
"features": {
    "ghcr.io/sercxanto/devcontainer-features/opencode:0": {}
}
```

| Option | Default | |
|---|---|---|
| `version` | `latest` | Version to install, e.g. `2.3.2`. `latest` is the newest 2.x release. |

## Requirements

The base image needs **`curl`, `tar` and `bash`**. The feature runs the official
installer (`https://opencode.ai/v2/install`) and does not install packages
itself; if one is missing, the build fails and says which. On Debian/Ubuntu
images the `common-utils` feature provides all three (this feature is ordered
after it).

On **Alpine** also install `libstdc++` and `libgcc` (`apk add bash curl tar
libstdc++ libgcc`): the musl binary links against them (measured). Without
them the build fails with that hint instead of leaving a binary that cannot
start.

## What it does

- Runs the official installer with a throwaway `$HOME` and `--no-modify-path`,
  so nothing lands in root's home or in a shell rc file, then copies the one
  self-contained binary (~250 MB) to `/usr/local/bin/opencode`. Measured: it
  runs from there without anything else from the installer.
- Verifies that the result reports a 2.x version.
- Is idempotent: a second run replaces the binary.
- Adds `sst-dev.opencode` to the VS Code extensions. That extension only opens
  a terminal and runs `opencode` in it (plus `@file` references), so it needs
  nothing but the binary on `PATH`. Its published version is not confirmed to be
  tested against 2.x; it works through the CLI either way.

`VERSION` is deliberately not passed through to the installer, which reads that
variable itself and does not know the value `latest`.

## Together with `shared-agent-config`

This feature only installs. Login and config shared across containers, and
sessions kept per project through a rebuild, come from
[`shared-agent-config`](../shared-agent-config/). The two are independent; use
either alone or both, e.g. as default features:

```jsonc
"dev.containers.defaultFeatures": {
    "ghcr.io/sercxanto/devcontainer-features/opencode:0": {},
    "ghcr.io/sercxanto/devcontainer-features/shared-agent-config:0": {}
}
```

## Upgrading

The version is fixed when the image is built. `latest` is resolved at that
moment and then cached by Docker like any layer: use *Rebuild Container Without
Cache* to pick up a new release, or pin `version`.
