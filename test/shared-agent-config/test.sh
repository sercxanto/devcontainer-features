#!/usr/bin/env bash
# Standard `devcontainer features test` entrypoint. This only covers what a
# single container can see; the cross-container guarantee -- the whole point of
# the feature -- needs two containers on one volume and lives in run-local.sh.
set -e
source dev-container-features-test-lib

check "CLAUDE_CONFIG_DIR is set"          bash -c '[ "$CLAUDE_CONFIG_DIR" = "/opt/shared-agent-config/claude" ]'
check "shared dir exists"                 bash -c 'test -d /opt/shared-agent-config/claude'
check "shared dir is writable by me"      bash -c 'touch "$CLAUDE_CONFIG_DIR/.probe" && rm "$CLAUDE_CONFIG_DIR/.probe"'
check "shared dir is owned by me"         bash -c '[ "$(stat -c %u /opt/shared-agent-config/claude)" = "$(id -u)" ]'
check "credentials dir is not world-readable" bash -c '[ "$(stat -c %a /opt/shared-agent-config/claude)" = "700" ]'
check "hook is installed"                 bash -c 'test -x /usr/local/share/shared-agent-config/setup.sh'
check "hook is idempotent"                bash -c '/usr/local/share/shared-agent-config/setup.sh create && /usr/local/share/shared-agent-config/setup.sh create'
check "home is untouched by default"      bash -c '! test -L "$HOME/.claude"'
check "~/.claude.json is never linked"    bash -c '! test -L "$HOME/.claude.json"'

reportResults
