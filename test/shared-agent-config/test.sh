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
check "opencode config dir is linked into the volume" bash -c '[ "$(readlink "${XDG_CONFIG_HOME:-$HOME/.config}/opencode")" = "/opt/shared-agent-config/opencode/config" ]'
check "opencode auth.json is linked into the volume"  bash -c '[ "$(readlink "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json")" = "/opt/shared-agent-config/opencode/auth.json" ]'
check "opencode data dir itself is not linked"        bash -c '! test -L "${XDG_DATA_HOME:-$HOME/.local/share}/opencode"'
check "opencode volume dir is not world-readable"     bash -c '[ "$(stat -c %a /opt/shared-agent-config/opencode)" = "700" ]'
check "OPENCODE_DB points into the state volume"      bash -c '[ "$OPENCODE_DB" = "/opt/agent-state/opencode/opencode.db" ]'
check "state volume is writable and owned by me"      bash -c 'touch "$(dirname "$OPENCODE_DB")/.probe" && rm "$(dirname "$OPENCODE_DB")/.probe" && [ "$(stat -c %u "$(dirname "$OPENCODE_DB")")" = "$(id -u)" ]'
check "state volume is a mount of its own"            bash -c 'grep -q " /opt/agent-state/opencode " /proc/self/mountinfo && grep -q " /opt/shared-agent-config " /proc/self/mountinfo'
check "opencode snapshot/ goes to the state volume"   bash -c '[ "$(readlink "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/snapshot")" = /opt/agent-state/opencode/snapshot ]'
check "opencode shell/ goes to the state volume"      bash -c '[ "$(readlink "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/shell")" = /opt/agent-state/opencode/shell ]'
check "opencode service.json is per devcontainer"     bash -c '[ "$(readlink "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/service.json")" = /opt/agent-state/opencode/config-service.json ]'
check "opencode state directory goes to the state volume" bash -c '[ "$(readlink "${XDG_STATE_HOME:-$HOME/.local/state}/opencode")" = /opt/agent-state/opencode/state ]'

reportResults
