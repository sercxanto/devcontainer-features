#!/usr/bin/env bash
#
# Answers section 6.4 of the briefing empirically: with CLAUDE_CONFIG_DIR set,
# where does Claude Code put .claude.json -- inside that directory, or next to
# the home directory as usual?
#
# No login happens here. The script only starts the CLI far enough to make it
# write its config, then looks at the filesystem.
#
set -euo pipefail
IMAGE="claude-json-probe:$$"
KEEP="${KEEP_IMAGE:-0}"
trap '[ "$KEEP" = "1" ] || docker rmi -f "$IMAGE" >/dev/null 2>&1 || true' EXIT

ctx="$(mktemp -d)"
cat > "$ctx/Dockerfile" <<'EOF'
FROM mcr.microsoft.com/devcontainers/base:ubuntu
RUN apt-get update -qq && apt-get install -y -qq nodejs npm >/dev/null 2>&1 || true
RUN su vscode -c "curl -fsSL https://claude.ai/install.sh | bash" 2>/dev/null || true
EOF
echo "==> building probe image (installing Claude Code CLI)"
docker build -q -t "$IMAGE" "$ctx" >/dev/null
rm -rf "$ctx"

echo
echo "==> probe A: CLAUDE_CONFIG_DIR set to a custom directory"
docker run --rm -u vscode -e CLAUDE_CONFIG_DIR=/home/vscode/custom-config "$IMAGE" bash -lc '
  export PATH="$HOME/.local/bin:$PATH"
  command -v claude >/dev/null || { echo "CLI_NOT_INSTALLED"; exit 0; }
  claude --version 2>&1 | head -1
  claude mcp list >/dev/null 2>&1 || true
  echo "--- files under CLAUDE_CONFIG_DIR ---"
  ls -la /home/vscode/custom-config 2>/dev/null || echo "(directory does not exist)"
  echo "--- .claude* directly in HOME ---"
  ls -lad /home/vscode/.claude /home/vscode/.claude.json 2>/dev/null || echo "(none)"
  echo "--- top-level keys, CLAUDE_CONFIG_DIR/.claude.json ---"
  node -e "console.log(Object.keys(require(\"/home/vscode/custom-config/.claude.json\")).sort().join(\"\\n\"))" 2>/dev/null || echo "(unreadable)"
  echo "--- top-level keys, HOME/.claude.json ---"
  node -e "console.log(Object.keys(require(\"/home/vscode/.claude.json\")).sort().join(\"\\n\"))" 2>/dev/null || echo "(unreadable)"
  echo "--- contents of HOME/.claude ---"
  find /home/vscode/.claude -maxdepth 2 | head -20
'
