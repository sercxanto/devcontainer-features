#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "~/.claude is a symlink"      bash -c 'test -L "$HOME/.claude"'
check "it points at the volume"     bash -c '[ "$(readlink "$HOME/.claude")" = "/opt/shared-agent-config/claude" ]'
check "~/.claude.json still not linked" bash -c '! test -L "$HOME/.claude.json"'

reportResults
