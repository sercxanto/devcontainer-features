#!/usr/bin/env bash
#
# Pull-request check for feature versions. Publishing is driven by the
# `version` field in each devcontainer-feature.json: a merge to main publishes
# exactly the features whose version does not exist in the registry yet. This
# script makes the consequences of a PR visible before the merge.
#
#   changed, version unchanged   -> notice (legitimate: batching changes)
#   version changed, not greater -> error  (typo, bad merge resolution)
#   version changed, exists      -> error  (publish would silently skip it)
#   version changed, new         -> ok, reported
#
# Usage: version-check.sh <base-ref> <registry-namespace>
#   e.g. version-check.sh origin/main ghcr.io/sercxanto/devcontainer-features
#
# Registry auth: set REGISTRY_USER and REGISTRY_TOKEN (GITHUB_ACTOR /
# GITHUB_TOKEN in CI) so private packages resolve; anonymous works for public
# ones. If the package cannot be queried at all -- typically because it has
# never been published -- that is reported as a notice, not an error.

set -euo pipefail

BASE="${1:?base ref}"
NAMESPACE="${2:?registry namespace, e.g. ghcr.io/owner/repo}"
REGISTRY="${NAMESPACE%%/*}"           # ghcr.io
REPO_PATH="${NAMESPACE#*/}"           # owner/repo

# registry_status <feature-id> <version>  ->  prints 200 / 404 / other
registry_status() {
    local scope="repository:${REPO_PATH}/$1:pull"
    local auth=()
    [ -n "${REGISTRY_USER:-}" ] && auth=(-u "${REGISTRY_USER}:${REGISTRY_TOKEN:-}")
    local token
    token="$(curl -fsS ${auth[@]+"${auth[@]}"} "https://${REGISTRY}/token?scope=${scope}" 2>/dev/null \
             | jq -r '.token // empty' 2>/dev/null || true)"
    [ -n "$token" ] || { echo "no-token"; return; }
    curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        "https://${REGISTRY}/v2/${REPO_PATH}/$1/manifests/$2"
}

merge_base="$(git merge-base "$BASE" HEAD)"
status=0

for dir in src/*/; do
    id="$(basename "$dir")"
    manifest="${dir}devcontainer-feature.json"
    [ -f "$manifest" ] || continue

    if [ -z "$(git diff --name-only "$merge_base" HEAD -- "$dir")" ]; then
        continue   # feature untouched by this PR
    fi

    head_v="$(jq -r '.version' "$manifest")"
    base_v="$(git show "${merge_base}:${manifest}" 2>/dev/null | jq -r '.version' 2>/dev/null || true)"

    if ! [[ "$head_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "::error file=${manifest}::${id}: version '${head_v}' is not MAJOR.MINOR.PATCH"
        status=1; continue
    fi

    if [ "$head_v" = "$base_v" ]; then
        echo "::notice file=${manifest}::${id} changed but version is still ${head_v} — merging will not publish it"
        continue
    fi

    if [ -n "$base_v" ] && [ "$(printf '%s\n%s\n' "$base_v" "$head_v" | sort -V | tail -n1)" != "$head_v" ]; then
        echo "::error file=${manifest}::${id}: version ${head_v} is not greater than ${base_v} on ${BASE}"
        status=1; continue
    fi

    case "$(registry_status "$id" "$head_v")" in
        200)
            echo "::error file=${manifest}::${id}: version ${head_v} already exists in ${NAMESPACE} — publishing would be skipped"
            status=1 ;;
        404)
            echo "${id}: ${base_v:-(new feature)} -> ${head_v}; not in ${NAMESPACE} yet, will publish on merge" ;;
        *)
            echo "::notice file=${manifest}::${id}: ${base_v:-(new feature)} -> ${head_v}; could not query ${NAMESPACE} (unpublished package, or no access) — will publish on merge if the version is new" ;;
    esac
done

exit $status
