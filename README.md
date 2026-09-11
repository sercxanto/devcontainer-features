# devcontainer-features

Dev Container Features for running agentic coding tools inside **arbitrary,
pre-existing dev containers** — without touching their `devcontainer.json` —
with config, login and skills shared across every container on the machine.

Currently one feature:

| Feature | What it does |
|---|---|
| [`shared-agent-config`](src/shared-agent-config/) | Shares the config directories of agentic coding tools (settings, credentials, skills, memory) across all dev containers via one named Docker volume. Claude Code today; one subdirectory per agent. **Start with its README.** |

## Repository layout

```
src/<feature-id>/     the feature: manifest, install script, hook, README
test/<feature-id>/    its tests
```

This layout is dictated by the devcontainer tooling, not by taste:
`devcontainer features publish` and `devcontainer features test` both expect
`src/<id>` and `test/<id>`. Each feature carries its own README because that
file is what ghcr.io and the VS Code feature picker display — this root README
is only the map.

## Testing

Everything is safe to run next to a production setup; each script uses a
throwaway volume and removes it afterwards.

```bash
# cross-container behaviour, plain Docker, no devcontainer CLI required
./test/shared-agent-config/run-local.sh

# the standard `devcontainer features test` harness, on an isolated copy
./test/shared-agent-config/run-harness.sh
./test/shared-agent-config/run-harness.sh --filter with_home_link

# re-measure where Claude Code puts .claude.json when CLAUDE_CONFIG_DIR is set
./test/shared-agent-config/verify-claude-json.sh
```

Do **not** call `devcontainer features test` on `src/` directly. Feature mounts
are static, so the manifest names the real `shared-agent-config` volume and
every test container would write into it. `run-harness.sh` stages a copy with
the volume renamed and runs the harness on that.

On VM-based Docker setups (Colima, Lima) the CLI's workspace bind-mount needs
`TMPDIR` under `$HOME`; `run-harness.sh` sets that for you.

## Publishing

```bash
devcontainer features publish -r ghcr.io -n sercxanto/devcontainer-features ./src
```

Requires `docker login ghcr.io` with a token that has `write:packages`. The
package may stay private; Docker only needs to be logged in on the machines
that use it.

Referencing the published feature is described in the
[feature README](src/shared-agent-config/README.md#usage).

## License

[MIT](LICENSE)
