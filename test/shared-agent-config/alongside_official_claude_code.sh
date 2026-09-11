#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "claude CLI is on PATH"    bash -c 'command -v claude'
check "CLAUDE_CONFIG_DIR is set" bash -c '[ -n "$CLAUDE_CONFIG_DIR" ]'
# Starting the CLI writes .claude.json; it must land in the volume, not in HOME.
check "claude writes its state into the volume" bash -c '
    claude --version >/dev/null 2>&1 || true
    claude mcp list >/dev/null 2>&1 || true
    test -f "$CLAUDE_CONFIG_DIR/.claude.json"'

reportResults
