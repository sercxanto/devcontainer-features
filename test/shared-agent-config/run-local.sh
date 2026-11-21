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
# One per-devcontainer state volume per "devcontainer": STATE_A is reused across
# containers (a rebuild), STATE_B stands for another project.
STATE_A="shared-agent-config-test-state-a-$$"
STATE_B="shared-agent-config-test-state-b-$$"
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
    docker volume rm -f "$VOLUME" "$STATE_A" "$STATE_B" >/dev/null 2>&1 || true
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
# Same for opencode: a config dir and a credential file already in place.
RUN mkdir -p /home/$REMOTE_USER/.config/opencode/agents /home/$REMOTE_USER/.local/share/opencode \\
 && echo "baked agent" > /home/$REMOTE_USER/.config/opencode/agents/demo.md \\
 && echo "baked auth" > /home/$REMOTE_USER/.local/share/opencode/auth.json \\
 && echo "local db" > /home/$REMOTE_USER/.local/share/opencode/opencode.db \\
 && chown -R $REMOTE_USER:$REMOTE_USER /home/$REMOTE_USER/.config /home/$REMOTE_USER/.local
RUN cd /tmp/feature \\
 && _REMOTE_USER=$REMOTE_USER _REMOTE_USER_HOME=/home/$REMOTE_USER LINKHOME=true \\
    sh ./install.sh
EOF
docker build -q -t "$IMAGE" "$build_ctx" >/dev/null
rm -rf "$build_ctx"

STATE_VOL="${STATE_A}"
run_as_user() {   # run a command as the remote user in a fresh container
    docker run --rm -u "$REMOTE_USER" -v "$VOLUME:/opt/shared-agent-config" \
        -v "$STATE_VOL:/opt/agent-state/opencode" \
        -e CLAUDE_CONFIG_DIR=/opt/shared-agent-config/claude \
        -e OPENCODE_DB=/opt/agent-state/opencode/opencode.db "$IMAGE" bash -lc "$1"
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
  readlink ~/.config/opencode
  readlink ~/.local/share/opencode/auth.json
  cat /opt/shared-agent-config/opencode/config/agents/demo.md 2>/dev/null || echo "OC_CONFIG_LOST"
  cat /opt/shared-agent-config/opencode/auth.json 2>/dev/null || echo "OC_AUTH_LOST"
  cat "$OPENCODE_DB"   # carried over from the container-local db, once
  test -L ~/.local/share/opencode && echo "DATA_LINKED" || echo "DATA_LOCAL"
  stat -c %a /opt/shared-agent-config/opencode
  echo "oc secret" > ~/.local/share/opencode/mcp-auth.json   # created through a dangling link
  cat /opt/shared-agent-config/opencode/mcp-auth.json
  echo "db of container 1" > "$OPENCODE_DB"
  stat -c "%U %a" /opt/agent-state/opencode
  readlink ~/.local/share/opencode/snapshot
  readlink ~/.local/share/opencode/shell
  readlink ~/.config/opencode/service.json
  echo "snap" > ~/.local/share/opencode/snapshot/s1
  echo "sh-out" > ~/.local/share/opencode/shell/o1
  echo "pw-1" > ~/.config/opencode/service.json        # opencode writes its service password here
  cat /opt/agent-state/opencode/snapshot/s1 /opt/agent-state/opencode/shell/o1 /opt/agent-state/opencode/config-service.json | tr "\n" ","; echo
  test -L /opt/shared-agent-config/opencode/config/service.json && echo "LINK_IN_SHARED" || echo "REAL_FILE_IN_SHARED"
  readlink ~/.local/state/opencode
  s=~/.local/state/opencode
  echo "model-1" > /tmp/m && mv /tmp/m $s/model.json    # opencode writes model.json via rename (measured)
  echo "prompt-1" >> $s/prompt-history.jsonl
  mkdir -p $s/locks $s/pty $s/latest/locks $s/latest/tui
  touch $s/locks/l1 $s/pty/p1 $s/service.json $s/latest/locks/l2   # process state of this container
  echo "tabs" > $s/latest/tui/tabs.json
  cat /opt/agent-state/opencode/state/model.json /opt/agent-state/opencode/state/prompt-history.jsonl | tr "\n" ","; echo
')"
c1_chown="$(sed -n 1p <<<"$out1")"
check "no recursive chown needed on first mount (build-time trick)" "$c1_chown" "NO_CHOWN"
check "volume owned by remote user"           "$(sed -n 2p <<<"$out1")" "$REMOTE_USER"
check "~/.claude points into volume"          "$(sed -n 3p <<<"$out1")" "/opt/shared-agent-config/claude"
check "~/.claude.json deliberately NOT linked (installMethod is container-local)" \
      "$(sed -n 4p <<<"$out1")" "NOT_LINKED"
check "image-baked skill was migrated, not deleted" "$(sed -n 5p <<<"$out1")" "baked into the image"
check "remote user can write without chmod 777"     "$(sed -n 6p <<<"$out1")" "WROTE_OK"
check "opencode config dir linked into volume (no env var exists for it)" \
      "$(sed -n 7p <<<"$out1")" "/opt/shared-agent-config/opencode/config"
check "opencode auth.json linked into volume"       "$(sed -n 8p <<<"$out1")" "/opt/shared-agent-config/opencode/auth.json"
check "image-baked opencode agent migrated"         "$(sed -n 9p <<<"$out1")" "baked agent"
check "image-baked opencode credentials migrated"   "$(sed -n 10p <<<"$out1")" "baked auth"
check "existing opencode.db carried into the state volume" "$(sed -n 11p <<<"$out1")" "local db"
check "opencode data dir itself is not linked"      "$(sed -n 12p <<<"$out1")" "DATA_LOCAL"
check "opencode volume dir is 700"                  "$(sed -n 13p <<<"$out1")" "700"
check "file created through a dangling link lands in the volume" "$(sed -n 14p <<<"$out1")" "oc secret"
check "state volume owned by remote user, 700 (build-time trick)" "$(sed -n 15p <<<"$out1")" "$REMOTE_USER 700"
check "opencode snapshot/ lives in the state volume"    "$(sed -n 16p <<<"$out1")" "/opt/agent-state/opencode/snapshot"
check "opencode shell/ (command output) lives in the state volume" "$(sed -n 17p <<<"$out1")" "/opt/agent-state/opencode/shell"
check "service.json (service password) is redirected to the state volume" \
      "$(sed -n 18p <<<"$out1")" "/opt/agent-state/opencode/config-service.json"
check "files written through those links land in the state volume" \
      "$(sed -n 19p <<<"$out1")" "snap,sh-out,pw-1,"
check "the shared config dir holds only a link, no real service.json" "$(sed -n 20p <<<"$out1")" "LINK_IN_SHARED"
check "opencode state directory lives in the state volume" "$(sed -n 21p <<<"$out1")" "/opt/agent-state/opencode/state"
check "model.json written by rename (as opencode does) stays in the volume" \
      "$(sed -n 22p <<<"$out1")" "model-1,prompt-1,"

echo
echo "==> container 2: independent container, same volume (the actual requirement)"
out2="$(run_as_user '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  cat ~/.claude/skills/shared.md
  cat ~/.claude/skills/demo/SKILL.md
  cat ~/.local/share/opencode/auth.json
  cat ~/.config/opencode/agents/demo.md
  cat "$OPENCODE_DB"
  cat ~/.local/share/opencode/snapshot/s1 ~/.local/share/opencode/shell/o1 ~/.config/opencode/service.json | tr "\n" ","; echo
  s=~/.local/state/opencode
  cat $s/model.json $s/prompt-history.jsonl $s/latest/tui/tabs.json | tr "\n" ","; echo
  test -e $s/locks/l1 -o -e $s/pty/p1 -o -e $s/service.json -o -e $s/latest/locks/l2 && echo "STALE_PROCESS_STATE" || echo "PROCESS_STATE_CLEARED"
')"
echo "    (same state volume, new container: a rebuild.  next: other state volume, another project)"
STATE_VOL="$STATE_B"
out2b="$(run_as_user '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  cat "$OPENCODE_DB"
  cat ~/.local/share/opencode/auth.json
  find ~/.local/share/opencode/snapshot/ ~/.local/share/opencode/shell/ -type f | wc -l
  cat ~/.config/opencode/service.json 2>/dev/null && echo "SERVICE_PW_SHARED" || echo "SERVICE_PW_PER_CONTAINER"
  cat ~/.local/state/opencode/model.json 2>/dev/null || echo "NO_MODEL"
')"
STATE_VOL="$STATE_A"
check "sees skill written by container 1"  "$(sed -n 1p <<<"$out2")" "written by container 1"
check "sees migrated skill"                "$(sed -n 2p <<<"$out2")" "baked into the image"
check "opencode login from container 1 visible"  "$(sed -n 3p <<<"$out2")" "baked auth"
check "opencode agents from container 1 visible" "$(sed -n 4p <<<"$out2")" "baked agent"
check "opencode sessions survive a rebuild (same state volume)" "$(sed -n 5p <<<"$out2")" "db of container 1"
check "snapshot/, shell/ and the service password survive a rebuild" "$(sed -n 6p <<<"$out2")" "snap,sh-out,pw-1,"
check "model, prompt history and TUI tabs survive a rebuild"        "$(sed -n 7p <<<"$out2")" "model-1,prompt-1,tabs,"
check "locks, pty and service.json of the old container are cleared" "$(sed -n 8p <<<"$out2")" "PROCESS_STATE_CLEARED"
check "opencode sessions are NOT shared with another project"    "$(sed -n 1p <<<"$out2b")" "local db"
check "...while its login is shared"                             "$(sed -n 2p <<<"$out2b")" "baked auth"
check "...and its snapshot/ and shell/ are empty"          "$(sed -n 3p <<<"$out2b")" "0"
check "...and it does not inherit the other container's service password" \
      "$(sed -n 4p <<<"$out2b")" "SERVICE_PW_PER_CONTAINER"
check "...nor the other project's model choice"                  "$(sed -n 5p <<<"$out2b")" "NO_MODEL"

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
  readlink ~/.local/share/opencode/auth.json
  # relocated XDG dirs are honoured
  rm -rf ~/.config/opencode ~/.local/share/opencode
  XDG_CONFIG_HOME=/tmp/xdg/c XDG_DATA_HOME=/tmp/xdg/d /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  readlink /tmp/xdg/c/opencode
  readlink /tmp/xdg/d/opencode/auth.json
')"
docker rmi -f "$IMAGE_NOLINK" >/dev/null 2>&1 || true
check "home is left untouched with linkHome=false" "$(sed -n 1p <<<"$out5")" "NOT_LINKED"
check "sharing works through CLAUDE_CONFIG_DIR alone" "$(sed -n 2p <<<"$out5")" "written by container 1"
check "opencode is linked even with linkHome=false (it has no env var)" \
      "$(sed -n 3p <<<"$out5")" "/opt/shared-agent-config/opencode/auth.json"
check "XDG_CONFIG_HOME is honoured for the opencode config dir" \
      "$(sed -n 4p <<<"$out5")" "/opt/shared-agent-config/opencode/config"
check "XDG_DATA_HOME is honoured for opencode credentials" \
      "$(sed -n 5p <<<"$out5")" "/opt/shared-agent-config/opencode/auth.json"

echo
echo "==> start hook repairs opencode credentials replaced by an atomic write"
out7="$(run_as_user '
  /usr/local/share/shared-agent-config/setup.sh create >/dev/null 2>&1
  f=~/.local/share/opencode/auth.json
  echo "fresh token" > /tmp/new && mv /tmp/new "$f"      # write-temp-then-rename
  test -L "$f" && echo "STILL_LINK" || echo "CLOBBERED"
  /usr/local/share/shared-agent-config/setup.sh start >/dev/null 2>&1
  test -L "$f" && echo "REPAIRED" || echo "STILL_BROKEN"
  cat /opt/shared-agent-config/opencode/auth.json
')"
check "replaced auth.json is detected"        "$(sed -n 1p <<<"$out7")" "CLOBBERED"
check "start hook restores the link"          "$(sed -n 2p <<<"$out7")" "REPAIRED"
check "volume content wins over the clobbered copy (cp -n, shared state is the source of truth)" \
      "$(sed -n 3p <<<"$out7")" "baked auth"

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
  readlink ~/.config/opencode
')"
docker volume rm -f "$ALPINE_VOLUME" >/dev/null 2>&1 || true
docker rmi -f "$ALPINE_IMAGE" >/dev/null 2>&1 || true
check "hook exits 0 under BusyBox sh"        "$(sed -n 1p <<<"$out6")" "exit=0"
check "volume owned by the non-root user"    "$(sed -n 2p <<<"$out6")" "dev"
check "~/.claude linked (linkHome=true)"     "$(sed -n 3p <<<"$out6")" "/opt/shared-agent-config/claude"
check "writable without sudo"                "$(sed -n 4p <<<"$out6")" "WROTE_OK"
check "opencode config linked under BusyBox" "$(sed -n 5p <<<"$out6")" "/opt/shared-agent-config/opencode/config"

echo
echo "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
