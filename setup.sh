#!/usr/bin/env bash
# setup.sh - get a local Bonsai model server running on this machine.
#
# Does four things:
#   1. works out what hardware this is and which backend fits
#   2. downloads the matching prebuilt llama-server
#   3. downloads a model that suits the machine
#   4. tells you the two commands to start it and point Hermes at it
#
# Usage:
#   ./setup.sh                  interactive, recommends a model
#   ./setup.sh --yes            accept the recommendation without asking
#   ./setup.sh --detect-only    report the hardware and stop
#   ./setup.sh --no-models      skip the model download
#
# Overrides:
#   BACKEND=cpu|vulkan|cuda|rocm   force a backend
#   IKAROS_MODELS_DIR=/path        where models are stored

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/scripts/lib/common.sh"

ASSUME_YES=0
DETECT_ONLY=0
SKIP_MODELS=0

for arg in "$@"; do
    case "$arg" in
        --yes|-y)     ASSUME_YES=1 ;;
        --detect-only) DETECT_ONLY=1 ;;
        --no-models)  SKIP_MODELS=1 ;;
        -h|--help)    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "Unknown option: $arg" ;;
    esac
done

printf '\n'
printf '  %s\n' "Ikaros Bonsai server setup"
printf '  %s\n' "--------------------------"

# ---------------------------------------------------------------------------
# 1. Hardware
# ---------------------------------------------------------------------------

"$SCRIPT_DIR/scripts/detect.sh"
load_detect

if [ "$DETECT_ONLY" = 1 ]; then
    echo ""
    info "Detection only. Nothing was downloaded or changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Binary
# ---------------------------------------------------------------------------

"$SCRIPT_DIR/scripts/fetch-binary.sh"

# ---------------------------------------------------------------------------
# 3. Model
# ---------------------------------------------------------------------------

if [ "$SKIP_MODELS" = 1 ]; then
    info "Skipping model download (--no-models)."
else
    _existing="$(find "$MODELS_DIR" -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$_existing" -gt 0 ]; then
        info "Models already present in $MODELS_DIR ($_existing file(s))."
    elif [ "$ASSUME_YES" = 1 ]; then
        "$SCRIPT_DIR/scripts/get-models.sh" --recommend
    else
        # The picker prints the catalog and asks which entry to download.
        "$SCRIPT_DIR/scripts/get-models.sh"
    fi
fi

# ---------------------------------------------------------------------------
# 4. What next
# ---------------------------------------------------------------------------

echo ""
printf '  %s\n' "=============================================="
printf '  %s\n' "  Ready"
printf '  %s\n' "=============================================="
echo ""
printf '  Start the server (leave this running):\n'
printf '    %s./scripts/start-server.sh%s\n\n' "$C_CYAN" "$C_RESET"
printf '  Then, in another terminal, point Hermes at it:\n'
printf '    %s./scripts/hermes-wire.sh --dry-run%s   # see what it would change\n' "$C_CYAN" "$C_RESET"
printf '    %s./scripts/hermes-wire.sh%s             # apply it\n\n' "$C_CYAN" "$C_RESET"
printf '  Optional: run it as a user service (installed disabled, start it yourself)\n'
printf '    %s./scripts/install-service.sh%s\n\n' "$C_CYAN" "$C_RESET"
printf '  Web UI and OpenAI-compatible API: %shttp://localhost:%s%s\n' "$C_CYAN" "$IKAROS_PORT" "$C_RESET"
echo ""
dim "  Docs: README.md, docs/MODELS.md, docs/HARDWARE.md, docs/HERMES.md"
echo ""
