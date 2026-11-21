#!/usr/bin/env sh
#
# Generates .devcontainer/opencode-local: a copy of src/opencode, because VS Code
# only accepts local features inside .devcontainer/. This feature has no mounts,
# so there is no production volume to protect; only the published feature is a
# concern (see README).
#
# Re-run after every change to src/opencode, then rebuild the container.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../src/opencode"
DEST="$HERE/.devcontainer/opencode-local"

mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"
echo "prepared $DEST"
