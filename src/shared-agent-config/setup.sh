#!/usr/bin/env sh
#
# Runtime hook. Runs as the remote user, with the shared volume mounted.
#
#   setup.sh create   -- postCreateCommand, once per container
#   setup.sh start    -- postStartCommand, every start; O(1), no recursion
#
# Never fails the container: a broken share is worth reporting, not worth
# blocking someone's dev environment over. Every step is idempotent, because
# double installation is a real case (repo pins the feature *and* it is a
# default feature).
#
# Adding an agent: a call in main, plus the matching entry in install.sh
# (AGENT_DIRS) and, if the agent has a config-dir variable, in
# devcontainer-feature.json (containerEnv). See the feature README.

set -u

REMOTE_USER="@@REMOTE_USER@@"
REMOTE_GROUP="@@REMOTE_GROUP@@"
HOME_DIR="@@REMOTE_USER_HOME@@"
LINK_HOME="@@LINK_HOME@@"

SHARED_ROOT="/opt/shared-agent-config"
STATE_ROOT="/opt/agent-state"

MODE="${1:-create}"

log()  { echo "[shared-agent-config] $*"; }
warn() { echo "[shared-agent-config] WARNING: $*" >&2; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
    else
        return 1
    fi
}

# --- ownership ---------------------------------------------------------------
# The build-time chown in install.sh covers the very first container, the one
# that populates an empty volume (Docker copies image content into the volume
# including ownership). Later containers mount a volume that is no longer
# empty, so nothing is copied and the owner may not match -- e.g. the volume
# was created by an image whose remote user has a different UID.
#
# The recursive walk is gated on the owner of the volume root, so it happens
# at most once per (volume, uid) pair. Without that gate this is the
# `chmod -R 777` mistake of the feature this replaces: it gets slower every
# time a session-history directory grows.
ensure_ownership() {
    root="${1:-${SHARED_ROOT}}"
    want="$(id -u "${REMOTE_USER}" 2>/dev/null || echo)"
    [ -n "${want}" ] || return 0

    if [ -d "${root}" ]; then
        have="$(stat -c %u "${root}" 2>/dev/null || stat -f %u "${root}" 2>/dev/null || echo)"
        if [ "${have}" = "${want}" ]; then
            return 0   # already ours; skip the expensive walk
        fi
    fi

    log "claiming ${root} for ${REMOTE_USER} (uid ${want}); this runs once per volume"
    if ! as_root mkdir -p "${root}"; then
        mkdir -p "${root}" 2>/dev/null || {
            warn "cannot create ${root} and no passwordless sudo available"
            warn "sharing is NOT active; agents will fall back to container-local config"
            return 1
        }
    fi
    as_root chown -R "${REMOTE_USER}:${REMOTE_GROUP}" "${root}" 2>/dev/null \
        || warn "chown of ${root} failed; writes may be denied"
    return 0
}

# --- migration ---------------------------------------------------------------
# Anything already sitting in the home directory is moved into the volume
# before the path is replaced -- image-baked skills, a config from an earlier
# run without this feature. `cp -Rn` never overwrites what the volume already
# holds: the shared state wins, the local copy only fills gaps.
migrate_into_volume() {
    src="$1"
    dst="$2"
    [ -e "${src}" ] || return 0
    [ -L "${src}" ] && return 0          # already a link, nothing of ours there

    if [ -d "${src}" ]; then
        log "migrating existing ${src} into the shared volume"
        cp -Rn "${src}/." "${dst}/" 2>/dev/null || true
    else
        if [ ! -e "${dst}" ]; then
            log "migrating existing ${src} into the shared volume"
            cp -n "${src}" "${dst}" 2>/dev/null || true
        fi
    fi
    as_root rm -rf "${src}" 2>/dev/null || rm -rf "${src}" 2>/dev/null || {
        warn "could not remove ${src}; leaving it in place, sharing may be partial"
        return 1
    }
    return 0
}

# --- linking -----------------------------------------------------------------
# The environment variables are what the agents themselves read; these links
# only exist for tooling that hardcodes the home paths, and are off by default.
#
# They are re-checked on every start, not just on create: a writer that saves
# atomically (write temp + rename) replaces a symlink with a real file, which
# would silently drop that path out of the shared volume.
ensure_link() {
    link="$1"
    target="$2"

    if [ -L "${link}" ]; then
        current="$(readlink "${link}" 2>/dev/null || echo)"
        [ "${current}" = "${target}" ] && return 0
        log "repointing ${link} -> ${target}"
    elif [ -e "${link}" ]; then
        migrate_into_volume "${link}" "${target}" || return 1
    fi

    mkdir -p "$(dirname "${link}")" 2>/dev/null || true
    ln -sfn "${target}" "${link}" 2>/dev/null || {
        warn "could not create symlink ${link}"
        return 1
    }
    return 0
}

# --- per agent ---------------------------------------------------------------
# setup_agent <subdir> <home path relative to $HOME>
#
# The subdirectory is the agent's config dir inside the volume; the matching
# environment variable in devcontainer-feature.json points the agent there.
# The home path is only linked when linkHome=true.
setup_agent() {
    dir="${SHARED_ROOT}/$1"
    home_path="${HOME_DIR}/$2"

    case "${MODE}" in
        create)
            mkdir -p "${dir}" 2>/dev/null || { warn "cannot create ${dir}"; return 1; }
            chmod 700 "${dir}" 2>/dev/null || true
            [ "${LINK_HOME}" = "true" ] && ensure_link "${home_path}" "${dir}"
            ;;
        start)
            # Cheap repair only -- one readlink call, no directory walk.
            [ "${LINK_HOME}" = "true" ] && [ -d "${dir}" ] && ensure_link "${home_path}" "${dir}"
            ;;
    esac
    return 0
}

# --- agents without a config-dir variable -------------------------------------
# opencode has no variable that relocates its config *and* its credentials:
# OPENCODE_CONFIG_DIR is additive (an extra place to look for agents/commands/
# plugins), and moving the XDG_* variables would relocate every other tool's
# data too. So its paths are linked unconditionally -- not behind linkHome --
# and only the parts worth sharing, never the whole data dir (see README).
#
# share_dir  <absolute target in a volume> <home-side path>
# share_file <absolute target in a volume> <home-side path>
#
# A file target is not created up front: a link to a missing file is fine, the
# agent creates it through the link on first write.
share_dir() {
    target="$1"
    case "${MODE}" in
        create) mkdir -p "${target}" 2>/dev/null || { warn "cannot create ${target}"; return 1; }
                ensure_link "$2" "${target}" ;;
        start)  [ -d "${target}" ] && ensure_link "$2" "${target}" ;;
    esac
    return 0
}

share_file() {
    target="$1"
    case "${MODE}" in
        create|start) [ -d "$(dirname "${target}")" ] && ensure_link "$2" "${target}" ;;
    esac
    return 0
}

# Process state inside opencode's state directory. Called only on create, where
# the previous container's processes are gone.
clear_process_state() {
    base="$1"
    [ -n "${base}" ] && [ -d "${base}" ] || return 0
    rm -rf "${base}/pty" "${base}/service.json" "${base}/locks" 2>/dev/null
    for d in "${base}"/*/locks; do
        [ -d "${d}" ] && rm -rf "${d}"
    done
    return 0
}

setup_opencode() {
    dir="${SHARED_ROOT}/opencode"
    if [ "${MODE}" = "create" ]; then
        mkdir -p "${dir}" 2>/dev/null || { warn "cannot create ${dir}"; return 1; }
        chmod 700 "${dir}" 2>/dev/null || true
    fi
    # Sessions: OPENCODE_DB (containerEnv) points into the per-devcontainer
    # state volume, so they survive a rebuild without being shared. An
    # opencode.db that already exists in the container (from before the volume
    # existed) is carried over once; cp -n never overwrites.
    if [ "${MODE}" = "create" ]; then
        old="${XDG_DATA_HOME:-${HOME_DIR}/.local/share}/opencode"
        new="${STATE_ROOT}/opencode"
        if [ -f "${old}/opencode.db" ] && [ ! -e "${new}/opencode.db" ] && [ -d "${new}" ]; then
            log "carrying over existing opencode sessions into ${new}"
            cp -n "${old}"/opencode.db "${old}"/opencode.db-wal "${old}"/opencode.db-shm "${new}/" 2>/dev/null || true
        fi
    fi
    # Honour relocated XDG directories; the hooks run with containerEnv set.
    config="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/opencode"
    data="${XDG_DATA_HOME:-${HOME_DIR}/.local/share}/opencode"
    state="${XDG_STATE_HOME:-${HOME_DIR}/.local/state}/opencode"

    share_dir  "${SHARED_ROOT}/opencode/config"        "${config}"
    share_file "${SHARED_ROOT}/opencode/auth.json"     "${data}/auth.json"
    share_file "${SHARED_ROOT}/opencode/mcp-auth.json" "${data}/mcp-auth.json"

    # What belongs to the sessions in opencode.db goes into the per-devcontainer
    # state volume with it: without snapshot/ (shadow git repos) a restored
    # session cannot be reverted, without shell/ (the full output of commands)
    # its long results are gone. Same lifetime as the database, never shared.
    if [ -d "${STATE_ROOT}/opencode" ]; then
        share_dir "${STATE_ROOT}/opencode/snapshot"    "${data}/snapshot"
        share_dir "${STATE_ROOT}/opencode/shell"       "${data}/shell"

        # opencode keeps the password of its local background service in
        # <config>/service.json -- inside the shared config dir, but it belongs
        # to this container's service (state/service.json holds the matching
        # pid and port). Redirect that one file into the per-devcontainer
        # volume. The link lives in the shared volume and is the same for every
        # container; where the target does not exist, opencode creates it.
        share_file "${STATE_ROOT}/opencode/config-service.json" "${config}/service.json"

        # The TUI's state: recent models, prompt history, tabs, seen hints.
        # The whole directory is linked, not single files: opencode writes
        # model.json via a temp file and rename, which replaces a file symlink
        # (measured) and would silently drop that file out of the volume.
        # Inside a linked directory the rename stays inside the volume.
        #
        # The price is that process state lives there too -- locks, pty
        # sessions, pid and port of the background service. When a container is
        # created, nothing of an earlier container is running any more, so that
        # is cleared. (Channel directories such as latest/ have their own locks.)
        share_dir "${STATE_ROOT}/opencode/state" "${state}"
        if [ "${MODE}" = "create" ]; then
            clear_process_state "${STATE_ROOT}/opencode/state"
        fi
    fi
    return 0
}

# --- main --------------------------------------------------------------------
case "${MODE}" in
    create|start) ;;
    *) warn "unknown mode '${MODE}'"; exit 0 ;;
esac

if [ "${MODE}" = "create" ]; then
    ensure_ownership "${SHARED_ROOT}" || exit 0
    ensure_ownership "${STATE_ROOT}/opencode" || true   # the per-devcontainer volume
fi

# Claude Code. Reads CLAUDE_CONFIG_DIR and keeps everything there, including
# .claude.json (measured, see README). ~/.claude.json is deliberately never
# linked: it also carries installMethod/autoUpdates, which describe the
# installation in *this* image.
setup_agent "claude" ".claude"

# opencode. Config dir + credential files, linked into the volume.
setup_opencode

[ "${MODE}" = "create" ] && log "ready: shared root ${SHARED_ROOT}"
exit 0
