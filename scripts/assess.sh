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
#   ./scripts/assess.sh --sweep            split the model across VRAM and RAM,
#                                          measuring tokens per second at each split
#   ./scripts/assess.sh --tune             try the settings that affect speed and
#                                          report the fastest on this machine
#
# --sweep answers "how much of this model should go on the GPU?". llama.cpp can
# keep some layers in VRAM and run the rest from system RAM, so a model larger
# than VRAM can still run, just slower. The sweep measures the curve instead of
# guessing it.
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
SWEEP=0
SWEEP_TOKENS=64
SWEEP_LEVELS=""
SWEEP_MODEL=""
TUNE=0
TUNE_TOKENS=64
TUNE_MODEL=""
COVERAGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --context)  CONTEXT="${2:-}"; shift ;;
        --kv-type)  KV_TYPE="${2:-}"; shift ;;
        --measure)  DO_MEASURE=1 ;;
        --speed)    DO_SPEED=1 ;;
        --kv-matrix) MATRIX=1 ;;
        --sweep)    SWEEP=1 ;;
        --sweep-tokens) SWEEP_TOKENS="${2:-64}"; shift ;;
        --sweep-levels) SWEEP_LEVELS="${2:-}"; shift ;;
        --model)    SWEEP_MODEL="${2:-}"; TUNE_MODEL="${2:-}"; shift ;;
        --tune)     TUNE=1 ;;
        --coverage) COVERAGE=1 ;;
        --tune-tokens) TUNE_TOKENS="${2:-64}"; shift ;;
        -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

case "$CONTEXT" in ''|*[!0-9]*) die "--context needs a number, got '$CONTEXT'." ;; esac

if detect_is_stale; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

# Resolving "auto" needs the measurements and the budget, so it has to happen
# after detection and before anything validates the value. KV_TYPE was captured
# from the setting earlier, so re-read it now that it may have changed.
kv_type_resolve
# Report the type that will actually be used. An earlier version mapped f16 to
# q8_0 here, which was written when f16 meant "quantization disabled"; now that
# auto can pick f16, that mapping would report a type the server will not use.
KV_TYPE="$(kv_type_effective)"
kv_type_valid "$KV_TYPE" || die "Unknown KV cache type '$KV_TYPE'. Allowed: $KV_CACHE_TYPES"

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
    _layers=""
    for _ in $(seq 1 60); do
        # One line carries everything: "size = 1296.00 MiB ( 32768 cells, 36
        # layers, 4/1 seqs), K (q4_0): ...".
        _line="$(grep -a -oE 'llama_kv_cache: *size = *[0-9.]+ MiB \( *[0-9]+ cells, *[0-9]+ layers' "$_log" 2>/dev/null | head -1 || true)"
        if [ -n "$_line" ]; then
            _mib="$(printf '%s' "$_line" | grep -oE '[0-9.]+ MiB' | grep -oE '[0-9.]+')"
            _layers="$(printf '%s' "$_line" | grep -oE '[0-9]+ layers' | grep -oE '[0-9]+')"
            break
        fi
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
    kv_cost_set "$_model" "$_bpc" "${_layers:-}"
    coverage_set model "$(basename "$_model")"
    info "measured $(basename "$_model"): ${_mib} MiB at 512 cells, ${_layers:-?} layers (${_bpc} bytes/cell)"
}

# bench_tps MODEL NGL CONTEXT KV TOKENS - run one generation, print tok/s.
# Prints nothing and fails if the server cannot start or produce a number.
bench_tps() {
    _model="$1" _ngl="$2" _ctx="$3" _kv="$4" _tokens="$5"
    shift 5
    _port="$BENCH_PORT"
    _log="$BENCH_LOG"

    "$SERVER_BIN" -m "$_model" --port "$_port" --ctx-size "$_ctx" \
        --cache-type-k "$_kv" --cache-type-v "$_kv" \
        --n-gpu-layers "$_ngl" --no-warmup --jinja "$@" >"$_log" 2>&1 &
    _pid=$!

    _ready=0
    for _ in $(seq 1 120); do
        curl -sf "http://127.0.0.1:$_port/health" >/dev/null 2>&1 && { _ready=1; break; }
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
    done

    _tps=""
    if [ "$_ready" = 1 ]; then
        _resp="$(curl -s --max-time 300 "http://127.0.0.1:$_port/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d "$(printf '{"messages":[{"role":"user","content":"Write a short paragraph about the sea."}],"max_tokens":%s,"temperature":0.7}' "$_tokens")" \
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

    [ -n "$_tps" ] && [ "$_tps" != "0" ] || return 1
    printf '%s' "$_tps"
}

# explain_bench_failure LOG - say why a benchmark produced nothing.
explain_bench_failure() {
    if grep -qa "out of memory\|failed to allocate" "$1" 2>/dev/null; then
        dim "  Not enough free memory for this configuration."
        if grep -qa "kv cache" "$1" 2>/dev/null; then
            dim "  The KV cache is what did not fit. A smaller BONSAI_CTX or a"
            dim "  smaller BONSAI_KV_TYPE will free room."
        fi
    else
        dim "  See $1"
    fi
}

# measure_speed MODEL CONTEXT KV - run a short generation and record tok/s.
measure_speed() {
    _model="$1" _ctx="$2" _kv="$3"
    BENCH_PORT=$((BONSAI_PORT + 201))
    BENCH_LOG="$STATE_DIR/assess-speed.log"

    _tps="$(bench_tps "$_model" "$BONSAI_NGL" "$_ctx" "$_kv" 128 || true)"

    if [ -z "$_tps" ]; then
        warn "Could not measure speed for $(basename "$_model") at $_ctx/$_kv."
        # Distinguish "not enough memory right now" from a real failure. The
        # assessment models total capacity; a benchmark needs free capacity.
        if grep -qa "out of memory\|failed to allocate" "$BENCH_LOG" 2>/dev/null; then
            _other="$(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null | head -1 || true)"
            if [ -n "$_other" ]; then
                dim "  Not enough free memory. Something else is holding it, on port"
                dim "  $BONSAI_PORT (pid $_other). Stop it and re-run, or benchmark a"
                dim "  smaller context: ./scripts/assess.sh --measure --speed --context 32768"
            else
                dim "  Not enough free memory for this model at $_ctx context."
            fi
        else
            dim "  See $BENCH_LOG"
        fi
        return 1
    fi
    speed_set "$_model" "$_ctx" "$_kv" "$_tps"
    coverage_set backend "${BACKEND:-unknown}"
    coverage_set kv "$_kv"
    info "measured $(basename "$_model") at $_ctx/$_kv: ${_tps} tok/s"
}

# show_coverage - which configuration dimensions have been explored.
#
# What improves a recommendation is not how many measurements were run but how
# many distinct dimensions were opened. Re-measuring inside one dimension buys
# a few percent; a new dimension is where the step changes came from. This
# prints the map so the unexplored ones are visible rather than implied.
show_coverage() {
    step "Configuration coverage"

    local _rows="" _n
    _add() {
        local _d="$1" _y="$2" _vals
        # paste -sd', ' treats the two characters as alternating delimiters.
        _vals="$(coverage_values "$_d" | paste -sd',' - 2>/dev/null | sed 's/,/, /g')"
        if [ -z "$_vals" ]; then
            _vals="not explored"
            _rows="${_rows}${_d}\t${_vals}\t${_y}\tUNEXPLORED\n"
        else
            _rows="${_rows}${_d}\t${_vals}\t${_y}\tcovered\n"
        fi
    }

    # Ordered by measured yield, which is the point: the top of this list is
    # where a run is worth spending.
    _add ngl      "up to 4.2x"
    _add backend  "up to 15%"
    _add spec     "up to 13%"
    _add kv       "3 to 5%"
    _add context  "unknown"
    _add ubatch   "about 3%"
    _add model    "-"

    printf '  %-10s %-34s %-10s %s\n' "dimension" "explored" "yield" "status"
    printf '  %s\n' "-------------------------------------------------------------------------"
    printf '%b' "$_rows" | while IFS="$(printf '\t')" read -r _d _v _y _st; do
        printf '  %-10s %-34s %-10s %s\n' "$_d" "$_v" "$_y" "$_st"
    done

    echo ""
    printf '  %s\n' "Thread count was measured as noise on this hardware (86.9 against 87.1 tok/s),"
    printf '  %s\n' "so it is deliberately not tracked."

    local _missing=""
    for _d in ngl backend spec kv context; do
        [ -n "$(coverage_values "$_d")" ] || _missing="$_missing $_d"
    done

    echo ""
    if [ -n "$_missing" ]; then
        info "Unexplored with real potential:$_missing"
        case "$_missing" in
            *ngl*)     dim "  ./scripts/assess.sh --sweep            # find the offload split" ;;
        esac
        case "$_missing" in
            *context*) dim "  ./scripts/assess.sh --sweep --context 131072   # long context" ;;
        esac
        case "$_missing" in
            *backend*) dim "  BACKEND=vulkan ./scripts/setup.sh     # the other backend" ;;
        esac
        case "$_missing" in
            *spec*)    dim "  ./scripts/assess.sh --tune            # tests MTP when the model has it" ;;
        esac
        case "$_missing" in
            *kv*)      dim "  ./scripts/assess.sh --measure --speed # prices the cache types" ;;
        esac
    else
        info "Every tracked dimension has been explored."
    fi
    echo ""
}

if [ "$COVERAGE" = 1 ]; then
    show_coverage
    exit 0
fi

if [ "$DO_MEASURE" = 1 ]; then
    step "Measuring KV cache cost"
    dim "  One brief load per model at a 512-token context."
    for _m in "${MODELS[@]}"; do
        if kv_measured "$_m"; then
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
# Tuning: try the settings that move throughput, keep the fastest
# ---------------------------------------------------------------------------

if [ "$TUNE" = 1 ]; then
    if [ -n "$TUNE_MODEL" ]; then
        TUNE_PATH="$TUNE_MODEL"
        [ -f "$TUNE_PATH" ] || die "No such model: $TUNE_PATH"
    else
        TUNE_PATH="${MODELS[0]}"
        [ "${#MODELS[@]}" -gt 1 ] && dim "  Using $(basename "$TUNE_PATH"); override with --model"
    fi

    kv_measured "$TUNE_PATH" || die "$(basename "$TUNE_PATH") is not measured.
       Run first: ./scripts/assess.sh --measure"

    W_GB="$(awk -v b="$(model_size_bytes "$TUNE_PATH")" 'BEGIN { printf "%.2f", b/1073741824 }')"

    step "Tuning for throughput"
    info "Model  : $(basename "$TUNE_PATH")"
    info "Context: $CONTEXT"
    dim "  Each row is a full model load and a $TUNE_TOKENS-token generation."
    dim "  Numbers move a few percent between runs, so treat small gaps as noise."

    # A benchmark needs free memory, not just total. Measuring while something
    # else holds the GPU produces numbers that do not reproduce: that is exactly
    # how an earlier run reported f16 KV as slower when it is in fact faster.
    _free="$(free_vram_gb || true)"
    if [ -n "$_free" ]; then
        info "Free VRAM: ${_free} GB of ${VRAM_GB} GB"
        if awk -v f="$_free" 'BEGIN { exit !(f < 8) }'; then
            warn "Less than 8 GB of VRAM is free, so these numbers may not reproduce."
            dim "  Another process is holding memory. Stop it first for a clean run:"
            _other="$(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null | head -1 || true)"
            [ -n "$_other" ] && dim "    something is on port $BONSAI_PORT (pid $_other)"
            dim "    ./scripts/bonsai stop   if this repo's server is the one running"
        fi
    fi

    _results="$STATE_DIR/tune-results.tsv"
    : > "$_results"
    echo ""

    # label | kv type | extra server args | env to reproduce
    run_variant() {
        _label="$1" _kv="$2" _extra="$3" _env="$4"

        # A cache that does not fit is not a candidate, so check before loading.
        _kvmib="$(kv_mib "$TUNE_PATH" "$CONTEXT" "$_kv" || true)"
        if [ -n "$_kvmib" ]; then
            _kvgb="$(awk -v m="$_kvmib" 'BEGIN { printf "%.2f", m/1024 }')"
            if ! awk -v w="$W_GB" -v k="$_kvgb" -v b="$BUDGET_AVAIL" 'BEGIN { exit !(w + k <= b) }'; then
                printf '  %-34s %8s  %s\n' "$_label" "skip" "needs $(awk -v w="$W_GB" -v k="$_kvgb" 'BEGIN{printf "%.1f", w+k}')G, budget ${BUDGET_AVAIL}G"
                return 0
            fi
        fi

        BENCH_PORT=$((BONSAI_PORT + 203))
        BENCH_LOG="$STATE_DIR/assess-tune.log"
        # Three runs, median taken. A single run is easily depressed by anything
        # else touching the GPU, and that was enough to flip a close ranking.
        _runs=""
        for _rep in 1 2 3; do
            # shellcheck disable=SC2086
            _one="$(bench_tps "$TUNE_PATH" "$BONSAI_NGL" "$CONTEXT" "$_kv" "$TUNE_TOKENS" $_extra || true)"
            _runs="${_runs}${_one}
"
        done
        _tps="$(printf '%s' "$_runs" | grep -v '^[[:space:]]*$' | sort -g | awk '{ v[NR] = $1 } END { if (NR == 0) exit 1; print v[int((NR + 1) / 2)] }')"

        if [ -z "$_tps" ]; then
            printf '  %-34s %8s  failed\n' "$_label" "-"
            explain_bench_failure "$BENCH_LOG"
            return 0
        fi
        printf '  %-34s %6s tok/s\n' "$_label" "$_tps"
        printf '%s\t%s\t%s\t%s\n' "$_tps" "$_label" "$_kv" "$_env" >> "$_results"
        coverage_set kv "$_kv"
        coverage_set backend "${BACKEND:-unknown}"
        coverage_set context "$CONTEXT"
        case "$_label" in
            *"n-max 1"|*"n-max 2") coverage_set spec "draft-mtp" ;;
            *ubatch*)              coverage_set ubatch "$(printf '%s' "$_label" | grep -oE '[0-9]+$' || echo 512)" ;;
        esac
    }

    printf '  %-34s %12s\n' "configuration" "result"
    printf '  %s\n' "----------------------------------------------"

    # The default first, so every other row has something to be compared to.
    run_variant "q8_0 KV, ubatch 512 (default)" "q8_0" "--ubatch-size 512" \
        "BONSAI_KV_TYPE=q8_0"
    run_variant "q4_0 KV, ubatch 512" "q4_0" "--ubatch-size 512" \
        "BONSAI_KV_TYPE=q4_0"
    run_variant "f16 KV, ubatch 512" "f16" "--ubatch-size 512" \
        "BONSAI_KV_TYPE=f16"
    run_variant "q8_0 KV, ubatch 256" "q8_0" "--ubatch-size 256" \
        "BONSAI_KV_TYPE=q8_0 BONSAI_EXTRA_ARGS=\"--ubatch-size 256\""
    run_variant "q8_0 KV, ubatch 1024" "q8_0" "--ubatch-size 1024" \
        "BONSAI_KV_TYPE=q8_0 BONSAI_EXTRA_ARGS=\"--ubatch-size 1024\""

    # An MTP model carries its own draft head. The best window depends on the
    # backend: on Vulkan n-max 2 measured fastest, on ROCm n-max 1 did, so both
    # are offered and the fastest wins.
    case "$(basename "$TUNE_PATH")" in
        *mtp*)
            run_variant "draft-mtp n-max 1" "$KV_TYPE" \
                "--ubatch-size 512 --spec-type draft-mtp --spec-draft-n-max 1" \
                "BONSAI_SPEC_TYPE=draft-mtp"
            run_variant "draft-mtp n-max 2" "$KV_TYPE" \
                "--ubatch-size 512 --spec-type draft-mtp --spec-draft-n-max 2" \
                "BONSAI_SPEC_TYPE=draft-mtp BONSAI_SPEC_DRAFT_N_MAX=2"
            ;;
    esac

    echo ""
    if [ ! -s "$_results" ]; then
        warn "Nothing measured. Check .state/assess-tune.log"
        echo ""
        exit 0
    fi

    _base="$(awk -F'\t' '$2 ~ /default/ { print $1; exit }' "$_results")"
    _best="$(sort -rn "$_results" | head -1)"

    _btps="$(printf '%s' "$_best" | cut -f1)"
    _blabel="$(printf '%s' "$_best" | cut -f2)"
    _benv="$(printf '%s' "$_best" | cut -f4)"

    printf '  %-38s %8s %9s  %s\n' "fastest first" "tok/s" "vs now" "verdict"
    printf '  %s\n' "----------------------------------------------------------------------"
    sort -rn "$_results" | while IFS=$'\t' read -r _t _l _k _e; do
        _rel=""
        _verdict=""
        if [ -n "$_base" ]; then
            _rel="$(awk -v a="$_t" -v b="$_base" 'BEGIN { printf "%.2fx", (b > 0 ? a/b : 1) }')"
            if awk -v a="$_t" -v b="$_base" 'BEGIN { exit !(a > b * 1.03) }'; then
                _verdict="use this"
            elif awk -v a="$_t" -v b="$_base" 'BEGIN { exit !(a < b * 0.97) }'; then
                _verdict="slower, do not use"
            else
                _verdict="same as now"
            fi
        fi
        printf '  %-38s %8s %9s  %s\n' "$_l" "$_t" "$_rel" "$_verdict"
    done

    echo ""
    dim "  'vs now' compares against the current default. Below 1.00x means that"
    dim "  option is slower, so nothing is lost by leaving it alone."
    echo ""
    if [ "$_blabel" = "q8_0 KV, ubatch 512 (default)" ]; then
        info "The current default is already the fastest of these on this machine."
    else
        info "Fastest: $_blabel at ${_btps} tok/s."
    fi

    # Only call it a win if it clears the run-to-run noise we see in practice.
    if [ -n "$_base" ] && [ "$_blabel" != "q8_0 KV, ubatch 512 (default)" ]; then
        if awk -v a="$_btps" -v b="$_base" 'BEGIN { exit !(a > b * 1.03) }'; then
            awk -v a="$_btps" -v b="$_base" \
                'BEGIN { printf "  That is %.0f%% faster than the default.\n", (a/b - 1) * 100 }' >&2
            echo ""
            info "Serve it with:"
            dim "    $_benv ./scripts/start-server.sh"
        else
            dim "  The gap is within run-to-run noise, so the defaults are fine."
        fi
    fi
    echo ""
    exit 0
fi

# ---------------------------------------------------------------------------
# Offload sweep: split the model across VRAM and RAM
# ---------------------------------------------------------------------------

if [ "$SWEEP" = 1 ]; then
    # Pick the model: an explicit one, the only measured one, or ask.
    if [ -n "$SWEEP_MODEL" ]; then
        SWEEP_PATH="$SWEEP_MODEL"
        [ -f "$SWEEP_PATH" ] || die "No such model: $SWEEP_PATH"
    else
        _measured=()
        for _m in "${MODELS[@]}"; do
            kv_measured "$_m" && _measured+=("$_m")
        done
        case "${#_measured[@]}" in
            0) die "No measured models. Run first: ./scripts/assess.sh --measure" ;;
            1) SWEEP_PATH="${_measured[0]}" ;;
            *)
                step "Which model?"
                _i=0
                for _m in "${_measured[@]}"; do
                    _i=$((_i + 1))
                    printf '  %2d. %s\n' "$_i" "$(basename "$_m")" >&2
                done
                _pick="$(ask "Model number" "1")"
                case "$_pick" in ''|*[!0-9]*) die "Expected a number, got '$_pick'." ;; esac
                SWEEP_PATH="${_measured[$((_pick - 1))]}"
                [ -f "$SWEEP_PATH" ] || die "No model for selection '$_pick'."
                ;;
        esac
    fi

    N_LAYER="$(kv_layers_get "$SWEEP_PATH" || true)"
    [ -n "$N_LAYER" ] || die "No layer count for $(basename "$SWEEP_PATH").
       Re-measure it: ./scripts/assess.sh --measure"

    W_GB="$(awk -v b="$(model_size_bytes "$SWEEP_PATH")" 'BEGIN { printf "%.2f", b/1073741824 }')"
    KV_MIB="$(kv_mib "$SWEEP_PATH" "$CONTEXT" "$KV_TYPE" || true)"
    [ -n "$KV_MIB" ] || die "No KV cost for $(basename "$SWEEP_PATH"). Re-measure it."
    KV_GB="$(awk -v m="$KV_MIB" 'BEGIN { printf "%.2f", m/1024 }')"

    # How many layers fit in the budget once the cache has taken its share.
    MAX_FIT="$(awk -v budget="$BUDGET_AVAIL" -v kv="$KV_GB" -v w="$W_GB" -v n="$N_LAYER" \
        'BEGIN { p = w / n; if (p <= 0) { print n; exit } f = int((budget - kv) / p); if (f < 0) f = 0; if (f > n) f = n; print f }')"

    if [ -n "$SWEEP_LEVELS" ]; then
        LEVELS="$(printf '%s' "$SWEEP_LEVELS" | tr ',' ' ')"
    else
        LEVELS="$(awk -v m="$MAX_FIT" 'BEGIN {
            a = int(m/3); b = int(2*m/3)
            printf "0 %d %d %d", a, b, m
        }')"
    fi
    # Deduplicate and order, so a small model does not bench the same split twice.
    # Word splitting is intended here: the levels are a space separated list
    # that needs one per line for sort.
    # shellcheck disable=SC2086
    LEVELS="$(printf '%s\n' $LEVELS | sort -n -u | tr '\n' ' ')"

    step "Offload sweep"
    info "Model    : $(basename "$SWEEP_PATH")"
    info "Layers   : $N_LAYER   weights ${W_GB} GB   KV at $CONTEXT/$KV_TYPE ${KV_GB} GB"
    info "Budget   : ${BUDGET_AVAIL} GB of $BUDGET_LABEL"
    if [ "$MAX_FIT" -lt "$N_LAYER" ]; then
        warn "Only $MAX_FIT of $N_LAYER layers fit; the rest run from system RAM."
    else
        info "The whole model fits, so the sweep shows the curve up to full offload."
    fi
    dim "  ${SWEEP_TOKENS} tokens per measurement, $(printf '%s' "$LEVELS" | wc -w | tr -d ' ') configurations."
    echo ""

    _other="$(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null | head -1 || true)"
    if [ -n "$_other" ]; then
        warn "Something is on port $BONSAI_PORT (pid $_other); it may hold memory."
        dim "  Benchmarks need free memory. Stop it for a clean sweep."
    fi

    printf '  %8s %9s %9s %10s %10s\n' "on GPU" "VRAM" "RAM" "tok/s" "vs all-CPU"
    printf '  %s\n' "--------------------------------------------------------"

    BASE_TPS=""
    BEST_NGL=""
    BEST_TPS=""
    for _ngl in $LEVELS; do
        BENCH_PORT=$((BONSAI_PORT + 202))
        BENCH_LOG="$STATE_DIR/assess-sweep-$_ngl.log"

        read -r _vram _ram <<<"$(kv_placement "$N_LAYER" "$_ngl" "$W_GB" "$KV_GB")"

        _tps="$(bench_tps "$SWEEP_PATH" "$_ngl" "$CONTEXT" "$KV_TYPE" "$SWEEP_TOKENS" || true)"

        if [ -z "$_tps" ]; then
            printf '  %8s %8sG %8sG %10s %10s\n' "$_ngl" "$_vram" "$_ram" "-" "-"
            explain_bench_failure "$BENCH_LOG"
            continue
        fi

        if [ "$_ngl" = "0" ]; then BASE_TPS="$_tps"; fi
        _rel=""
        if [ -n "$BASE_TPS" ]; then
            _rel="$(awk -v a="$_tps" -v b="$BASE_TPS" 'BEGIN { printf "%.1fx", (b > 0 ? a/b : 1) }')"
        fi

        printf '  %8s %8sG %8sG %10s %10s\n' "$_ngl" "$_vram" "$_ram" "$_tps" "$_rel"

        if [ -z "$BEST_TPS" ] || awk -v a="$_tps" -v b="$BEST_TPS" 'BEGIN { exit !(a > b) }'; then
            BEST_TPS="$_tps"; BEST_NGL="$_ngl"
        fi
        speed_set "$SWEEP_PATH" "$CONTEXT" "$KV_TYPE" "$_tps"
        coverage_set ngl "$_ngl"
    done
    coverage_set context "$CONTEXT"

    echo ""
    if [ -n "$BEST_NGL" ]; then
        if [ "$BEST_NGL" = "$N_LAYER" ]; then
            info "Best: all $N_LAYER layers on the GPU, ${BEST_TPS} tok/s."
        elif [ "$BEST_NGL" = "0" ]; then
            info "Best: everything on the CPU, ${BEST_TPS} tok/s."
            dim "  Offloading did not help here; memory bandwidth is the limit."
        else
            info "Best: $BEST_NGL of $N_LAYER layers on the GPU, ${BEST_TPS} tok/s."
        fi
        if [ -n "$BASE_TPS" ] && [ "$BEST_NGL" != "0" ]; then
            awk -v a="$BEST_TPS" -v b="$BASE_TPS" \
                'BEGIN { if (b > 0) printf "  That is %.1fx the all-CPU rate (%.1f tok/s).\n", a/b, b }' >&2
        fi
        echo ""
        dim "  Serve it with:"
        dim "    BONSAI_NGL=$BEST_NGL ./scripts/start-server.sh"
    else
        warn "No configuration produced a measurement."
        dim "  Something is holding memory, or the model is too large for this machine."
    fi
    echo ""
    exit 0
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
