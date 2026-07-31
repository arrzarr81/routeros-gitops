#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-time provisioning of a router + this repo's GitHub secrets.
#
# WHAT IT DOES
#   1. Generates a dedicated SSH keypair (ed25519) if you don't have one.
#   2. Creates a `ci-deploy` user on the router, installs the public key,
#      and moves SSH to port 2222.
#   3. Pushes the values in scripts/.env into GitHub Actions secrets.
#   4. Prints the exact next steps.
#
# It talks to the router over the LAN with the ADMIN account, once. After this,
# nothing on your machine needs router access again — deploys are pull-based.
#
# PREREQUISITES
#   * router reachable on the LAN (factory default is 192.168.88.1)
#   * `gh` authenticated:  gh auth login
#   * scripts/.env filled in (copy from .env.example)
#
# USAGE
#   ./scripts/bootstrap.sh --ip 192.168.88.1 --admin admin
#   ./scripts/bootstrap.sh --secrets-only     # skip the router, just set secrets
#   ./scripts/bootstrap.sh --router-only      # skip GitHub, just provision
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

ROUTER_IP="192.168.88.1"
ADMIN_USER="admin"
ADMIN_PORT="22"
SSH_KEY="$HOME/.ssh/routeros-gitops"
DO_ROUTER=1
DO_SECRETS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)           ROUTER_IP="$2"; shift 2 ;;
        --admin)        ADMIN_USER="$2"; shift 2 ;;
        --port)         ADMIN_PORT="$2"; shift 2 ;;
        --key)          SSH_KEY="$2"; shift 2 ;;
        --secrets-only) DO_ROUTER=0; shift ;;
        --router-only)  DO_SECRETS=0; shift ;;
        -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Step 1: SSH key ---------------------------------------------------------
if [[ ! -f "$SSH_KEY" ]]; then
    echo "==> Generating deploy key at $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "routeros-gitops"
else
    echo "==> Reusing existing key $SSH_KEY"
fi
PUBKEY_FILE="${SSH_KEY}.pub"

# --- Step 2: provision the router -------------------------------------------
if [[ $DO_ROUTER -eq 1 ]]; then
    echo ""
    echo "==> Provisioning router at $ADMIN_USER@$ROUTER_IP:$ADMIN_PORT"
    echo "    (you will be prompted for the admin password)"

    # Upload the public key, then bind it to a purpose-made user. RouterOS
    # imports SSH keys per-user and the file must already be on the device.
    scp -P "$ADMIN_PORT" "$PUBKEY_FILE" "$ADMIN_USER@$ROUTER_IP:gitops-key.pub"

    # A random password is set because RouterOS requires one; it is never used
    # (the key is the only credential) and is not stored anywhere.
    RANDPW=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)

    ssh -p "$ADMIN_PORT" "$ADMIN_USER@$ROUTER_IP" \
      "/user group add name=gitops policy=ssh,ftp,read,write,policy,test,password,sensitive,reboot comment=\"routeros-gitops deploy\" ; \
       /user remove [find name=ci-deploy] ; \
       /user add name=ci-deploy group=gitops password=\"$RANDPW\" comment=\"routeros-gitops\" ; \
       /user ssh-keys import public-key-file=gitops-key.pub user=ci-deploy ; \
       /file remove [find name=gitops-key.pub] ; \
       /ip service set ssh port=2222 ; \
       /ip service disable [find name=telnet] ; \
       /ip service disable [find name=ftp] ; \
       /ip service disable [find name=api] ; \
       /ip service disable [find name=api-ssl] ; \
       :put \"provisioned\""

    echo ""
    echo "==> Router provisioned. SSH is now on port 2222 as ci-deploy (key only)."
    echo "    Verify:  ssh -p 2222 -i $SSH_KEY ci-deploy@$ROUTER_IP '/system identity print'"
fi

# --- Step 3: GitHub secrets --------------------------------------------------
if [[ $DO_SECRETS -eq 1 ]]; then
    echo ""
    echo "==> Setting GitHub Actions secrets from $ENV_FILE"
    [[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found (copy .env.example)" >&2; exit 1; }
    command -v gh >/dev/null || { echo "ERROR: gh CLI not found" >&2; exit 1; }

    # Refuse to arm a public repo — release assets carry cleartext secrets.
    VIS=$(gh repo view --json visibility -q .visibility)
    if [[ "$VIS" != "PRIVATE" && "$VIS" != "INTERNAL" ]]; then
        echo "ERROR: this repository is $VIS." >&2
        echo "       Release assets are rendered with real secrets. Make it private first:" >&2
        echo "         gh repo edit --visibility private --accept-visibility-change-consequences" >&2
        exit 1
    fi

    set -a; . "$ENV_FILE"; set +a

    # Only the env vars named in secrets.map are pushed, and GITOPS_GITHUB_REPO
    # is skipped: the workflow derives it from ${{ github.repository }}.
    while read -r ph env req _; do
        case "$ph" in ''|'#'*) continue ;; esac
        [[ "$env" == "GITOPS_GITHUB_REPO" ]] && continue
        eval "val=\${$env-}"
        if [[ -z "${val:-}" ]]; then
            if [[ "$req" == "yes" ]]; then
                echo "  ERROR: required secret $env is empty in .env" >&2; exit 1
            fi
            echo "  skip $env (optional, not set)"
            continue
        fi
        printf '%s' "$val" | gh secret set "$env"
        echo "  set  $env"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/secrets.map")
fi

cat <<EOF

=============================================================================
NEXT STEPS

1. Review config/10-network.rsc and adapt it to this site (interfaces, subnets,
   identity). It is an EXAMPLE — deploying it unchanged will renumber the LAN.

2. Provision the router over the LAN, once:
     ./scripts/deploy-local.sh --ip <router-ip>

3. Confirm the pull agent is armed:
     ssh -p 2222 -i $SSH_KEY ci-deploy@<router-ip> \\
       '/system scheduler print where name="schedule_SELF_UPDATE"'

4. From now on, deploy by publishing a Release:
     git commit && git push
     gh release create v1 --generate-notes

   The router applies it within the hour, entirely on its own.
=============================================================================
EOF
