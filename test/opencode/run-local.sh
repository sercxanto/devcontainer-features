#!/usr/bin/env bash
#
# Exercises install.sh against plain Docker -- no devcontainer CLI needed.
# install.sh runs as root, as the devcontainer runtime would run it at build
# time; the results are then inspected as an ordinary user.
#
# What it proves:
#   1. default install gives opencode 2.x on PATH for every user
#   2. nothing lands in root's home (the installer's rc-file edits are fenced off)
#   3. a version pin is honoured, and a second run (double install) is harmless
#   4. missing curl/tar/bash and a malformed version fail with a clear message
#   5. Alpine/musl: runs once bash, curl, tar, libstdc++, libgcc are installed;
#      without libstdc++ it fails with a hint instead of a broken binary
#   6. the manifest registers the VS Code extension
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FEATURE_DIR="$REPO_ROOT/src/opencode"
BASE_IMAGE="${BASE_IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
PIN="${PIN:-2.3.1}"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1))
    else
        printf '  \033[31mFAIL\033[0m %s\n        expected: %s\n        actual:   %s\n' "$1" "$3" "$2"
        fail=$((fail+1))
    fi
}

# in_image <image> <script>: run a script as root with the feature mounted.
in_image() {
    docker run --rm -v "$FEATURE_DIR:/feat:ro" "$1" sh -c "$2" 2>&1 </dev/null
}

echo "==> default install on $BASE_IMAGE"
out="$(in_image "$BASE_IMAGE" '
  VERSION=latest sh /feat/install.sh >/tmp/log 2>&1 || { echo INSTALL_FAILED; tail -5 /tmp/log; exit 0; }
  echo "VERSION=$(opencode --version </dev/null)"
  echo "WHICH=$(command -v opencode)"
  echo "ROOT_HOME=$(ls -A /root | grep -c opencode || true)"
  echo "AS_USER=$(su vscode -c "opencode --version </dev/null")"
  echo "MODE=$(stat -c %a /usr/local/bin/opencode)"
  VERSION=latest sh /feat/install.sh >/dev/null 2>&1 && echo "SECOND_RUN=ok" || echo "SECOND_RUN=failed"
')"
check "install succeeds"                    "$(echo "$out" | grep -c INSTALL_FAILED || true)" "0"
check "opencode is a 2.x"                   "$(echo "$out" | sed -n 's/^VERSION=\(opencode \)\{0,1\}v\{0,1\}\([0-9]*\)\..*/\2/p')" "2"
check "lives in /usr/local/bin"             "$(echo "$out" | sed -n 's/^WHICH=//p')" "/usr/local/bin/opencode"
check "no installer files left in /root"    "$(echo "$out" | sed -n 's/^ROOT_HOME=//p')" "0"
check "runs for an ordinary user"           "$(echo "$out" | sed -n 's/^AS_USER=\(opencode \)\{0,1\}v\{0,1\}\([0-9]*\)\..*/\2/p')" "2"
check "mode 755"                            "$(echo "$out" | sed -n 's/^MODE=//p')" "755"
check "second run is harmless"              "$(echo "$out" | sed -n 's/^SECOND_RUN=//p')" "ok"

echo
echo "==> version pin $PIN"
out="$(in_image "$BASE_IMAGE" "
  VERSION=$PIN sh /feat/install.sh >/tmp/log 2>&1 || { echo INSTALL_FAILED; tail -5 /tmp/log; exit 0; }
  echo \"VERSION=\$(opencode --version </dev/null)\"
")"
check "pinned version is installed"         "$(echo "$out" | sed -n 's/^VERSION=\(opencode \)\{0,1\}v\{0,1\}//p')" "$PIN"

echo
echo "==> failure modes"
out="$(in_image debian:12-slim 'VERSION=latest sh /feat/install.sh; echo "RC=$?"')"
check "missing curl: fails"                 "$(echo "$out" | sed -n 's/^RC=//p')" "1"
check "missing curl: says what is missing"  "$(echo "$out" | grep -c 'missing in the base image: curl')" "1"
out="$(in_image "$BASE_IMAGE" 'VERSION="2.3;touch /pwned" sh /feat/install.sh; echo "RC=$?"; test -e /pwned && echo PWNED || echo SAFE')"
check "malformed version: fails"            "$(echo "$out" | sed -n 's/^RC=//p')" "1"
check "malformed version: nothing executed" "$(echo "$out" | grep -c '^SAFE$')" "1"

echo
echo "==> Alpine (musl)"
out="$(in_image alpine:3 '
  apk add -q bash curl tar >/dev/null 2>&1
  VERSION=latest sh /feat/install.sh; echo "RC=$?"
')"
check "Alpine without libstdc++: fails"      "$(echo "$out" | sed -n 's/^RC=//p')" "1"
check "Alpine without libstdc++: says why"   "$(echo "$out" | grep -c 'apk add libstdc++ libgcc')" "1"
out="$(in_image alpine:3 '
  apk add -q bash curl tar libstdc++ libgcc >/dev/null 2>&1
  VERSION=latest sh /feat/install.sh >/tmp/log 2>&1 || { echo INSTALL_FAILED; tail -5 /tmp/log; exit 0; }
  echo "VERSION=$(opencode --version </dev/null 2>&1)"
')"
check "Alpine with libstdc++: installs and runs" "$(echo "$out" | sed -n 's/^VERSION=\(opencode \)\{0,1\}v\{0,1\}\([0-9]*\)\..*/\2/p')" "2"

echo
echo "==> manifest"
check "VS Code extension is registered"     "$(grep -c '"sst-dev.opencode"' "$FEATURE_DIR/devcontainer-feature.json")" "1"
check "does not claim a mount or env"       "$(grep -cE '"(mounts|containerEnv)"' "$FEATURE_DIR/devcontainer-feature.json")" "0"

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
