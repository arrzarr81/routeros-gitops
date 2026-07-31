#!/usr/bin/env bash
# =============================================================================
# render.sh — substitute PLACEHOLDER_* tokens in a .rsc file using secrets.map.
#
# The ONE substitution engine. CI and local deploy both call this, so they can
# never disagree about which placeholders exist.
#
# USAGE
#   scripts/render.sh <src> <dst>      render one file
#   scripts/render.sh --check <dir>    fail if any REQUIRED placeholder survives
#   scripts/render.sh --list           print the placeholder table
#
# Values come from the environment (see secrets.map column 2). Locally those
# are exported by scripts/.env; in CI they come from the workflow's env: block.
#
# IMPLEMENTATION NOTES
#   * sed delimiter is \x01, not / or |, because tokens and URLs contain both.
#   * replacement values are escaped for \ and & — sed treats & as "the whole
#     match" and would silently corrupt any secret containing one.
#   * a value containing a newline is rejected rather than mangled.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="$REPO_ROOT/secrets.map"
SEP=$'\001'

[[ -f "$MAP" ]] || { echo "render.sh: secrets.map not found at $MAP" >&2; exit 1; }

# Emits: placeholder<TAB>envvar<TAB>required
read_map() {
    grep -vE '^[[:space:]]*(#|$)' "$MAP" | awk '{ printf "%s\t%s\t%s\n", $1, $2, $3 }'
}

cmd_list() {
    printf '%-30s %-26s %s\n' PLACEHOLDER ENV_VAR REQUIRED
    read_map | while IFS=$'\t' read -r ph env req; do
        printf '%-30s %-26s %s\n' "$ph" "$env" "$req"
    done
}

cmd_render() {
    local src="$1" dst="$2"
    [[ -f "$src" ]] || { echo "render.sh: source not found: $src" >&2; exit 1; }

    local -a sed_args=()
    local missing=""
    while IFS=$'\t' read -r ph env req; do
        # Indirect lookup. `eval` (not ${!x}) for bash 3.2 compatibility — macOS
        # still ships 3.2 as /bin/bash. Name is validated first so this is safe.
        [[ "$env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            echo "render.sh: invalid env var name in secrets.map: $env" >&2; exit 1; }
        local val=""
        eval "val=\${$env-}"
        if [[ -z "$val" ]]; then
            if [[ "$req" == "yes" ]]; then
                missing="$missing $env"
            fi
            continue          # optional + unset: leave the literal placeholder
        fi
        if [[ "$val" == *$'\n'* ]]; then
            echo "render.sh: $env contains a newline; not supported" >&2
            exit 1
        fi
        # escape backslash and ampersand for the sed REPLACEMENT side
        local esc
        esc=$(printf '%s' "$val" | sed -e 's/[\\&]/\\&/g')
        # `/^[[:space:]]*#/!` — skip comment lines. Every .rsc here documents
        # its own placeholders in the header; without this, a rendered asset has
        # the secret pasted into its comments and the docs become unreadable.
        sed_args+=(-e "/^[[:space:]]*#/!s${SEP}${ph}${SEP}${esc}${SEP}g")
    done < <(read_map)

    if [[ -n "$missing" ]]; then
        echo "render.sh: required secret(s) not set:$missing" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$dst")"
    # Guarded expansion: an empty array under `set -u` is an error on bash 3.2.
    if [[ ${#sed_args[@]-0} -eq 0 ]]; then
        cp "$src" "$dst"
    else
        sed ${sed_args[@]+"${sed_args[@]}"} "$src" > "$dst"
    fi
}

# Safety net: no REQUIRED placeholder may survive into a shipped artifact.
# Optional ones are allowed through by design — the .rsc scripts detect the
# "PLACEHOLDER_" prefix at runtime and disable that feature.
cmd_check() {
    local dir="$1"
    local pattern=""
    while IFS=$'\t' read -r ph env req; do
        [[ "$req" == "yes" ]] || continue
        pattern="${pattern:+$pattern|}$ph"
    done < <(read_map)

    [[ -n "$pattern" ]] || return 0

    # Comment lines are excluded on purpose: render.sh does not substitute in
    # them, so a placeholder NAME appearing in a header is documentation, not a
    # missing secret. Only live config lines are a failure.
    local found=0 f hits
    while IFS= read -r f; do
        hits=$(grep -nE "$pattern" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
        if [[ -n "$hits" ]]; then
            found=1
            echo "$hits" | sed "s|^|$f:|"
        fi
    done < <(find "$dir" -type f)

    if [[ $found -eq 1 ]]; then
        echo "render.sh: a REQUIRED placeholder survived into $dir (secret missing?)" >&2
        exit 1
    fi
    echo "render.sh: check passed — no required placeholder left in $dir"
}

case "${1-}" in
    --list)  cmd_list ;;
    --check) cmd_check "${2:?usage: render.sh --check <dir>}" ;;
    "")      echo "usage: render.sh <src> <dst> | --check <dir> | --list" >&2; exit 1 ;;
    *)       cmd_render "${1}" "${2:?usage: render.sh <src> <dst>}" ;;
esac
