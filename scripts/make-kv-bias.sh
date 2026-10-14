#!/usr/bin/env bash
# make-kv-bias.sh - build a K-cache mean-centering bias file for --kv-mean-center.
#
# --kv-mean-center improves the quality of a q4_0 K cache by subtracting a
# per-(head, channel) bias from K before quantization. It needs a small bias
# file computed by running calibration text through the model.
#
# The bias lives in whatever basis the calibration used. This fork rotates the K
# cache before quantizing it, and the loader refuses a bias whose basis does not
# match, so calibration MUST use the same cache type you will serve with. This
# script always calibrates with -ctk q4_0 for that reason.
#
# Usage:
#   ./scripts/make-kv-bias.sh                  calibrate the only model present
#   ./scripts/make-kv-bias.sh --model <path>   calibrate a specific GGUF
#   ./scripts/make-kv-bias.sh --force          redo an existing bias file
#
# Then serve it:
#   KILN_KV_TYPE_K=q4_0 KILN_KV_TYPE_V=q8_0 \
#   KILN_EXTRA_ARGS="--kv-mean-center <bias file>" ./scripts/start-server.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MODEL=""
FORCE=0
TOKENS="${KILN_CALIB_TOKENS:-400}"

while [ $# -gt 0 ]; do
    case "$1" in
        --model)  MODEL="${2:-}"; shift ;;
        --force)  FORCE=1 ;;
        --tokens) TOKENS="${2:-400}"; shift ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

if detect_is_stale; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

SERVER_BIN="$(llama_server_bin)" || die "No llama-server installed. Run: ./scripts/fetch-binary.sh"
BIN_DIR_ACTUAL="$(dirname "$SERVER_BIN")"
CALIB_BIN="$BIN_DIR_ACTUAL/llama-kv-mean-center"
[ -x "$CALIB_BIN" ] || die "llama-kv-mean-center not found next to llama-server.
       The pinned prebuilt ships it; re-fetch with: ./scripts/fetch-binary.sh --force"

# ---------------------------------------------------------------------------
# Pick the model
# ---------------------------------------------------------------------------

if [ -z "$MODEL" ]; then
    mapfile -t _cands < <(find "$MODELS_DIR" -name '*.gguf' -not -name '*mmproj*' 2>/dev/null | sort)
    case "${#_cands[@]}" in
        0) die "No models in $MODELS_DIR. Run: ./scripts/get-models.sh" ;;
        1) MODEL="${_cands[0]}" ;;
        *)
            step "Which model should the bias be calibrated for?"
            _i=0
            for _c in "${_cands[@]}"; do
                _i=$((_i + 1))
                printf '  %2d. %s\n' "$_i" "$(basename "$_c")" >&2
            done
            _pick="$(ask "Model number" "1")"
            case "$_pick" in ''|*[!0-9]*) die "Expected a number, got '$_pick'." ;; esac
            MODEL="${_cands[$((_pick - 1))]}"
            [ -f "$MODEL" ] || die "No model for selection '$_pick'."
            ;;
    esac
fi
[ -f "$MODEL" ] || die "Model not found: $MODEL"

STEM="$(basename "${MODEL%.gguf}")"
BIAS="${KILN_KV_BIAS_OUT:-$MODELS_DIR/kv-mean-center-$STEM.gguf}"
CORPUS="$STATE_DIR/calib-corpus-$STEM.txt"

if [ -f "$BIAS" ] && [ "$FORCE" = 0 ]; then
    info "Bias file already exists: $BIAS"
    dim "  Re-run with --force to rebuild it."
    exit 0
fi

step "Calibrating a K-cache bias"
info "Model : $(basename "$MODEL")"
info "Output: $BIAS"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# 1. Calibration corpus
# ---------------------------------------------------------------------------

# Seed prompts spanning the kinds of text a chat model actually sees. The
# per-channel K mean is dominated by model-intrinsic structure rather than
# corpus content, so a modest self-generated corpus is sufficient.
SEEDS=(
    "Explain how a hash map works internally, including collision handling."
    "Write a short story about a lighthouse keeper who finds a message in a bottle."
    "Describe the water cycle for a middle-school science class."
    "Write a Python function that merges two sorted lists, with comments."
    "Summarize the causes and consequences of the Industrial Revolution."
    "Explain the difference between TCP and UDP and when to use each."
    "Write a dialogue between a customer and a barista ordering an unusual drink."
    "Describe how photosynthesis converts light energy into chemical energy."
    "Give step-by-step instructions for making fresh pasta from scratch."
    "Explain what a stock index is and how index funds work."
    "Write a product review for a fictional pair of noise-cancelling headphones."
    "Explain how vaccines train the immune system."
    "Describe a day in the life of a marine biologist studying coral reefs."
    "Explain the doppler effect and give everyday examples."
    "Explain how compilers optimize loops, mentioning unrolling and vectorization."
    "Write a troubleshooting guide for a home Wi-Fi connection that keeps dropping."
    "Explain probability with coin flips and dice, including expected value."
    "Write a scene where two old friends meet by chance at a train station."
)

if [ -f "$CORPUS" ] && [ "$FORCE" = 0 ]; then
    info "Reusing existing corpus: $CORPUS"
else
    step "Generating a calibration corpus from the model"
    dim "  This starts a temporary server and asks the model ${#SEEDS[@]} questions."

    _port=$((KILN_PORT + 100))
    _log="$STATE_DIR/calib-server.log"
    "$SERVER_BIN" -m "$MODEL" --port "$_port" --ctx-size 4096 \
        --n-gpu-layers "$KILN_NGL" --no-warmup --jinja >"$_log" 2>&1 &
    _srv_pid=$!
    trap 'kill "$_srv_pid" 2>/dev/null || true' EXIT

    for _ in $(seq 1 90); do
        curl -sf "http://127.0.0.1:$_port/health" >/dev/null 2>&1 && break
        kill -0 "$_srv_pid" 2>/dev/null || die "Calibration server died. See $_log"
        sleep 1
    done
    curl -sf "http://127.0.0.1:$_port/health" >/dev/null 2>&1 ||
        die "Calibration server did not come up. See $_log"

    : > "$CORPUS"
    _n=0
    for _seed in "${SEEDS[@]}"; do
        _n=$((_n + 1))
        _resp="$(curl -s "http://127.0.0.1:$_port/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d "$(printf '{"messages":[{"role":"user","content":%s}],"max_tokens":%s,"temperature":0.7,"chat_template_kwargs":{"enable_thinking":false}}' \
                "$(printf '%s' "$_seed" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
                "$TOKENS")" 2>/dev/null || true)"
        _text="$(printf '%s' "$_resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["message"]["content"])
except Exception:
    pass
' 2>/dev/null || true)"
        printf '%s\n\n' "$_text" >> "$CORPUS"
        printf '  [%2d/%2d] %s\n' "$_n" "${#SEEDS[@]}" "${_seed:0:60}" >&2
    done

    kill "$_srv_pid" 2>/dev/null || true
    wait "$_srv_pid" 2>/dev/null || true
    trap - EXIT

    _bytes="$(stat -c '%s' "$CORPUS" 2>/dev/null || echo 0)"
    [ "$_bytes" -gt 2000 ] || die "Corpus is only $_bytes bytes; the model produced almost nothing.
       Check $_log"
    _ratio="$(gzip -c "$CORPUS" | wc -c)"
    _ratio="$(awk -v a="$_bytes" -v b="$_ratio" 'BEGIN { printf "%.2f", a/b }')"
    info "Corpus: $(human_size "$_bytes"), gzip ratio $_ratio"
    awk -v r="$_ratio" 'BEGIN { exit (r < 1.5) ? 1 : 0 }' ||
        warn "Low gzip ratio ($_ratio) - the corpus may be degenerate. Inspect $CORPUS"
fi

# ---------------------------------------------------------------------------
# 2. Compute the bias
# ---------------------------------------------------------------------------

step "Computing the bias (this is quick)"

# -ctk q4_0 is not optional: it makes the calibration run use the same rotated
# basis that inference will use, and the loader rejects a mismatch.
"$CALIB_BIN" -m "$MODEL" -f "$CORPUS" -o "$BIAS" -ctk q4_0 -ngl "$KILN_NGL"

[ -f "$BIAS" ] || die "Calibration finished but $BIAS was not written."

step "Done"
info "Bias file: $BIAS  ($(human_size "$(stat -c '%s' "$BIAS")"))"
echo ""
printf '  Serve it with a q4_0 K cache (2.46x smaller than f16, best measured quality):\n\n'
printf '    %sKILN_KV_TYPE_K=q4_0 KILN_KV_TYPE_V=q8_0 \\%s\n' "$C_CYAN" "$C_RESET"
printf '    %sKILN_EXTRA_ARGS="--kv-mean-center %s" \\%s\n' "$C_CYAN" "$BIAS" "$C_RESET"
printf '    %s./scripts/start-server.sh%s\n\n' "$C_CYAN" "$C_RESET"
dim "  The bias is only valid for this model and this K cache type."
dim "  Rebuild it if you change the model or the K cache type."
