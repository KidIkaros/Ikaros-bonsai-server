#!/usr/bin/env bash
# start-server.sh - run the llama.cpp router server that Hermes talks to.
#
# Router mode means no model is pinned at startup: llama-server scans the models
# directory and loads one on demand, so models can be swapped without a restart.
#
# Usage:
#   ./scripts/start-server.sh              start on the detected backend
#   ./scripts/start-server.sh --no-browser don't open the Web UI
#   ./scripts/start-server.sh --background run detached, log to .state/server.log
#
# Overrides:
#   BONSAI_PORT=8081        listening port
#   BONSAI_CTX=65536        context size (Hermes needs >= 64000)
#   BONSAI_NGL=99           GPU layers, 0 for CPU-only
#   BONSAI_MODELS_DIR=path  models directory
#   BONSAI_EXTRA_ARGS="..." extra llama-server flags

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

OPEN_BROWSER=1
BACKGROUND=0
for arg in "$@"; do
    case "$arg" in
        --no-browser) OPEN_BROWSER=0 ;;
        --background) BACKGROUND=1 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

if detect_is_stale; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

SERVER_BIN="$(llama_server_bin)" || die "No llama-server installed for backend '$BACKEND'.
       Run: ./scripts/fetch-binary.sh"

[ -d "$MODELS_DIR" ] || die "Models directory does not exist: $MODELS_DIR
       Run: ./scripts/get-models.sh"

# Refuse to start with nothing to serve - a silent empty router is confusing.
_gguf_count="$(find "$MODELS_DIR" -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')"
[ "$_gguf_count" -gt 0 ] || die "No .gguf files in $MODELS_DIR
       Run: ./scripts/get-models.sh"

# Refuse to start when the port is already taken, rather than failing obscurely.
if command -v lsof >/dev/null 2>&1; then
    _busy="$(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null || true)"
    if [ -n "$_busy" ]; then
        die "Port $BONSAI_PORT is already in use (pid $_busy).
       Stop it first: ./scripts/stop-server.sh"
    fi
fi

# Hermes requires a context window of at least 64000 tokens.
if [ "$BONSAI_CTX" -lt 64000 ] 2>/dev/null; then
    warn "BONSAI_CTX=$BONSAI_CTX is below 64000; Hermes requires at least that."
fi

# ROCm runtime override is only ever applied when detection found a gfx target
# the prebuilt does not cover, and only when the user has supplied a value.
if [ "$BACKEND" = "rocm" ] && [ "${GFX_SUPPORTED:-1}" = "0" ]; then
    if [ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]; then
        export HSA_OVERRIDE_GFX_VERSION
        info "Applying HSA_OVERRIDE_GFX_VERSION=$HSA_OVERRIDE_GFX_VERSION"
    else
        warn "gfx $ROCM_GFX may not be covered by this prebuilt and no override is set."
        warn "If the model fails to load, set HSA_OVERRIDE_GFX_VERSION to a supported gfx."
    fi
fi

# Only pass --n-gpu-layers when there is actually a GPU backend in play.
NGL_ARGS=()
case "$BACKEND" in
    cpu) ;;
    *) NGL_ARGS=(--n-gpu-layers "$BONSAI_NGL") ;;
esac

# shellcheck disable=SC2206
EXTRA_ARGS=(${BONSAI_EXTRA_ARGS:-})

CMD=(
    "$SERVER_BIN"
    --models-dir "$MODELS_DIR"
    --models-max 1
    --host 0.0.0.0
    --port "$BONSAI_PORT"
    --ctx-size "$BONSAI_CTX"
    --threads "$(nproc 2>/dev/null || echo 4)"
    --flash-attn on
    --no-warmup
    --jinja
    "${NGL_ARGS[@]}"
    "${EXTRA_ARGS[@]}"
)

step "Starting llama-server"
printf '  %s\n' "${C_DIM}${CMD[*]}${C_RESET}"
echo ""
info "Backend     : $BACKEND"
info "Models dir  : $MODELS_DIR  ($_gguf_count file(s))"
info "Web UI      : http://localhost:$BONSAI_PORT"
info "OpenAI API  : http://localhost:$BONSAI_PORT/v1"
echo ""

if [ "$OPEN_BROWSER" = 1 ]; then
    (
        for _ in $(seq 1 60); do
            if command -v curl >/dev/null 2>&1; then
                curl -sf "http://127.0.0.1:$BONSAI_PORT/health" >/dev/null 2>&1 && break
            fi
            sleep 1
        done
        _url="http://localhost:$BONSAI_PORT"
        if   command -v xdg-open >/dev/null 2>&1; then xdg-open "$_url" >/dev/null 2>&1
        elif command -v open     >/dev/null 2>&1; then open "$_url" >/dev/null 2>&1
        fi
    ) &
fi

if [ "$BACKGROUND" = 1 ]; then
    mkdir -p "$STATE_DIR"
    LOG="$STATE_DIR/server.log"
    nohup "${CMD[@]}" >"$LOG" 2>&1 &
    _pid=$!
    printf '%s' "$_pid" > "$STATE_DIR/server.pid"
    info "Started in background (pid $_pid)"
    dim "  log: $LOG"
    dim "  stop: ./scripts/stop-server.sh"
    exit 0
fi

dim "Ctrl+C to stop."
exec "${CMD[@]}"
