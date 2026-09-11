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
# Adding an agent: one setup_agent line in main, plus the matching entries in
# install.sh (AGENT_DIRS) and devcontainer-feature.json (containerEnv).

set -u

REMOTE_USER="@@REMOTE_USER@@"
REMOTE_GROUP="@@REMOTE_GROUP@@"
HOME_DIR="@@REMOTE_USER_HOME@@"
LINK_HOME="@@LINK_HOME@@"

SHARED_ROOT="/opt/shared-agent-config"

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
    want="$(id -u "${REMOTE_USER}" 2>/dev/null || echo)"
    [ -n "${want}" ] || return 0

    if [ -d "${SHARED_ROOT}" ]; then
        have="$(stat -c %u "${SHARED_ROOT}" 2>/dev/null || stat -f %u "${SHARED_ROOT}" 2>/dev/null || echo)"
        if [ "${have}" = "${want}" ]; then
            return 0   # already ours; skip the expensive walk
        fi
    fi

    log "claiming ${SHARED_ROOT} for ${REMOTE_USER} (uid ${want}); this runs once per volume"
    if ! as_root mkdir -p "${SHARED_ROOT}"; then
        mkdir -p "${SHARED_ROOT}" 2>/dev/null || {
            warn "cannot create ${SHARED_ROOT} and no passwordless sudo available"
            warn "sharing is NOT active; agents will fall back to container-local config"
            return 1
        }
    fi
    as_root chown -R "${REMOTE_USER}:${REMOTE_GROUP}" "${SHARED_ROOT}" 2>/dev/null \
        || warn "chown of ${SHARED_ROOT} failed; writes may be denied"
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

# --- main --------------------------------------------------------------------
case "${MODE}" in
    create|start) ;;
    *) warn "unknown mode '${MODE}'"; exit 0 ;;
esac

if [ "${MODE}" = "create" ]; then
    ensure_ownership || exit 0
fi

# Claude Code. Reads CLAUDE_CONFIG_DIR and keeps everything there, including
# .claude.json (measured, see README). ~/.claude.json is deliberately never
# linked: it also carries installMethod/autoUpdates, which describe the
# installation in *this* image.
setup_agent "claude" ".claude"

[ "${MODE}" = "create" ] && log "ready: shared root ${SHARED_ROOT}"
exit 0
