#!/usr/bin/env bash
# assess.sh - what can this machine actually run?
#
# Answers that question with our own measurements rather than a generic
# estimate, because for these models the KV cache, not the weights, usually
# decides the answer. The KV cost is measured once per model and then computed
# exactly for every cache type.
#
# Usage:
#   ./scripts/assess.sh                    assess installed models at 65536 / q8_0
#   ./scripts/assess.sh --context 32768    a different context
#   ./scripts/assess.sh --kv-type q4_0     a different KV cache type
#   ./scripts/assess.sh --kv-matrix        every KV type side by side
#   ./scripts/assess.sh --measure          measure KV cost for installed models
#   ./scripts/assess.sh --measure --speed  also benchmark tokens per second
#
# Measuring is a one-off cost per model: it loads the model briefly at a tiny
# context to read its cache geometry, which is exact and cheap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONTEXT="$BONSAI_CTX"
KV_TYPE="$(kv_type_effective)"
[ "$KV_TYPE" = "f16" ] && KV_TYPE="q8_0"
DO_MEASURE=0
DO_SPEED=0
MATRIX=0

while [ $# -gt 0 ]; do
    case "$1" in
        --context)  CONTEXT="${2:-}"; shift ;;
        --kv-type)  KV_TYPE="${2:-}"; shift ;;
        --measure)  DO_MEASURE=1 ;;
        --speed)    DO_SPEED=1 ;;
        --kv-matrix) MATRIX=1 ;;
        -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

case "$CONTEXT" in ''|*[!0-9]*) die "--context needs a number, got '$CONTEXT'." ;; esac
kv_type_valid "$KV_TYPE" || die "Unknown KV cache type '$KV_TYPE'. Allowed: $KV_CACHE_TYPES"

if detect_is_stale; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

SERVER_BIN="$(llama_server_bin)" || die "No llama-server installed. Run: ./scripts/fetch-binary.sh"

# ---------------------------------------------------------------------------
# Budget: how much memory the models may use
# ---------------------------------------------------------------------------

if [ "$BACKEND" = "cpu" ]; then
    BUDGET_GB="$RAM_GB"
    BUDGET_LABEL="system RAM"
    BUDGET_RESERVE=2
else
    BUDGET_GB="$VRAM_GB"
    BUDGET_LABEL="VRAM"
    BUDGET_RESERVE=1
fi
[ "$BUDGET_GB" -gt 0 ] || die "Could not determine a memory budget from detection."
BUDGET_AVAIL=$((BUDGET_GB - BUDGET_RESERVE))

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

mapfile -t MODELS < <(find "$MODELS_DIR" -name '*.gguf' \
    -not -name '*mmproj*' -not -name 'kv-mean-center-*' 2>/dev/null | sort)
[ "${#MODELS[@]}" -gt 0 ] || die "No models in $MODELS_DIR. Run: ./scripts/get-models.sh"

# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

# measure_kv MODEL - load briefly and record the f16 bytes per cell.
measure_kv() {
    _model="$1"
    _port=$((BONSAI_PORT + 200))
    _log="$STATE_DIR/assess-measure.log"

    # A tiny context keeps this cheap: the cache is linear in cells, so 512
    # cells give the per-cell cost to full precision.
    "$SERVER_BIN" -m "$_model" --port "$_port" --ctx-size 512 \
        --cache-type-k f16 --cache-type-v f16 \
        --n-gpu-layers "$BONSAI_NGL" --no-warmup -lv 4 >"$_log" 2>&1 &
    _pid=$!

    _mib=""
    for _ in $(seq 1 60); do
        _mib="$(grep -a -oE 'llama_kv_cache: *size = *[0-9.]+ MiB' "$_log" 2>/dev/null \
            | head -1 | grep -oE '[0-9.]+' || true)"
        [ -n "$_mib" ] && break
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
    done
    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true

    if [ -z "$_mib" ]; then
        warn "Could not measure $(basename "$_model") - it did not report a KV size."
        dim "  See $_log"
        return 1
    fi

    _bpc="$(awk -v mib="$_mib" 'BEGIN { printf "%.4f", mib * 1048576 / 512 }')"
    kv_cost_set "$_model" "$_bpc"
    info "measured $(basename "$_model"): ${_mib} MiB at 512 cells (${_bpc} bytes/cell)"
}

# measure_speed MODEL CONTEXT KV - run a short generation and record tok/s.
measure_speed() {
    _model="$1" _ctx="$2" _kv="$3"
    _port=$((BONSAI_PORT + 201))
    _log="$STATE_DIR/assess-speed.log"

    "$SERVER_BIN" -m "$_model" --port "$_port" --ctx-size "$_ctx" \
        --cache-type-k "$_kv" --cache-type-v "$_kv" \
        --n-gpu-layers "$BONSAI_NGL" --no-warmup --jinja >"$_log" 2>&1 &
    _pid=$!

    _ready=0
    for _ in $(seq 1 120); do
        curl -sf "http://127.0.0.1:$_port/health" >/dev/null 2>&1 && { _ready=1; break; }
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
    done

    _tps=""
    if [ "$_ready" = 1 ]; then
        _resp="$(curl -s --max-time 180 "http://127.0.0.1:$_port/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d '{"messages":[{"role":"user","content":"Write a short paragraph about the sea."}],"max_tokens":128,"temperature":0.7}' \
            2>/dev/null || true)"
        _tps="$(printf '%s' "$_resp" | python3 -c '
import json, sys
try:
    print(round(json.load(sys.stdin).get("timings", {}).get("predicted_per_second", 0), 1))
except Exception:
    pass
' 2>/dev/null || true)"
    fi

    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true

    if [ -z "$_tps" ] || [ "$_tps" = "0" ]; then
        warn "Could not measure speed for $(basename "$_model") at $_ctx/$_kv."
        # Distinguish "not enough memory right now" from a real failure. The
        # assessment models total capacity; a benchmark needs free capacity.
        if grep -qa "out of memory\|failed to allocate" "$_log" 2>/dev/null; then
            _other="$(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null | head -1 || true)"
            if [ -n "$_other" ]; then
                dim "  Not enough free memory. Something else is holding it, on port"
                dim "  $BONSAI_PORT (pid $_other). Stop it and re-run, or benchmark a"
                dim "  smaller context: ./scripts/assess.sh --measure --speed --context 32768"
            else
                dim "  Not enough free memory for this model at $_ctx context."
            fi
        else
            dim "  See $_log"
        fi
        return 1
    fi
    speed_set "$_model" "$_ctx" "$_kv" "$_tps"
    info "measured $(basename "$_model") at $_ctx/$_kv: ${_tps} tok/s"
}

if [ "$DO_MEASURE" = 1 ]; then
    step "Measuring KV cache cost"
    dim "  One brief load per model at a 512-token context."
    for _m in "${MODELS[@]}"; do
        if [ -n "$(kv_cost_get "$_m" || true)" ]; then
            dim "  already measured: $(basename "$_m")"
            continue
        fi
        measure_kv "$_m" || true
    done

    if [ "$DO_SPEED" = 1 ]; then
        step "Benchmarking tokens per second at $CONTEXT / $KV_TYPE"
        dim "  One 128-token generation per model. This takes a while."
        for _m in "${MODELS[@]}"; do
            [ -n "$(kv_cost_get "$_m" || true)" ] || continue
            measure_speed "$_m" "$CONTEXT" "$KV_TYPE" || true
        done
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Assessment
# ---------------------------------------------------------------------------

step "Hardware"
info "GPU      : $GPU_NAME"
info "Backend  : $BACKEND"
info "VRAM     : ${VRAM_GB} GB"
info "RAM      : ${RAM_GB} GB"
info "Budget   : ${BUDGET_AVAIL} GB of $BUDGET_LABEL (${BUDGET_RESERVE} GB held back)"

printf '\n  %-44s %8s %8s %8s %9s  %s\n' "model" "weights" "KV" "total" "spare" "verdict"
printf '  %s\n' "--------------------------------------------------------------------------------------------------"

UNMEASURED=0
BEST=""
BEST_TOTAL=0

for _m in "${MODELS[@]}"; do
    _name="$(basename "$_m" .gguf)"
    _wbytes="$(model_size_bytes "$_m")"
    _wgb="$(awk -v b="$_wbytes" 'BEGIN { printf "%.1f", b/1073741824 }')"

    _kvmib="$(kv_mib "$_m" "$CONTEXT" "$KV_TYPE" || true)"
    if [ -z "$_kvmib" ]; then
        UNMEASURED=$((UNMEASURED + 1))
        printf '  %-44s %7sG %8s %8s %9s  %s\n' "${_name:0:44}" "$_wgb" "?" "?" "?" "not measured"
        continue
    fi

    _kvgb="$(awk -v m="$_kvmib" 'BEGIN { printf "%.1f", m/1024 }')"
    _total="$(awk -v w="$_wgb" -v k="$_kvgb" 'BEGIN { printf "%.1f", w + k }')"
    _spare="$(awk -v b="$BUDGET_AVAIL" -v t="$_total" 'BEGIN { printf "%.1f", b - t }')"
    _verdict="$(awk -v s="$_spare" 'BEGIN { print (s >= 0) ? "fits" : "does not fit" }')"

    # Track the largest model that fits, as the headline recommendation.
    if awk -v s="$_spare" 'BEGIN { exit !(s >= 0) }'; then
        if awk -v t="$_total" -v b="$BEST_TOTAL" 'BEGIN { exit !(t > b) }'; then
            BEST="$_name"; BEST_TOTAL="$_total"
        fi
    fi

    _tps="$(speed_get "$_m" "$CONTEXT" "$KV_TYPE" || true)"
    printf '  %-44s %7sG %7sG %7sG %8sG  %s%s\n' \
        "${_name:0:44}" "$_wgb" "$_kvgb" "$_total" "$_spare" "$_verdict" \
        "$([ -n "$_tps" ] && printf '  %s tok/s' "$_tps")"
done

echo ""
info "Assessed at $CONTEXT context, $KV_TYPE KV cache"

if [ "$UNMEASURED" -gt 0 ]; then
    echo ""
    warn "$UNMEASURED model(s) not measured. Run: ./scripts/assess.sh --measure"
    dim "  Without a measurement the KV cost cannot be computed, and the KV"
    dim "  cache is usually the larger half of the answer."
fi

if [ -n "$BEST" ]; then
    echo ""
    info "Largest that fits: $BEST (${BEST_TOTAL} GB)"
elif [ "$UNMEASURED" -eq "${#MODELS[@]}" ]; then
    echo ""
    dim "Nothing measured yet, so there is no verdict to give."
else
    echo ""
    warn "Nothing measured fits. Try a smaller model, a smaller KV type, or a"
    warn "smaller context: ./scripts/assess.sh --kv-type iq4_nl --context 32768"
fi

# ---------------------------------------------------------------------------
# KV type matrix
# ---------------------------------------------------------------------------

if [ "$MATRIX" = 1 ]; then
    step "KV cache type at $CONTEXT context"
    printf '  %-44s' "model"
    for _t in q8_0 q5_0 iq4_nl q4_0 f16; do printf '%10s' "$_t"; done
    printf '\n  %s\n' "--------------------------------------------------------------------------------------------------"

    for _m in "${MODELS[@]}"; do
        _name="$(basename "$_m" .gguf)"
        printf '  %-44s' "${_name:0:44}"
        for _t in q8_0 q5_0 iq4_nl q4_0 f16; do
            _kvmib="$(kv_mib "$_m" "$CONTEXT" "$_t" || true)"
            if [ -z "$_kvmib" ]; then
                printf '%10s' "?"
            else
                _kvgb="$(awk -v m="$_kvmib" 'BEGIN { printf "%.1f", m/1024 }')"
                _wgb="$(awk -v b="$(model_size_bytes "$_m")" 'BEGIN { printf "%.1f", b/1073741824 }')"
                _fits="$(awk -v b="$BUDGET_AVAIL" -v w="$_wgb" -v k="$_kvgb" \
                    'BEGIN { printf "%s", (w + k <= b) ? "ok" : "no" }')"
                printf '%9s%s' "${_kvgb}G" "$([ "$_fits" = ok ] && printf ' ' || printf '-')"
            fi
        done
        printf '\n'
    done
    echo ""
    dim "  Values are KV cache size; a trailing space means the total still fits,"
    dim "  a '-' means it does not. q8_0 is the default."
fi

echo ""
dim "  Measured values live in $KV_COST_CACHE and $SPEED_CACHE."
dim "  Speed is measured, never estimated; run --measure --speed to fill it in."
