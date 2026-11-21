#!/usr/bin/env bash
# =============================================================================
# build-release.sh — render every manifest entry into release assets.
#
# The one place that turns a site (deploy-manifest.json + config/ + secrets)
# into the files a router downloads. release.yml calls it; so can you, to see
# exactly what would ship:
#
#   scripts/build-release.sh dist          # template mode (this repo)
#   gitops/scripts/build-release.sh dist   # per-router repo, engine as submodule
#
# Run from the SITE root (the repo that holds deploy-manifest.json), or set
# GITOPS_SITE_ROOT. Secret values come from the environment or from
# GITOPS_SECRETS_JSON / GITOPS_VARS_JSON — see scripts/render.sh.
# =============================================================================
set -euo pipefail

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_ROOT="$(cd "${GITOPS_SITE_ROOT:-$PWD}" && pwd)"
export GITOPS_SITE_ROOT="$SITE_ROOT"
OUT="${1:?usage: build-release.sh <out-dir>}"
MANIFEST="$SITE_ROOT/deploy-manifest.json"

command -v jq >/dev/null || { echo "build-release.sh: jq is required" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "build-release.sh: no deploy-manifest.json in $SITE_ROOT" >&2; exit 1; }

# Exactly one entry must be the pull agent, and it must be last: a broken
# release can then still be replaced by the next one.
selfs=$(jq '[.[] | select(.self == true)] | length' "$MANIFEST")
last_self=$(jq '.[-1].self == true' "$MANIFEST")
if [[ "$selfs" != "1" || "$last_self" != "true" ]]; then
    echo "build-release.sh: manifest needs exactly one \"self\": true entry, as the LAST entry" >&2
    exit 1
fi

mkdir -p "$OUT"
jq -c '.[]' "$MANIFEST" | while read -r entry; do
    path=$(printf '%s' "$entry" | jq -r '.path')
    asset=$(printf '%s' "$entry" | jq -r '.asset')
    "$ENGINE_ROOT/scripts/render.sh" "$SITE_ROOT/$path" "$OUT/$asset"
    echo "  rendered $path -> $asset"
done

# The manifest travels with the release, so a release always applies ITS OWN
# order, not whatever the router saw last time.
cp "$MANIFEST" "$OUT/deploy-manifest.json"

"$ENGINE_ROOT/scripts/render.sh" --check "$OUT"
