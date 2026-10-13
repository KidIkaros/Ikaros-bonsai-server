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
#   BONSAI_DRAFT_MODEL=path a *-dspark-* drafter, for speculative decoding
#   BONSAI_SPEC_TYPE=name   speculative decoding type; draft-mtp uses the MTP
#                           head inside a *-mtp.gguf, no second file needed
#   BONSAI_SPEC_DRAFT_N_MAX tokens to draft (default 1; Vulkan prefers 2,
#                           ROCm prefers 1 on this card - measure both)
#   BONSAI_SPEC_DRAFT_P_MIN draft probability floor (default 0.0 = disabled;
#                           0.8 lets deeper n-max pay off, see RESEARCH-2026-10)
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

# ---------------------------------------------------------------------------
# Pre-flight: refuse to start in states that are known to wedge.
# ---------------------------------------------------------------------------

# Disk guard. A wedged loader writes its spinner to the log without bound -
# one stuck load has been observed writing 1.7 GB. Refusing to start on a
# nearly-full disk keeps that from becoming unrecoverable.
_df_line="$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4, $6}')"
_df_kb="${_df_line%% *}"
if [ -n "$_df_kb" ] && [ "$_df_kb" -lt 5242880 ] 2>/dev/null; then
    die "Less than 5 GB free on ${_df_line#* } ($((_df_kb / 1024)) MB available).
       A stuck model load writes its progress spinner to the log without
       bound, so starting here risks filling the disk. Free space, then retry."
fi

# Stale GPU state. If VRAM is held but no llama-server is running, a previous
# load died mid-transfer (crash, SIGKILL) and the runtime never released it.
# The next load then hangs during compute-graph setup, which looks like a
# silent startup. Detect it here and say how to recover, instead of letting
# the server appear to start and never answer a request.
if [ "$BACKEND" != "cpu" ] && [ -n "${VRAM_GB:-}" ]; then
    _free_vram="$(free_vram_gb 2>/dev/null || true)"
    if [ -n "$_free_vram" ]; then
        _used_vram="$(awk -v t="$VRAM_GB" -v f="$_free_vram" 'BEGIN { u = t - f; printf "%d", (u > 0 ? u : 0) }')"
        if [ "$_used_vram" -gt 2 ] && [ -z "$(pgrep -f '[l]lama-server' 2>/dev/null || true)" ]; then
            warn "VRAM appears held by a dead process (${_used_vram} GB in use, no llama-server running)."
            warn "A previous load was killed mid-transfer; the next load will hang."
            warn "Recover with: pkill -9 llama-server, then retry. Reboot if it persists."
        fi
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
# Resolve "auto" now that detection and the measurements are available.
if [ "$BONSAI_KV_TYPE" = "auto" ]; then
    # Take the reason from the resolver rather than asserting one here: an
    # unmeasured model falls back to q8_0 without ever checking what fits.
    _auto_reason="$(kv_type_auto_reason)"
    _auto_note=1
fi
kv_type_resolve

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

# Speculative decoding. Either a separate drafter via BONSAI_DRAFT_MODEL, or a
# spec type such as draft-mtp, which uses the MTP head already inside the model
# file and needs no second file.
DRAFT_ARGS=()
if [ -n "${BONSAI_DRAFT_MODEL:-}" ]; then
    [ -f "$BONSAI_DRAFT_MODEL" ] ||
        die "Draft model not found: $BONSAI_DRAFT_MODEL
       Set BONSAI_DRAFT_MODEL to a GGUF, or unset it to disable drafting."
    DRAFT_ARGS+=(--model-draft "$BONSAI_DRAFT_MODEL")
fi
if [ -n "${BONSAI_SPEC_TYPE:-}" ]; then
    case "$BONSAI_SPEC_TYPE" in
        none|draft-simple|draft-eagle3|draft-mtp|draft-dflash|draft-dspark|\
        ngram-simple|ngram-map-k|ngram-map-k4v|ngram-mod|ngram-cache) ;;
        *) die "Unknown BONSAI_SPEC_TYPE '$BONSAI_SPEC_TYPE'.
       Allowed: none, draft-simple, draft-eagle3, draft-mtp, draft-dflash,
                draft-dspark, ngram-simple, ngram-map-k, ngram-map-k4v,
                ngram-mod, ngram-cache" ;;
    esac
    if [ "$BONSAI_SPEC_TYPE" != "none" ]; then
        DRAFT_ARGS+=(--spec-type "$BONSAI_SPEC_TYPE"
                     --spec-draft-n-max "$BONSAI_SPEC_DRAFT_N_MAX")
        # The probability floor is only passed when enabled: passing 0.0
        # explicitly is the llama.cpp default, but keeping it off the command
        # line means older builds without the flag still work.
        if [ "${BONSAI_SPEC_DRAFT_P_MIN:-0.0}" != "0.0" ] && [ -n "${BONSAI_SPEC_DRAFT_P_MIN:-}" ]; then
            DRAFT_ARGS+=(--spec-draft-p-min "$BONSAI_SPEC_DRAFT_P_MIN")
        fi
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

# Threads come from the setting (or `bonsai set threads`), falling back to all
# cores. Validated here so a bad value fails with a clear message instead of a
# cryptic llama-server error.
BONSAI_THREADS="${BONSAI_THREADS:-$(nproc 2>/dev/null || echo 4)}"
case "$BONSAI_THREADS" in
    ''|*[!0-9]*) die "BONSAI_THREADS must be a number, got '$BONSAI_THREADS'.\n       Example: ./scripts/bonsai set threads 8" ;;
esac

CMD=(
    "$SERVER_BIN"
    --models-dir "$MODELS_DIR"
    --models-max 1
    --host 0.0.0.0
    --port "$BONSAI_PORT"
    --ctx-size "$BONSAI_CTX"
    --threads "$BONSAI_THREADS"
    --flash-attn on
    --no-warmup
    --jinja
    "${KV_ARGS[@]}"
    "${DRAFT_ARGS[@]}"
    "${NGL_ARGS[@]}"
    "${EXTRA_ARGS[@]}"
)

step "Starting llama-server"
printf '  %s\n' "${C_DIM}${CMD[*]}${C_RESET}"
echo ""
info "Backend     : $BACKEND"
info "Models dir  : $MODELS_DIR  ($_gguf_count file(s))"
if [ -n "${BONSAI_DRAFT_MODEL:-}" ]; then
    info "Draft model : $(basename "$BONSAI_DRAFT_MODEL")  (speculative decoding)"
fi
if [ -n "${BONSAI_SPEC_TYPE:-}" ] && [ "$BONSAI_SPEC_TYPE" != "none" ]; then
    info "Spec decode : $BONSAI_SPEC_TYPE, n-max $BONSAI_SPEC_DRAFT_N_MAX"
fi
if [ -n "${_auto_note:-}" ]; then
    info "KV cache    : $(kv_type_effective)  (auto: $_auto_reason)"
else
    info "KV cache    : $(kv_type_effective)"
fi
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
    # Fresh log per start so the failure tail below is about this attempt.
    : >"$LOG"
    nohup "${CMD[@]}" >>"$LOG" 2>&1 &
    _pid=$!
    printf '%s' "$_pid" > "$STATE_DIR/server.pid"

    # Verify the server actually became healthy before claiming success. A
    # model load can hang indefinitely on a wedged GPU runtime; without this
    # check the caller is told "started" and every request then times out
    # with no explanation. Bounded wait, then a clear failure.
    _health_timeout="${BONSAI_START_TIMEOUT:-120}"
    info "Waiting up to ${_health_timeout}s for the server to become healthy..."
    _ok=0
    _i=0
    while [ "$_i" -lt "$_health_timeout" ]; do
        if ! kill -0 "$_pid" 2>/dev/null; then
            err "llama-server exited during startup (pid $_pid)."
            break
        fi
        if command -v curl >/dev/null 2>&1 &&
           curl -sf --max-time 5 "http://127.0.0.1:$BONSAI_PORT/health" >/dev/null 2>&1; then
            # /health only proves the process is up. In router mode the model
            # load happens per-request, and that is what hangs on a wedged
            # runtime, so verify one real generation too.
            _deep_rc=0
            _deep="$(curl -sf --max-time 90 \
                "http://127.0.0.1:$BONSAI_PORT/v1/chat/completions" \
                -H 'Content-Type: application/json' \
                -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
                2>/dev/null)" || _deep_rc=$?
            if [ "$_deep_rc" = 0 ] && [ -n "$_deep" ]; then
                _ok=1
                break
            fi
            if [ "$_deep_rc" = 28 ]; then
                # curl 28 = operation timeout: the load is wedged, not merely
                # failing. This is the "user grabs a model and it hangs" case.
                err "Model load timed out after 90s. The GPU runtime is likely wedged"
                err "by a previously killed load. Recover with: pkill -9 llama-server,"
                err "then retry; reboot if it persists."
                break
            fi
            # Any other failure (e.g. the first model does not fit VRAM) is a
            # warning, not a start failure: the server is up and another model
            # may serve fine.
            warn "Startup generation check failed (curl rc=$_deep_rc); the server is"
            warn "up but the default model may not load. Other models may serve fine."
            _ok=1
            break
        fi
        sleep 1
        _i=$((_i + 1))
    done

    if [ "$_ok" = 1 ]; then
        info "Started in background (pid $_pid), healthy."
        dim "  log: $LOG"
        dim "  stop: ./scripts/stop-server.sh"
        exit 0
    fi

    # Failure path: kill it, show why, exit non-zero. The log tail is the
    # whole point - a hang shows the loader stalling, an OOM shows the
    # allocator, a crash shows the reason.
    kill "$_pid" 2>/dev/null
    sleep 1
    kill -9 "$_pid" 2>/dev/null
    rm -f "$STATE_DIR/server.pid"
    err "Server failed to become healthy within ${_health_timeout}s."
    echo "" >&2
    if [ -s "$LOG" ]; then
        echo "  Last log lines:" >&2
        tail -15 "$LOG" | sed 's/^/    /' >&2
    else
        echo "  Log is empty - the loader produced no output at all." >&2
    fi
    echo "" >&2
    echo "  Common causes:" >&2
    echo "    - GPU runtime wedged by a previously killed load (reboot clears it)" >&2
    echo "    - model + KV cache larger than VRAM at ctx $BONSAI_CTX" >&2
    echo "    - slow first load: retry with BONSAI_START_TIMEOUT=300" >&2
    exit 1
fi

dim "Ctrl+C to stop."
exec "${CMD[@]}"
