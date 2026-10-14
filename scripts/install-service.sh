#!/usr/bin/env bash
# install-service.sh - install a systemd user unit for the model server.
#
# The unit is written but deliberately NOT enabled and NOT started. A model
# server holds VRAM and CPU for as long as it runs, so starting it is always an
# explicit decision, never a side effect of installation.
#
# Usage:
#   ./scripts/install-service.sh             write the unit, leave it disabled
#   ./scripts/install-service.sh --dry-run   print the unit, change nothing
#   ./scripts/install-service.sh --enable    write it and enable at login (asks first)
#   ./scripts/install-service.sh --uninstall remove the unit
#   ./scripts/install-service.sh --status    show current state
#
# After installing, start it when you actually want it:
#   systemctl --user start kiln
#   systemctl --user stop  kiln
#
# The KV cache type in use is baked in at install time from KILN_KV_TYPE
# (default q8_0). Re-run this script after changing it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

UNIT_NAME="kiln.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"

MODE="install"
for arg in "$@"; do
    case "$arg" in
        --dry-run)   MODE="dry-run" ;;
        --enable)    MODE="enable" ;;
        --uninstall) MODE="uninstall" ;;
        --status)    MODE="status" ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "Unknown option: $arg" ;;
    esac
done

have_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

case "$MODE" in
    status)
        have_systemd || die "systemd is not available on this system."
        printf 'unit file : %s\n' "$([ -f "$UNIT_PATH" ] && echo present || echo missing)"
        printf 'enabled   : %s\n' "$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || echo no)"
        printf 'active    : %s\n' "$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || echo inactive)"
        exit 0
        ;;

    uninstall)
        have_systemd || die "systemd is not available on this system."
        systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
        systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
        rm -f "$UNIT_PATH"
        systemctl --user daemon-reload 2>/dev/null || true
        info "Removed $UNIT_NAME"
        exit 0
        ;;
esac

have_systemd || die "systemd is not available. Use ./scripts/start-server.sh instead."

# Load any existing settings FIRST. Without this the file is rewritten from
# defaults, silently discarding whatever the user set with `kiln set`.
load_settings

if detect_is_stale; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

# The unit runs start-server.sh, which resolves the binary itself; this is
# just a check that one exists before writing a unit that would fail.
llama_server_bin >/dev/null || die "No llama-server installed. Run: ./scripts/fetch-binary.sh"
[ -d "$MODELS_DIR" ] || die "Models directory missing: $MODELS_DIR"

# ---------------------------------------------------------------------------
# Build the unit
# ---------------------------------------------------------------------------

# Validate the settings before writing them out.
KV_TYPE_K="$(kv_type_k)"
KV_TYPE_V="$(kv_type_v)"
for _t in "$KV_TYPE_K" "$KV_TYPE_V"; do
    [ "$_t" = "auto" ] && continue   # resolved at start time
    kv_type_valid "$_t" || die "Unknown KV cache type '$_t'. Allowed: auto, $KV_CACHE_TYPES"
done

# All settings live in one editable file. The unit reads it through
# EnvironmentFile, so changing a value is an edit plus a restart rather than a
# reinstall, and the interactive launcher reads the same file.
mkdir -p "$STATE_DIR"
SETTINGS_TMP="$SETTINGS_FILE.tmp"
{
    printf '# Settings for the local Bonsai server.\n'
    printf '# Edit a value and restart: ./scripts/kiln restart\n'
    printf '# Or from the CLI:          ./scripts/kiln set CTX 32768\n'
    printf '#\n'
    printf '# A value exported in the shell still wins over this file.\n'
    printf '\n'
    printf 'KILN_PORT=%s\n' "$KILN_PORT"
    printf 'KILN_CTX=%s\n' "$KILN_CTX"
    printf 'KILN_NGL=%s\n' "$KILN_NGL"
    printf 'KILN_KV_TYPE=%s\n' "${KILN_KV_TYPE:-auto}"
    printf 'KILN_MODELS_DIR=%s\n' "$MODELS_DIR"
    [ -n "${KILN_DRAFT_MODEL:-}" ] &&
        printf 'KILN_DRAFT_MODEL=%s\n' "$KILN_DRAFT_MODEL"
    [ -n "${KILN_SPEC_TYPE:-}" ] &&
        printf 'KILN_SPEC_TYPE=%s\n' "$KILN_SPEC_TYPE"
} > "$SETTINGS_TMP"
mv "$SETTINGS_TMP" "$SETTINGS_FILE"

ENV_LINES=""
case "$BACKEND" in
    rocm)
        [ -n "$ROCM_PREFIX" ] &&
            ENV_LINES="Environment=PATH=$ROCM_PREFIX/bin:$ROCM_PREFIX/lib/llvm/bin:/usr/bin:/bin"
        if [ "${GFX_SUPPORTED:-1}" = "0" ] && [ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]; then
            ENV_LINES="$ENV_LINES
Environment=HSA_OVERRIDE_GFX_VERSION=$HSA_OVERRIDE_GFX_VERSION"
        fi
        ;;
    cuda) ENV_LINES="Environment=CUDA_VISIBLE_DEVICES=0" ;;
esac

# The unit is deliberately thin: it runs the same launcher you would run by
# hand, so there is no second copy of the flag logic to drift.
UNIT_CONTENT="# Generated by scripts/install-service.sh for this machine.
# Backend: $BACKEND ($BACKEND_REASON)
# Settings: $SETTINGS_FILE
# This unit is intentionally NOT enabled by the installer.
[Unit]
Description=Kiln local model server (llama.cpp router, $BACKEND)
After=network.target

[Service]
Type=simple
${ENV_LINES}
EnvironmentFile=-$SETTINGS_FILE
ExecStart=$SCRIPT_DIR/start-server.sh --no-browser
Restart=on-failure
RestartSec=5
# A 27B model can take a while to load on first request.
TimeoutStartSec=300

[Install]
WantedBy=default.target"

if [ "$MODE" = "dry-run" ]; then
    step "Dry run - unit that would be written to $UNIT_PATH"
    printf '%s\n' "$UNIT_CONTENT"
    echo ""
    dim "Nothing was written."
    exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

mkdir -p "$UNIT_DIR"
if [ -f "$UNIT_PATH" ]; then
    cp -p "$UNIT_PATH" "$UNIT_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    info "Backed up the existing unit."
fi

printf '%s\n' "$UNIT_CONTENT" > "$UNIT_PATH"
systemctl --user daemon-reload

info "Wrote $UNIT_PATH"
info "Settings: $SETTINGS_FILE"
info "KV cache: $(kv_type_effective)"
info "State: $(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || echo disabled)"
echo ""

if [ "$MODE" = "enable" ]; then
    warn "Enabling makes the server start automatically at login and hold VRAM."
    if confirm "Enable $UNIT_NAME at login?" n; then
        systemctl --user enable "$UNIT_NAME"
        info "Enabled."
        echo ""
        info "Start it now:  systemctl --user start $UNIT_NAME"
    else
        info "Left disabled."
    fi
else
    dim "Not enabled and not started, by design. To use it:"
    echo "  ./scripts/kiln start      # start now"
    echo "  ./scripts/kiln stop"
    echo "  ./scripts/kiln status"
    echo ""
    dim "  Or with systemd directly: systemctl --user start $UNIT_NAME"
fi
