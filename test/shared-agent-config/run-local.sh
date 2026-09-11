#!/usr/bin/env bash
#
# Exercises the feature against plain Docker -- no devcontainer CLI needed.
# It reproduces what the devcontainer runtime does: run install.sh as root at
# build time, then run the hooks as the remote user with the volume mounted.
#
# What it proves:
#   1. the build-time ownership trick works (no chown at first runtime start)
#   2. a second, independent container sees state written by the first
#   3. re-running the hooks is idempotent
#   4. an existing ~/.claude is migrated instead of deleted
#   5. the start hook repairs a symlink clobbered by an atomic write
#
set -euo pipefail

FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src/shared-agent-config" && pwd)"
VOLUME="shared-agent-config-test-$$"
IMAGE="shared-agent-config-test:$$"
BASE_IMAGE="${BASE_IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
REMOTE_USER="${REMOTE_USER:-vscode}"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1))
    else
        printf '  \033[31mFAIL\033[0m %s\n        expected: %s\n        actual:   %s\n' "$1" "$3" "$2"
        fail=$((fail+1))
    fi
}

cleanup() {
    docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> building test image from $BASE_IMAGE"
build_ctx="$(mktemp -d)"
cp "$FEATURE_DIR/install.sh" "$FEATURE_DIR/setup.sh" "$build_ctx/"
cat > "$build_ctx/Dockerfile" <<EOF
FROM $BASE_IMAGE
COPY install.sh setup.sh /tmp/feature/
# Pre-create a real ~/.claude with content, to test the migration path.
RUN mkdir -p /home/$REMOTE_USER/.claude/skills/demo \\
 && echo "baked into the image" > /home/$REMOTE_USER/.claude/skills/demo/SKILL.md \\
 && chown -R $REMOTE_USER:$REMOTE_USER /home/$REMOTE_USER/.claude
RUN cd /tmp/feature \\
 && _REMOTE_USER=$REMOTE_USER _REMOTE_USER_HOME=/home/$REMOTE_USER LINKHOME=true \\
    sh ./install.sh
EOF
docker build -q -t "$IMAGE" "$build_ctx" >/dev/null
rm -rf "$build_ctx"

run_as_user() {   # run a command as the remote user in a fresh container
    docker run --rm -u "$REMOTE_USER" -v "$VOLUME:/opt/shared-agent-config" \
        -e CLAUDE_CONFIG_DIR=/opt/shared-agent-config/claude "$IMAGE" bash -lc "$1"
}

# The image is built with LINKHOME=true so the optional link path is covered;
# the feature ships with linkHome=false, which is exercised at the end.

echo
echo "==> container 1: first mount of an empty volume"
out1="$(run_as_user '
  /usr/local/share/shared-agent-config/setup.sh create >/tmp/log 2>&1
  grep -q "claiming" /tmp/log && echo "CHOWNED" || echo "NO_CHOWN"
  stat -c %U /opt/shared-agent-config/claude
  readlink ~/.claude
  test -L ~/.claude.json && echo "LINKED" || echo "NOT_LINKED"
  cat /opt/shared-agent-config/claude/skills/demo/SKILL.md 2>/dev/null || echo "MIGRATION_LOST"
  echo "written by container 1" > /opt/shared-agent-config/claude/skills/shared.md && echo "WROTE_OK" || echo "WRITE_DENIED"
')"
c1_chown="$(sed -n 1p <<<"$out1")"
check "no recursive chown needed on first mount (build-time trick)" "$c1_chown" "NO_CHOWN"
check "volume owned by remote user"           "$(sed -n 2p <<<"$out1")" "$REMOTE_USER"
check "~/.claude points into volume"          "$(sed -n 3p <<<"$out1")" "/opt/shared-agent-config/claude"
check "~/.claude.json deliberately NOT linked (installMethod is container-local)" \
      "$(sed -n 4p <<<"$out1")" "NOT_LINKED"
check "image-baked skill was migrated, not deleted" "$(sed -n 5p <<<"$out1")" "baked into the image"
check "remote user can write without chmod 777"     "$(sed -n 6p <<<"$out1")" "WROTE_OK"

echo
echo "==> container 2: independent container, same volume (the actual requirement)"
out2="$(run_as_user '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  cat ~/.claude/skills/shared.md
  cat ~/.claude/skills/demo/SKILL.md
')"
check "sees skill written by container 1"  "$(sed -n 1p <<<"$out2")" "written by container 1"
check "sees migrated skill"                "$(sed -n 2p <<<"$out2")" "baked into the image"

echo
echo "==> idempotency: hooks run twice (repo pins the feature AND it is a default feature)"
out3="$(run_as_user '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  /usr/local/share/shared-agent-config/setup.sh start  >/dev/null 2>&1
  readlink ~/.claude
  ls ~/.claude/skills | sort | tr "\n" "," 
')"
check "link still correct after repeated runs" "$(sed -n 1p <<<"$out3")" "/opt/shared-agent-config/claude"
check "no duplicated or lost skills"           "$(sed -n 2p <<<"$out3")" "demo,shared.md,"

echo
echo "==> start hook repairs a symlink clobbered by an atomic write"
out4="$(run_as_user '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  # simulate write-temp-then-rename, which replaces a symlink with a real file
  rm ~/.claude && mkdir -p /tmp/fresh && mv /tmp/fresh ~/.claude
  test -L ~/.claude && echo "STILL_LINK" || echo "CLOBBERED"
  /usr/local/share/shared-agent-config/setup.sh start >/dev/null 2>&1
  test -L ~/.claude && echo "REPAIRED" || echo "STILL_BROKEN"
  cat ~/.claude/skills/shared.md
')"
check "a replaced path is detected (premise for the start hook)" "$(sed -n 1p <<<"$out4")" "CLOBBERED"
check "start hook restores the link"                             "$(sed -n 2p <<<"$out4")" "REPAIRED"
check "shared content reachable again"                           "$(sed -n 3p <<<"$out4")" "written by container 1"

echo
echo "==> default configuration: linkHome=false"
IMAGE_NOLINK="$IMAGE-nolink"
ctx2="$(mktemp -d)"
cp "$FEATURE_DIR/install.sh" "$FEATURE_DIR/setup.sh" "$ctx2/"
cat > "$ctx2/Dockerfile" <<EOF
FROM $BASE_IMAGE
COPY install.sh setup.sh /tmp/feature/
RUN cd /tmp/feature && _REMOTE_USER=$REMOTE_USER _REMOTE_USER_HOME=/home/$REMOTE_USER \\
    LINKHOME=false sh ./install.sh
EOF
docker build -q -t "$IMAGE_NOLINK" "$ctx2" >/dev/null
rm -rf "$ctx2"
out5="$(docker run --rm -u "$REMOTE_USER" -v "$VOLUME:/opt/shared-agent-config" \
    -e CLAUDE_CONFIG_DIR=/opt/shared-agent-config/claude "$IMAGE_NOLINK" bash -lc '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  test -L ~/.claude && echo "LINKED" || echo "NOT_LINKED"
  cat "$CLAUDE_CONFIG_DIR/skills/shared.md"
')"
docker rmi -f "$IMAGE_NOLINK" >/dev/null 2>&1 || true
check "home is left untouched with linkHome=false" "$(sed -n 1p <<<"$out5")" "NOT_LINKED"
check "sharing works through CLAUDE_CONFIG_DIR alone" "$(sed -n 2p <<<"$out5")" "written by container 1"

echo
echo "==> Alpine/BusyBox, non-root user, no sudo (the persistence part must not need apt or bash)"
ALPINE_IMAGE="shared-agent-config-test-alpine:$$"
ALPINE_VOLUME="shared-agent-config-test-alpine-$$"
alpine_ctx="$(mktemp -d)"
cp "$FEATURE_DIR/install.sh" "$FEATURE_DIR/setup.sh" "$alpine_ctx/"
cat > "$alpine_ctx/Dockerfile" <<EOF
FROM alpine:3.20
RUN adduser -D dev
COPY install.sh setup.sh /tmp/feature/
RUN cd /tmp/feature && _REMOTE_USER=dev _REMOTE_USER_HOME=/home/dev LINKHOME=true sh ./install.sh
EOF
docker build -q -t "$ALPINE_IMAGE" "$alpine_ctx" >/dev/null
rm -rf "$alpine_ctx"
out6="$(docker run --rm -u dev -v "$ALPINE_VOLUME:/opt/shared-agent-config" "$ALPINE_IMAGE" sh -c '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1; echo "exit=$?"
  stat -c %U /opt/shared-agent-config/claude
  readlink ~/.claude
  echo hi > /opt/shared-agent-config/claude/probe && echo "WROTE_OK" || echo "WRITE_DENIED"
')"
docker volume rm -f "$ALPINE_VOLUME" >/dev/null 2>&1 || true
docker rmi -f "$ALPINE_IMAGE" >/dev/null 2>&1 || true
check "hook exits 0 under BusyBox sh"        "$(sed -n 1p <<<"$out6")" "exit=0"
check "volume owned by the non-root user"    "$(sed -n 2p <<<"$out6")" "dev"
check "~/.claude linked (linkHome=true)"     "$(sed -n 3p <<<"$out6")" "/opt/shared-agent-config/claude"
check "writable without sudo"                "$(sed -n 4p <<<"$out6")" "WROTE_OK"

echo
echo "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
