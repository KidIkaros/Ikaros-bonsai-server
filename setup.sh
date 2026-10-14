#!/usr/bin/env bash
# setup.sh - get a local Kiln model server running on this machine.
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
#   KILN_MODELS_DIR=/path        where models are stored

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
printf '  %s\n' "Kiln setup"
printf '  %s\n' "------------"

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
# 4. Teach the local Hermes agent (best-effort, never fatal)
# ---------------------------------------------------------------------------
# Same shared script install.sh uses, so both install routes lay down the
# identical skill from one implementation. Silent unless it succeeds.
KILN_SKILL_VERBOSE=1 "$SCRIPT_DIR/scripts/install-hermes-skill.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Finish the job: start the server and register it with Hermes
# ---------------------------------------------------------------------------
# Onboarding should END in a working stack, not a list of manual steps. When a
# model is present, start the server and register it as a Hermes provider (the
# user still picks it in `hermes model` - we never force it active). Skipped
# under --no-models (nothing to serve) and --detect-only (report and stop).
_do_launch=1
[ "$SKIP_MODELS" = 1 ] && _do_launch=0
[ "$DETECT_ONLY" = 1 ] && _do_launch=0

if [ "$_do_launch" = 1 ]; then
    _gguf_count="$(find "${KILN_MODELS_DIR:-$HOME/models/kiln-server}" -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$_gguf_count" -gt 0 ]; then
        step "Starting the server"
        if "$SCRIPT_DIR/scripts/start-server.sh" --background --no-browser >/dev/null 2>&1; then
            info "Server is up on http://localhost:$KILN_PORT"
            if command -v hermes >/dev/null 2>&1; then
                "$SCRIPT_DIR/scripts/hermes-wire.sh" >/dev/null 2>&1 || true
                info "Registered with Hermes."
            fi
        else
            warn "Server did not start cleanly. Start it with: ./scripts/start-server.sh"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 6. What next
# ---------------------------------------------------------------------------

echo ""
printf '  %s\n' "=============================================="
printf '  %s\n' "  Ready"
printf '  %s\n' "=============================================="
echo ""
if [ "$_do_launch" = 1 ] && [ "${_gguf_count:-0}" -gt 0 ]; then
    printf '  Kiln is live. Use it in Hermes:\n'
    printf '    %shermes model%s   -> pick the Kiln provider\n\n' "$C_CYAN" "$C_RESET"
    printf '  Or any time later, one command brings it all back up:\n'
    printf '    %skiln up%s\n\n' "$C_CYAN" "$C_RESET"
else
    printf '  Start the server when ready:\n'
    printf '    %skiln up%s   (model + start + wire Hermes, one command)\n\n' "$C_CYAN" "$C_RESET"
fi
printf '  Optional: run it as a user service (installed disabled, start it yourself)\n'
printf '    %s./scripts/install-service.sh%s\n\n' "$C_CYAN" "$C_RESET"
printf '  Manage it: %skiln status%s  %skiln stop%s  %skiln dash%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
printf '  Web UI and OpenAI-compatible API: %shttp://localhost:%s%s\n' "$C_CYAN" "$KILN_PORT" "$C_RESET"
echo ""
dim "  Docs: README.md, docs/MODELS.md, docs/HARDWARE.md, docs/HERMES.md"
echo ""
