#!/usr/bin/env bash
# hermes-wire.sh - register this local server as a Hermes provider.
#
# Writes to the Hermes config through the `hermes` CLI. Because that file is a
# live user config, this script always takes a timestamped backup first, and
# `--dry-run` prints exactly what it would change without touching anything.
#
# Usage:
#   ./scripts/hermes-wire.sh --dry-run          show the commands, change nothing
#   ./scripts/hermes-wire.sh                    write the provider
#   ./scripts/hermes-wire.sh --model <id>       pick a specific model id
#   ./scripts/hermes-wire.sh --make-default     also set model.provider/model.default
#   ./scripts/hermes-wire.sh --name "My Bonsai" display name for the provider
#
# The model id is the router's extension-less name, e.g.
#   prism-ml_Ternary-Bonsai-2-27B-gguf__Ternary-Bonsai-2-27B-PQ2_0
# It is read from the running server unless --model is given.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=0
MAKE_DEFAULT=0
MODEL=""
PROV_NAME="Kiln (local)"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1 ;;
        --make-default) MAKE_DEFAULT=1 ;;
        --model)        MODEL="${2:-}"; shift ;;
        --name)         PROV_NAME="${2:-}"; shift ;;
        -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "Unknown option: $1" ;;
    esac
    shift
done

command -v hermes >/dev/null 2>&1 || die "The 'hermes' CLI is not on PATH. Install Hermes first."

PROVIDER="local-127.0.0.1:$KILN_PORT"
BASE_URL="http://127.0.0.1:$KILN_PORT"

# Hermes parses config keys on dots, and this provider id contains dots. Each
# dot in the id must be backslash-escaped or `hermes config set` refuses it.
PROVIDER_KEY="$(printf '%s' "$PROVIDER" | sed 's/\./\\./g')"

# ---------------------------------------------------------------------------
# Resolve the model id from the running server
# ---------------------------------------------------------------------------

if [ -z "$MODEL" ]; then
    step "Looking for a running server on port $KILN_PORT"
    _resp=""
    if command -v curl >/dev/null 2>&1; then
        _resp="$(curl -sf --max-time 5 "$BASE_URL/v1/models" 2>/dev/null || true)"
    fi

    if [ -z "$_resp" ]; then
        err "No server responding at $BASE_URL."
        echo "  Start it first:  ./scripts/start-server.sh"
        echo "  Or name a model: ./scripts/hermes-wire.sh --model <id>"
        exit 1
    fi

    _models="$(printf '%s' "$_resp" | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    [ -n "$_models" ] || die "Server responded but reported no models."

    echo "" >&2
    echo "  Available models:" >&2
    _n=0
    while IFS= read -r _m; do
        [ -n "$_m" ] || continue
        _n=$((_n + 1))
        printf '    %2d. %s\n' "$_n" "$_m" >&2
    done <<EOF
$_models
EOF
    echo "" >&2

    if [ "$_n" -eq 1 ]; then
        MODEL="$(printf '%s' "$_models" | head -1)"
        info "Using the only available model."
    else
        _pick="$(ask "Model number to register" "1")"
        case "$_pick" in ''|*[!0-9]*) die "Expected a number, got '$_pick'." ;; esac
        MODEL="$(printf '%s' "$_models" | sed -n "${_pick}p")"
        [ -n "$MODEL" ] || die "No model for selection '$_pick'."
    fi
fi

info "Provider : $PROVIDER"
info "Name     : $PROV_NAME"
info "Base URL : $BASE_URL"
info "Model    : $MODEL"
echo ""

# ---------------------------------------------------------------------------
# Writes
# ---------------------------------------------------------------------------

# run_set KEY VALUE - apply one setting, or print it in dry-run mode.
run_set() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  hermes config set --force "%s" "%s"\n' "$1" "$2"
        return 0
    fi
    if hermes config set --force "$1" "$2" >/dev/null 2>&1; then
        printf '  %s %s\n' "${C_GREEN}ok${C_RESET}" "$1"
    else
        err "Failed to set $1"
        return 1
    fi
}

if [ "$DRY_RUN" = 1 ]; then
    step "Dry run - these commands would run"
    run_set "providers.$PROVIDER_KEY.api" "$BASE_URL"
    run_set "providers.$PROVIDER_KEY.name" "$PROV_NAME"
    run_set "providers.$PROVIDER_KEY.default_model" "$MODEL"
    if [ "$MAKE_DEFAULT" = 1 ]; then
        run_set "model.provider" "$PROVIDER"
        run_set "model.default" "$MODEL"
    fi
    echo ""
    dim "Nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Back up, then write
# ---------------------------------------------------------------------------

CONFIG_PATH="$(hermes config path 2>/dev/null | tail -1)"
BACKUP=""
if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    BACKUP="$CONFIG_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONFIG_PATH" "$BACKUP"
    info "Backed up config to $BACKUP"
else
    warn "Could not locate the Hermes config file; skipping the backup."
    CONFIG_PATH=""
fi

step "Writing provider"
run_set "providers.$PROVIDER_KEY.api" "$BASE_URL"
run_set "providers.$PROVIDER_KEY.name" "$PROV_NAME"
run_set "providers.$PROVIDER_KEY.default_model" "$MODEL"
if [ "$MAKE_DEFAULT" = 1 ]; then
    run_set "model.provider" "$PROVIDER"
    run_set "model.default" "$MODEL"
fi

step "Verifying"
_provider_json="$(hermes config get "providers.$PROVIDER_KEY" --json 2>/dev/null || true)"
if printf '%s' "$_provider_json" | grep -q "$MODEL"; then
    info "Provider registered and readable."
else
    warn "Could not read the provider back. Check with:"
    dim "  hermes config get \"providers.$PROVIDER_KEY\""
fi

echo ""
info "Done. In Hermes, select the '$PROV_NAME' provider."
if [ -n "$BACKUP" ]; then
    dim "  Undo: cp \"$BACKUP\" \"$CONFIG_PATH\""
fi
