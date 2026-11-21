#!/usr/bin/env bash
# Standard `devcontainer features test` entrypoint.
set -e
source dev-container-features-test-lib

check "opencode is on PATH"          bash -c 'command -v opencode'
check "it is a 2.x"                  bash -c 'opencode --version </dev/null | grep -Eq "(^| )v?2\."'
check "installed system-wide"        bash -c '[ "$(command -v opencode)" = /usr/local/bin/opencode ]'
check "no installer files in home"   bash -c '! test -e "$HOME/.opencode"'

reportResults
