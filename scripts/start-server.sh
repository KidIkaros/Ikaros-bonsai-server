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
#   KILN_PORT=8081        listening port
#   KILN_CTX=65536        context size (Hermes needs >= 64000)
#   KILN_NGL=99           GPU layers, 0 for CPU-only
#   KILN_KV_TYPE=q8_0     KV cache type: q8_0 (default), q4_0, iq4_nl, q5_0,
#                           f16 to disable. See docs/HARDWARE.md.
#   KILN_KV_TYPE_K / _V   set K and V independently (advanced)
#   KILN_DRAFT_MODEL=path a *-dspark-* drafter, for speculative decoding
#   KILN_SPEC_TYPE=name   speculative decoding type; draft-mtp uses the MTP
#                           head inside a *-mtp.gguf, no second file needed
#   KILN_SPEC_STACK=upstream  keep llama.cpp's default ngram-mod alongside ours
#                           (default: kiln, which removes ngram-mod first)
#   KILN_SPEC_DRAFT_N_MAX tokens to draft (default 1; Vulkan prefers 2,
#                           ROCm prefers 1 on this card - measure both)
#   KILN_SPEC_DRAFT_P_MIN draft probability floor (default 0.0 = disabled;
#                           0.8 lets deeper n-max pay off, see RESEARCH-2026-10)
#   KILN_HOST=127.0.0.1    listening address; 0.0.0.0 to serve other machines
#   KILN_MODELS_DIR=path  models directory
#   KILN_MOE_CACHE_MIB=N GPU cache for CPU-resident MoE experts (+1.5-1.85x
#                           decode, needs a source build; ignored with a warning
#                           when the installed binary has no --moe-cache-mib)
#   KILN_SLEEP_IDLE=N|on|off  free VRAM after N idle seconds; the next request
#                           wakes and reloads (~2s). on=300, off=never (default)
#   KILN_EXTRA_ARGS="..." extra llama-server flags

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
        --kv-type)    export KILN_KV_TYPE="${2:-}"; shift ;;
        --kv-type-k)  export KILN_KV_TYPE_K="${2:-}"; shift ;;
        --kv-type-v)  export KILN_KV_TYPE_V="${2:-}"; shift ;;
        -h|--help)    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done


# Settings come from .state/service.env unless the environment already set them,
# so `kiln set` and a one-off `KILN_CTX=... ./scripts/start-server.sh` both work.
load_settings

if detect_is_stale; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

SERVER_BIN="$(llama_server_bin)" || die "No llama-server installed for backend '$BACKEND'.
       Run: ./scripts/fetch-binary.sh"

# server_supports FLAG - succeed when the installed llama-server binary accepts
# FLAG. llama.cpp adds flags over time and the pinned prebuilt may predate one;
# emitting an unsupported flag makes the server refuse to start with "invalid
# argument". Gate every flag that is not universal on this check (--no-spec-type
# below, --moe-cache-mib further down) so a flag lands only when the binary can
# parse it. --help is cached once per run.
_supports_help=""
server_supports() {
    [ -n "$_supports_help" ] || _supports_help="$("$SERVER_BIN" --help 2>&1)"
    printf '%s' "$_supports_help" | grep -q -- "$1"
}

[ -d "$MODELS_DIR" ] || die "Models directory does not exist: $MODELS_DIR
       Run: ./scripts/get-models.sh"

# Refuse to start with nothing to serve - a silent empty router is confusing.
_gguf_count="$(find "$MODELS_DIR" -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')"
[ "$_gguf_count" -gt 0 ] || die "No .gguf files in $MODELS_DIR
       Run: ./scripts/get-models.sh"

# Refuse to start when the port is already taken, rather than failing obscurely.
if command -v lsof >/dev/null 2>&1; then
    _busy="$(lsof -ti "tcp:$KILN_PORT" 2>/dev/null || true)"
    if [ -n "$_busy" ]; then
        _busycmd="$(tr '\0' ' ' < "/proc/$_busy/cmdline" 2>/dev/null | cut -c1-100)"
        err "Port $KILN_PORT is already in use (pid $_busy)."
        echo "       $_busycmd" >&2
        echo "" >&2
        echo "       If that is your own service, stop it with systemd. Otherwise pick" >&2
        echo "       another port:" >&2
        echo "         KILN_PORT=9000 ./scripts/start-server.sh" >&2
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
if [ "$KILN_CTX" -lt 64000 ] 2>/dev/null; then
    warn "KILN_CTX=$KILN_CTX is below 64000; Hermes requires at least that."
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
if [ "$KILN_KV_TYPE" = "auto" ]; then
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
       Example: KILN_KV_TYPE=q8_0 ./scripts/start-server.sh"
done

KV_ARGS=()
if [ "$(kv_type_effective)" != "f16" ]; then
    KV_ARGS=(--cache-type-k "$KV_TYPE_K" --cache-type-v "$KV_TYPE_V")
fi

# Speculative decoding. Either a separate drafter via KILN_DRAFT_MODEL, or a
# spec type such as draft-mtp, which uses the MTP head already inside the model
# file and needs no second file.
#
# Speed-first default: when the models directory holds a *-mtp.gguf and nothing
# was set explicitly, enable draft-mtp. It is the third-biggest measured lever
# (+23-33% Turing/Ampere with a grafted head, +15% on Vulkan, +6% on ROCm), and
# an explicit KILN_SPEC_TYPE=none still turns it off. The draft window is picked
# per backend by spec_nmax_for, because the optimal window is measured and
# backend-specific (Vulkan pays for 2, ROCm/CUDA do not).
#
# ngram-mod is the upstream default spec type since PR #28391, and --spec-type is
# ADDITIVE to it: passing --spec-type draft-mtp would otherwise get
# [ngram-mod, draft-mtp] and the two drafters would fight over the same verify
# batch. Since ngram-mod silently no-ops on the PrismML ternary models (issue
# #203: accepted, zero log lines, draft_n null, decode identical to none), it is
# explicitly removed here so the measured MTP path is what runs. KILN_SPEC_STACK
# overrides both sides for users who want the upstream stack.
DRAFT_ARGS=()
if [ -n "${KILN_DRAFT_MODEL:-}" ]; then
    [ -f "$KILN_DRAFT_MODEL" ] ||
        die "Draft model not found: $KILN_DRAFT_MODEL
       Set KILN_DRAFT_MODEL to a GGUF, or unset it to disable drafting."
    DRAFT_ARGS+=(--model-draft "$KILN_DRAFT_MODEL")
fi

# mtp_file_for_router - the *-mtp.gguf to load on demand for draft-mtp. Router
# mode has no single model pinned, so the head must be requested per call; when
# more than one MTP file is installed the loader needs to be told which one.
# The fat (non-lean) file wins when present: it carries the full MTP head, and
# on cards with room it is the one whose acceptance rates were measured.
mtp_file_for_router() {
    local _fat="" _lean=""
    while IFS= read -r _f; do
        case "$(printf '%s' "$(basename "$_f")" | tr '[:upper:]' '[:lower:]')" in
            *lean*) _lean="$_f" ;;
            *)      _fat="$_f" ;;
        esac
    done < <(find "$MODELS_DIR" -maxdepth 1 -name '*.gguf' 2>/dev/null |
             while IFS= read -r _f; do
                 file_has_mtp_head "$_f" && printf '%s\n' "$_f"
             done | sort)
    printf '%s' "${_fat:-$_lean}"
}

if [ -z "${KILN_SPEC_TYPE:-}" ]; then
    _mtp_file="$(mtp_file_for_router)"
    if [ -n "$_mtp_file" ]; then
        KILN_SPEC_TYPE="draft-mtp"
        info "MTP head found in $(basename "$_mtp_file"); enabling draft-mtp."
    fi
fi

# --spec-type is additive to the upstream default (ngram-mod, PR #28391), so
# unless it is explicitly removed the binary runs [ngram-mod, draft-mtp] and the
# two drafters share one verify batch. KILN_SPEC_STACK=upstream keeps the
# upstream stack for users who want it; otherwise ngram-mod is removed first,
# and any explicit KILN_SPEC_TYPE is added on top.
#
# --no-spec-type only exists on newer llama.cpp builds; the pinned prebuilt
# (prism-b10772) predates it. Gate on binary support, exactly like
# --moe-cache-mib below: emitting it unconditionally made the server refuse to
# start with "invalid argument: --no-spec-type" on that build. On a build
# without the flag there is nothing to remove (no additive ngram-mod default
# either), so skipping it is correct, not a silent behaviour change.
if [ "${KILN_SPEC_STACK:-kiln}" != "upstream" ] && server_supports --no-spec-type; then
    DRAFT_ARGS+=(--no-spec-type ngram-mod)
fi

if [ -n "${KILN_SPEC_TYPE:-}" ] && [ "${_KILN_FROM_ENV:-}" != *"KILN_SPEC_DRAFT_N_MAX"* ]; then
    # A backend-tuned default, only when the caller did not set one: on Vulkan
    # n-max 2 measured fastest, on ROCm/CUDA n-max 2 measured slower than the
    # baseline, so the value that ships is the measured winner per backend.
    _nmax="$(spec_nmax_for "$BACKEND")"
    [ "$_nmax" -gt 0 ] && KILN_SPEC_DRAFT_N_MAX="$_nmax"
fi
if [ -n "${KILN_SPEC_TYPE:-}" ]; then
    case "$KILN_SPEC_TYPE" in
        none|draft-simple|draft-eagle3|draft-mtp|draft-dflash|draft-dspark|\
        ngram-simple|ngram-map-k|ngram-map-k4v|ngram-mod|ngram-cache) ;;
        *) die "Unknown KILN_SPEC_TYPE '$KILN_SPEC_TYPE'.
       Allowed: none, draft-simple, draft-eagle3, draft-mtp, draft-dflash,
                draft-dspark, ngram-simple, ngram-map-k, ngram-map-k4v,
                ngram-mod, ngram-cache" ;;
    esac
    if [ "$KILN_SPEC_TYPE" != "none" ]; then
        DRAFT_ARGS+=(--spec-type "$KILN_SPEC_TYPE"
                     --spec-draft-n-max "$KILN_SPEC_DRAFT_N_MAX")
        # The probability floor is only passed when enabled: passing 0.0
        # explicitly is the llama.cpp default, but keeping it off the command
        # line means older builds without the flag still work.
        if [ "${KILN_SPEC_DRAFT_P_MIN:-0.0}" != "0.0" ] && [ -n "${KILN_SPEC_DRAFT_P_MIN:-}" ]; then
            DRAFT_ARGS+=(--spec-draft-p-min "$KILN_SPEC_DRAFT_P_MIN")
        fi
    fi
fi

# Only pass --n-gpu-layers when there is actually a GPU backend in play.
NGL_ARGS=()
case "$BACKEND" in
    cpu) ;;
    *) NGL_ARGS=(--n-gpu-layers "$KILN_NGL") ;;
esac

# shellcheck disable=SC2206
EXTRA_ARGS=(${KILN_EXTRA_ARGS:-})

# Idle sleep (--sleep-idle-seconds): after N seconds with no request the server
# frees the model from VRAM and sleeps; the next request wakes it and reloads
# transparently (measured ~2s on this hardware). This is the native
# load-on-demand feel - VRAM is returned to the desktop/games when Kiln is
# idle, with no "keep it running" mental overhead. KILN_SLEEP_IDLE accepts a
# number of seconds, or on (=300) / off (=-1, the llama.cpp default). Gated on
# binary support; a build without the flag is left as-is.
SLEEP_ARGS=()
if [ -n "${KILN_SLEEP_IDLE:-}" ]; then
    case "$(printf '%s' "$KILN_SLEEP_IDLE" | tr '[:upper:]' '[:lower:]')" in
        on)             _sleep_s=300 ;;
        off|none|never) _sleep_s=-1 ;;
        ''|*[!0-9-]*)   die "KILN_SLEEP_IDLE must be seconds, or on/off, got '$KILN_SLEEP_IDLE'." ;;
        *)              _sleep_s="$KILN_SLEEP_IDLE" ;;
    esac
    if server_supports --sleep-idle-seconds; then
        SLEEP_ARGS=(--sleep-idle-seconds "$_sleep_s")
        if [ "$_sleep_s" -gt 0 ] 2>/dev/null; then
            info "Idle sleep : after ${_sleep_s}s idle, frees VRAM until the next request"
        fi
    else
        warn "KILN_SLEEP_IDLE set, but this build has no --sleep-idle-seconds."
    fi
fi

# MoE expert cache (--moe-cache-mib): keeps hot CPU-resident experts in a GPU
# cache, worth 1.5-1.85x decode on models split across VRAM and RAM (PR #29887,
# measured RTX 4090 1.57-1.62x, RTX 5090 1.77x). It is newer than the pinned
# prebuilt, so the flag is passed only when the binary actually supports it -
# an unknown flag aborts llama-server at startup.
MOE_CACHE_ARGS=()
if [ -n "${KILN_MOE_CACHE_MIB:-}" ]; then
    case "$KILN_MOE_CACHE_MIB" in
        ''|*[!0-9]*) die "KILN_MOE_CACHE_MIB must be a number, got '$KILN_MOE_CACHE_MIB'.
       Example: ./scripts/kiln set moe-cache-mib 2048" ;;
    esac
    if server_supports --moe-cache-mib; then
        MOE_CACHE_ARGS=(--moe-cache-mib "$KILN_MOE_CACHE_MIB")
        info "MoE cache : ${KILN_MOE_CACHE_MIB} MiB (needs a build newer than $PRISM_RELEASE)"
    else
        warn "KILN_MOE_CACHE_MIB set, but this build has no --moe-cache-mib."
        dim "  A source build gets it: ./scripts/build-from-source.sh"
    fi
fi

# Threads come from the setting (or `kiln set threads`), falling back to all
# cores. Validated here so a bad value fails with a clear message instead of a
# cryptic llama-server error.
KILN_THREADS="${KILN_THREADS:-$(nproc 2>/dev/null || echo 4)}"
case "$KILN_THREADS" in
    ''|*[!0-9]*) die "KILN_THREADS must be a number, got '$KILN_THREADS'.\n       Example: ./scripts/kiln set threads 8" ;;
esac

# ---------------------------------------------------------------------------
# Memory safety check (a balancing loop, not a quality cut)
# ---------------------------------------------------------------------------
# Warn before launch when the largest model plus its KV cache will not fit the
# memory budget. Reuses the existing cost model (kv_budget_gb for the budget
# with headroom, model_size_bytes, kv_mib when the model is measured) rather
# than re-deriving sizes here. Never blocks the start and never changes
# settings - it only surfaces a risk the user would otherwise hit as an
# OOM-kill or a silent CPU fallback. When the model is unmeasured there is no
# honest number, so it stays silent (kv_type_auto already warns on that).
_mem_largest="$(find "$MODELS_DIR" -name '*.gguf' -not -name '*mmproj*' \
    -not -name '*kv-mean-center-*' -not -name '*dspark*' 2>/dev/null |
    while IFS= read -r _f; do printf '%s\t%s\n' "$(model_size_bytes "$_f")" "$_f"; done |
    sort -rn | head -1 | cut -f2)"
if [ -n "$_mem_largest" ] && _mem_budget="$(kv_budget_gb 2>/dev/null)"; then
    _mem_w="$(awk -v b="$(model_size_bytes "$_mem_largest")" 'BEGIN{printf "%.2f", b/1073741824}')"
    _mem_kv="$(kv_mib "$_mem_largest" "$KILN_CTX" "${KILN_KV_TYPE:-q8_0}" 2>/dev/null |
        awk '{printf "%.2f", $1/1024}')"
    _mem_kv="${_mem_kv:-0}"
    if awk -v w="$_mem_w" -v k="$_mem_kv" -v b="$_mem_budget" 'BEGIN{exit !(w+k > b)}'; then
        _mem_kind="VRAM"; [ "${BACKEND:-cpu}" = "cpu" ] && _mem_kind="RAM"
        warn "Memory: $(basename "$_mem_largest") needs ~$(awk -v w="$_mem_w" -v k="$_mem_kv" 'BEGIN{printf "%.1f", w+k}') GB but the budget is ${_mem_budget} GB ${_mem_kind}."
        dim "  A smaller quant fits better: ./scripts/get-models.sh --recommend"
    fi
fi

CMD=(
    "$SERVER_BIN"
    --models-dir "$MODELS_DIR"
    --models-max 1
    --host "${KILN_HOST:-127.0.0.1}"
    --port "$KILN_PORT"
    --ctx-size "$KILN_CTX"
    --threads "$KILN_THREADS"
    --flash-attn on
    --no-warmup
    --jinja
    "${KV_ARGS[@]}"
    "${DRAFT_ARGS[@]}"
    "${NGL_ARGS[@]}"
    "${MOE_CACHE_ARGS[@]}"
    "${SLEEP_ARGS[@]}"
    "${EXTRA_ARGS[@]}"
)

step "Starting llama-server"
printf '  %s\n' "${C_DIM}${CMD[*]}${C_RESET}"
echo ""
info "Backend     : $BACKEND"
info "Models dir  : $MODELS_DIR  ($_gguf_count file(s))"
if [ -n "${KILN_DRAFT_MODEL:-}" ]; then
    info "Draft model : $(basename "$KILN_DRAFT_MODEL")  (speculative decoding)"
fi
if [ -n "${KILN_SPEC_TYPE:-}" ] && [ "$KILN_SPEC_TYPE" != "none" ]; then
    if [ "$KILN_SPEC_TYPE" = "draft-mtp" ] && [ -n "${_mtp_file:-}" ]; then
        info "Spec decode : draft-mtp from $(basename "$_mtp_file"), n-max $KILN_SPEC_DRAFT_N_MAX"
    else
        info "Spec decode : $KILN_SPEC_TYPE, n-max $KILN_SPEC_DRAFT_N_MAX"
    fi
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
info "Web UI      : http://localhost:$KILN_PORT"
info "OpenAI API  : http://localhost:$KILN_PORT/v1"
echo ""

if [ "$OPEN_BROWSER" = 1 ]; then
    (
        for _ in $(seq 1 60); do
            if command -v curl >/dev/null 2>&1; then
                curl -sf "http://127.0.0.1:$KILN_PORT/health" >/dev/null 2>&1 && break
            fi
            sleep 1
        done
        _url="http://localhost:$KILN_PORT"
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
    _health_timeout="${KILN_START_TIMEOUT:-120}"
    info "Waiting up to ${_health_timeout}s for the server to become healthy..."
    _ok=0
    _i=0
    while [ "$_i" -lt "$_health_timeout" ]; do
        if ! kill -0 "$_pid" 2>/dev/null; then
            err "llama-server exited during startup (pid $_pid)."
            break
        fi
        if command -v curl >/dev/null 2>&1 &&
           curl -sf --max-time 5 "http://127.0.0.1:$KILN_PORT/health" >/dev/null 2>&1; then
            # /health only proves the process is up. In router mode the model
            # load happens per-request, and that is what hangs on a wedged
            # runtime, so verify one real generation too. The model id must be
            # named: router mode rejects a request without one with "model
            # name is missing from the request", which would make a perfectly
            # healthy server look broken here.
            _deep_model="$(first_model_id "http://127.0.0.1:$KILN_PORT")"
            if [ -z "$_deep_model" ]; then
                # No model id resolvable: the router reported no models. The
                # server is up, so treat it as healthy and let the first real
                # request surface any loading problem.
                _ok=1
                break
            fi
            _deep_rc=0
            _deep="$(curl -sf --max-time 90 \
                "http://127.0.0.1:$KILN_PORT/v1/chat/completions" \
                -H 'Content-Type: application/json' \
                -d "{\"model\":\"$_deep_model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1,\"temperature\":0}" \
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
    echo "    - model + KV cache larger than VRAM at ctx $KILN_CTX" >&2
    echo "    - slow first load: retry with KILN_START_TIMEOUT=300" >&2
    exit 1
fi

dim "Ctrl+C to stop."
exec "${CMD[@]}"
