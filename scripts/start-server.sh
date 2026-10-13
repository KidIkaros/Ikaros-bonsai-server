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
#   BONSAI_KV_TYPE=q8_0     KV cache type: q8_0 (default), q4_0, iq4_nl, q5_0,
#                           f16 to disable. See docs/HARDWARE.md.
#   BONSAI_KV_TYPE_K / _V   set K and V independently (advanced)
#   BONSAI_MODELS_DIR=path  models directory
#   BONSAI_EXTRA_ARGS="..." extra llama-server flags

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

OPEN_BROWSER=1
BACKGROUND=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-browser) OPEN_BROWSER=0 ;;
        --background) BACKGROUND=1 ;;
        --kv-type)    export BONSAI_KV_TYPE="${2:-}"; shift ;;
        --kv-type-k)  export BONSAI_KV_TYPE_K="${2:-}"; shift ;;
        --kv-type-v)  export BONSAI_KV_TYPE_V="${2:-}"; shift ;;
        -h|--help)    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done


# Settings come from .state/service.env unless the environment already set them,
# so `bonsai set` and a one-off `BONSAI_CTX=... ./scripts/start-server.sh` both work.
load_settings

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
        _busycmd="$(tr '\0' ' ' < "/proc/$_busy/cmdline" 2>/dev/null | cut -c1-100)"
        err "Port $BONSAI_PORT is already in use (pid $_busy)."
        echo "       $_busycmd" >&2
        echo "" >&2
        echo "       If that is your own service, stop it with systemd. Otherwise pick" >&2
        echo "       another port:" >&2
        echo "         BONSAI_PORT=9000 ./scripts/start-server.sh" >&2
        exit 1
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

# Validate the KV cache types before starting, so a typo fails here with the
# allowed list rather than deep inside llama-server.
KV_TYPE_K="$(kv_type_k)"
KV_TYPE_V="$(kv_type_v)"
for _t in "$KV_TYPE_K" "$KV_TYPE_V"; do
    kv_type_valid "$_t" || die "Unknown KV cache type '$_t'.
       Allowed: $KV_CACHE_TYPES
       Example: BONSAI_KV_TYPE=q8_0 ./scripts/start-server.sh"
done

KV_ARGS=()
if [ "$(kv_type_effective)" != "f16" ]; then
    KV_ARGS=(--cache-type-k "$KV_TYPE_K" --cache-type-v "$KV_TYPE_V")
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
    "${KV_ARGS[@]}"
    "${NGL_ARGS[@]}"
    "${EXTRA_ARGS[@]}"
)

step "Starting llama-server"
printf '  %s\n' "${C_DIM}${CMD[*]}${C_RESET}"
echo ""
info "Backend     : $BACKEND"
info "Models dir  : $MODELS_DIR  ($_gguf_count file(s))"
info "KV cache    : $(kv_type_effective)"
if [ "$KV_TYPE_K" = "q4_0" ] || [ "$KV_TYPE_V" = "q4_0" ]; then
    dim "  q4_0 is the smallest option but costs some quality."
    dim "  --kv-mean-center improves q4_0 K quality; see docs/HARDWARE.md."
fi
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
