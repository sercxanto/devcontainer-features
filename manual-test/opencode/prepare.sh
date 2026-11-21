#!/usr/bin/env sh
#
# Generates .devcontainer/sac: a copy of src/shared-agent-config whose volume
# names are the TEST names below, so the production volume `shared-agent-config`
# and its per-devcontainer siblings are never mounted by this project.
#
# Also chooses what the container installs:
#
#   ./prepare.sh          @opencode/cli (opencode 2.x, the only supported line)
#   ./prepare.sh <spec>   any npm spec, e.g. @opencode/cli@2.3.1
#
# Re-run after every change to src/shared-agent-config, then rebuild the
# container.
set -eu

PACKAGE="${1:-@opencode/cli}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../src/shared-agent-config"
DEST="$HERE/.devcontainer/sac"

SHARED="sac-manual-test"                 # the shared volume (login, config)
STATE_PREFIX="sac-manual-test-opencode"  # per-devcontainer volumes: <prefix>-<id>

mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"

manifest="$DEST/devcontainer-feature.json"
sed -e "s|\"source\": \"shared-agent-config\"|\"source\": \"$SHARED\"|" \
    -e "s|\"source\": \"shared-agent-config-opencode-|\"source\": \"$STATE_PREFIX-|" \
    "$manifest" > "$manifest.new"
mv "$manifest.new" "$manifest"

grep -q "\"source\": \"$SHARED\"" "$manifest" \
  && grep -q "\"source\": \"$STATE_PREFIX-\${devcontainerId}\"" "$manifest" \
  || { echo "prepare.sh: volume rewrite failed; refusing" >&2; exit 1; }
if grep -q '"source": "shared-agent-config' "$manifest"; then
    echo "prepare.sh: production volume name still present; refusing" >&2; exit 1
fi

printf '%s\n' "$PACKAGE" > "$HERE/.devcontainer/opencode-package"

echo "prepared $DEST; the container will install: $PACKAGE"
grep '"source"' "$manifest"
