#!/usr/bin/env sh
#
# Build time. Runs as root, inside the image, with the shared volume NOT mounted.
#
# Two jobs:
#   1. Create /opt/shared-agent-config in the *image* and hand it to the remote
#      user. When Docker later mounts an EMPTY named volume over a path that
#      already has content, it copies that content into the volume -- including
#      owner and mode. That is what spares us a recursive chown at runtime.
#   2. Install the runtime hook, with the feature-time variables baked in
#      (the hook runs later without _REMOTE_USER et al. in its environment).
#
# Deliberately POSIX sh and free of apt/curl: this feature only makes
# directories and symlinks, so it must work on any base image.
#
# Adding an agent: add its subdirectory to AGENT_DIRS here, its environment
# variable to containerEnv in devcontainer-feature.json, and a setup_agent line
# in setup.sh.

set -eu

SHARED_ROOT="/opt/shared-agent-config"
# Per-devcontainer state: one volume per devcontainer (named with
# ${devcontainerId}), mounted at STATE_ROOT/<agent>. It survives a rebuild of
# that container but is not shared with other containers.
STATE_ROOT="/opt/agent-state"
STATE_DIRS="opencode"
HOOK_DIR="/usr/local/share/shared-agent-config"
AGENT_DIRS="claude opencode"

REMOTE_USER="${_REMOTE_USER:-root}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-/root}"
LINK_HOME="${LINKHOME:-false}"

echo "[shared-agent-config] build-time setup for user '${REMOTE_USER}' (home ${REMOTE_USER_HOME})"

# --- 1. seed the mount point, owned by the remote user -----------------------
for agent in ${AGENT_DIRS}; do
    mkdir -p "${SHARED_ROOT}/${agent}"
done

if [ "${REMOTE_USER}" != "root" ]; then
    # Resolve the primary group; fall back to a same-named group, then to the
    # user itself, which is what most devcontainer base images use anyway.
    REMOTE_GROUP="$(id -gn "${REMOTE_USER}" 2>/dev/null || echo "${REMOTE_USER}")"
else
    REMOTE_GROUP="root"
fi

for agent in ${STATE_DIRS}; do
    mkdir -p "${STATE_ROOT}/${agent}"
done

chown -R "${REMOTE_USER}:${REMOTE_GROUP}" "${SHARED_ROOT}" "${STATE_ROOT}"
for agent in ${STATE_DIRS}; do
    chmod 700 "${STATE_ROOT}/${agent}"
done
for agent in ${AGENT_DIRS}; do
    chmod 700 "${SHARED_ROOT}/${agent}"   # credentials live here -- not world-readable
done

# --- 2. install the runtime hook ---------------------------------------------
mkdir -p "${HOOK_DIR}"
install -m 0755 setup.sh "${HOOK_DIR}/setup.sh"

sed -i \
    -e "s|@@REMOTE_USER@@|${REMOTE_USER}|g" \
    -e "s|@@REMOTE_GROUP@@|${REMOTE_GROUP}|g" \
    -e "s|@@REMOTE_USER_HOME@@|${REMOTE_USER_HOME}|g" \
    -e "s|@@LINK_HOME@@|${LINK_HOME}|g" \
    "${HOOK_DIR}/setup.sh"

echo "[shared-agent-config] done; shared root is ${SHARED_ROOT}"
