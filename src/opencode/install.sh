#!/usr/bin/env sh
#
# Installs the opencode 2.x CLI to /usr/local/bin, for every user.
#
# This is POSIX sh, but it cannot avoid the network: it runs the official
# installer (https://opencode.ai/v2/install), which needs curl, tar and bash.
# A missing tool is reported and fails the build -- unlike the runtime hooks
# of shared-agent-config, a feature that was asked to install a tool and did
# not must not pretend to have succeeded. Nothing here installs packages.

set -eu

VERSION="${VERSION:-latest}"
INSTALL_URL="https://opencode.ai/v2/install"
TARGET="/usr/local/bin/opencode"

fail() { echo "opencode feature: $*" >&2; exit 1; }

case "${VERSION}" in
    latest|"") want="" ;;
    *[!0-9A-Za-z._+-]*) fail "invalid version '${VERSION}'" ;;
    *) want="${VERSION}" ;;
esac

missing=""
for tool in curl tar bash; do
    command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
[ -z "${missing}" ] || fail "missing in the base image:${missing}. Install them first (e.g. add the common-utils feature, or apt-get/apk add) -- this feature does not install packages."

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

curl -fsSL "${INSTALL_URL}" -o "${work}/install.sh" \
    || fail "could not download ${INSTALL_URL}"

# The installer writes to $HOME/.opencode and edits shell rc files. Give it a
# throwaway HOME so nothing of that lands in root's home, then move the single
# self-contained binary to /usr/local/bin (measured: it runs from anywhere).
#
# VERSION must not leak into it: the installer reads that variable itself, and
# the option's default "latest" is not a version it knows (404). The pin goes
# in explicitly, via --version.
unset VERSION
set -- --no-modify-path
[ -z "${want}" ] || set -- "$@" --version "${want}"
HOME="${work}" bash "${work}/install.sh" "$@" </dev/null \
    || fail "the opencode installer failed"

[ -x "${work}/.opencode/bin/opencode" ] || fail "installer did not produce a binary"
mkdir -p "$(dirname "${TARGET}")"
install -m 0755 "${work}/.opencode/bin/opencode" "${TARGET}"

# Idempotent: a second run replaces the binary. Verify what is actually there.
got="$(HOME="${work}" "${TARGET}" --version </dev/null 2>/dev/null)" \
    || { hint=""
         [ ! -e /etc/alpine-release ] || hint=" On Alpine the binary needs libstdc++ and libgcc: apk add libstdc++ libgcc"
         fail "installed binary does not run.${hint}"; }
case "${got}" in
    *" v2."*|*" 2."*|v2.*|2.*) ;;
    *) fail "expected opencode 2.x, got '${got}'" ;;
esac
echo "opencode feature: installed ${got} at ${TARGET}"
