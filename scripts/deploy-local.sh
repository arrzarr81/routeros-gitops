#!/usr/bin/env bash
# =============================================================================
# deploy-local.sh — push config to a router over the LAN, via SSH.
#
# THIS IS FOR INITIAL PROVISIONING ONLY.
#
# Once the router has script_SELF_UPDATE installed, a GitHub Release IS the
# deploy mechanism, and you should use it even when you are sitting next to the
# device. A live push here will be silently REVERTED within the hour when the
# pull agent re-imports the manifest from the last release. It also bypasses
# the pre-deploy snapshot, the watchdog and the release/rollback trail.
#
# Being on the LAN is convenience, not licence. See docs/04-operations.md.
#
# LEGITIMATE USES
#   * first provisioning of a brand-new router, before it can pull
#   * recovery after a factory reset, when there is no pull agent to recover
#   * a deliberate throwaway probe to confirm a diagnosis — then ship a release
#
# USAGE
#   ./scripts/deploy-local.sh                       # apply the full manifest
#   ./scripts/deploy-local.sh engine/02-watchdog.rsc  # one file
#   ./scripts/deploy-local.sh --ip 192.168.88.1     # override target
#   ./scripts/deploy-local.sh --dry-run             # render only, upload nothing
#
# Credentials come from scripts/.env (gitignored). Copy .env.example to .env.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

ROUTER_IP="${ROUTER_IP:-10.1.1.1}"
ROUTER_PORT="${ROUTER_PORT:-2222}"
ROUTER_USER="${ROUTER_USER:-ci-deploy}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/routeros-gitops}"
DRY_RUN=0

TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)      ROUTER_IP="$2"; shift 2 ;;
        --port)    ROUTER_PORT="$2"; shift 2 ;;
        --user)    ROUTER_USER="$2"; shift 2 ;;
        --key)     SSH_KEY="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *)         TARGETS+=("$1"); shift ;;
    esac
done

# --- Load credentials --------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
    set -a; . "$ENV_FILE"; set +a
else
    echo "WARNING: $ENV_FILE not found — required secrets must already be exported." >&2
fi

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)" >&2; exit 1; }

# --- Work out what to send ---------------------------------------------------
# The manifest is the source of truth, exactly as it is for CI and for the
# router. Never maintain a second ordered list here — that is how the local
# path and the remote path drift apart.
MANIFEST="$REPO_ROOT/deploy-manifest.json"
if [[ ${#TARGETS[@]-0} -eq 0 ]]; then
    while IFS= read -r p; do TARGETS+=("$p"); done < <(jq -r '.[].path' "$MANIFEST")
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Target : $ROUTER_USER@$ROUTER_IP:$ROUTER_PORT"
echo "Files  : ${#TARGETS[@]}"
echo ""

SFTP_BATCH=""
IMPORT_CMDS=()

for path in ${TARGETS[@]+"${TARGETS[@]}"}; do
    entry=$(jq -c --arg p "$path" '.[] | select(.path == $p)' "$MANIFEST")
    if [[ -z "$entry" ]]; then
        echo "ERROR: $path is not in deploy-manifest.json — add it there first." >&2
        exit 1
    fi
    action=$(echo "$entry" | jq -r '.action')
    dst=$(echo "$entry" | jq -r '.dst')

    "$REPO_ROOT/scripts/render.sh" "$REPO_ROOT/$path" "$WORK_DIR/$dst"
    echo "  rendered $path -> $dst  ($action)"

    SFTP_BATCH+=$'\n'"-mkdir $(dirname "$dst")"
    SFTP_BATCH+=$'\n'"put $WORK_DIR/$dst $dst"
    [[ "$action" == "import" ]] && IMPORT_CMDS+=("/import verbose=yes file-name=$dst")
done

# Nothing leaves this machine unrendered, and --check runs before upload so a
# missing secret fails here instead of on the router.
"$REPO_ROOT/scripts/render.sh" --check "$WORK_DIR"

if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "Dry run — rendered files left in: $WORK_DIR"
    trap - EXIT
    exit 0
fi

[[ -f "$SSH_KEY" ]] || { echo "ERROR: SSH key not found at $SSH_KEY" >&2; exit 1; }

echo ""
echo "=== Uploading via SFTP ==="
echo "$SFTP_BATCH" | sftp -P "$ROUTER_PORT" -i "$SSH_KEY" -b - "$ROUTER_USER@$ROUTER_IP"

echo ""
echo "=== Importing on router ==="
# One SSH invocation, chained. If the session drops mid-chain the import aborts
# part-way — for a long apply prefer a one-shot scheduler on the device
# (docs/04-operations.md). This is acceptable here because provisioning is
# supervised and you can watch the output.
IMPORT_CHAIN=$(IFS='; '; echo "${IMPORT_CMDS[*]-}")
ssh -p "$ROUTER_PORT" -i "$SSH_KEY" "$ROUTER_USER@$ROUTER_IP" "$IMPORT_CHAIN"

echo ""
echo "Done."
echo ""
echo "NEXT: seed the version marker so the first hourly pull is a clean no-op:"
echo "  ssh -p $ROUTER_PORT -i $SSH_KEY $ROUTER_USER@$ROUTER_IP \\"
echo "    '/file add name=flash/deployed-version type=file contents=<current-release-tag>'"
echo "If you skip this, the first pull simply re-applies the latest release once."
