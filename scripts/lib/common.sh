#!/usr/bin/env bash
# Shared helpers for the Ikaros Bonsai server scripts.
# Source this file: . "$(dirname "$0")/lib/common.sh"

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

# Resolve the repository root from this file's location (scripts/lib/common.sh).
_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_common_dir/../.." && pwd)"
unset _common_dir

# Record which settings the caller supplied before any default is applied below.
# Without this, load_settings cannot tell a deliberate override from a default,
# and a one-off `BONSAI_CTX=... ./scripts/start-server.sh` would be ignored.
_BONSAI_SETTINGS="BONSAI_PORT BONSAI_CTX BONSAI_NGL BONSAI_THREADS BONSAI_KV_TYPE BONSAI_KV_TYPE_K BONSAI_KV_TYPE_V BONSAI_MODELS_DIR BONSAI_DRAFT_MODEL BONSAI_SPEC_TYPE BONSAI_SPEC_DRAFT_N_MAX"
_BONSAI_FROM_ENV=""
for _v in $_BONSAI_SETTINGS; do
    if [ -n "${!_v+set}" ]; then _BONSAI_FROM_ENV="$_BONSAI_FROM_ENV $_v"; fi
done

STATE_DIR="${BONSAI_STATE_DIR:-$REPO_ROOT/.state}"
BIN_DIR="$REPO_ROOT/bin"
# Exported so the per-script globals stay visible to shellcheck and to any
# child process that needs them.
MODELS_DIR="${BONSAI_MODELS_DIR:-$REPO_ROOT/models}"
export MODELS_DIR STATE_DIR BIN_DIR

# Pinned upstream release. Bump PRISM_RELEASE and PRISM_COMMIT together.
PRISM_RELEASE="${PRISM_RELEASE:-prism-b10772-e8fd209}"
PRISM_COMMIT="${PRISM_COMMIT:-e8fd209}"
# git cannot fetch an abbreviated sha, so the source build needs the full one
PRISM_COMMIT_FULL="${PRISM_COMMIT_FULL:-e8fd209c975c80aa7fb36a8423571ff3b1b7e955}"
PRISM_REPO="${PRISM_REPO:-PrismML-Eng/llama.cpp}"

# Speculative decoding. "--spec-type draft-mtp" uses the MTP head inside an
# *-mtp.gguf file, so no separate drafter is needed. Measured on an RX 9060 XT
# with the 27B lean MTP file: n-max 1 gives +6 to +13%, and n-max 2 is WORSE
# than baseline (acceptance falls, and the stock small-batch mat-vec makes the
# wider window cost more than it saves). See docs/HARDWARE.md.
BONSAI_SPEC_TYPE="${BONSAI_SPEC_TYPE:-}"
BONSAI_SPEC_DRAFT_N_MAX="${BONSAI_SPEC_DRAFT_N_MAX:-1}"

# Optional draft model for speculative decoding. Must share the target's
# vocabulary; the PrismML repos ship purpose-trained drafters named *-dspark-*.
# A smaller model from the same family does NOT work: measured at no gain,
# because its predictions are rejected too often. See docs/HARDWARE.md.
BONSAI_DRAFT_MODEL="${BONSAI_DRAFT_MODEL:-}"

# Server defaults. Hermes requires a context window of at least 64000 tokens.
BONSAI_PORT="${BONSAI_PORT:-8081}"
BONSAI_CTX="${BONSAI_CTX:-65536}"
BONSAI_NGL="${BONSAI_NGL:-99}"
# Host threads for the CPU scheduler. Defaults to all logical cores. Under full
# GPU offload this is measured as noise; on CPU-only and partial-offload builds
# it is often the largest lever, so it is a setting rather than a constant.
BONSAI_THREADS="${BONSAI_THREADS:-$(nproc 2>/dev/null || echo 4)}"

# KV cache quantization. At the 65536 context Hermes requires, the cache is the
# single biggest consumer of VRAM and q8_0 halves it at negligible quality cost,
# so it is the default. Set BONSAI_KV_TYPE=f16 to turn it off, or q4_0/iq4_nl
# for roughly a quarter of the f16 size.
#
# BONSAI_KV_TYPE sets both halves; BONSAI_KV_TYPE_K / _V override one half.
# They stay empty here so that --kv-type on the command line still composes.
# Always resolve through kv_type_k / kv_type_v, never the raw variables.
# "auto" picks f16 when the largest installed model still fits with it, and
# q8_0 otherwise. Resolved at start time, so it adapts as models are added.
BONSAI_KV_TYPE="${BONSAI_KV_TYPE:-auto}"
BONSAI_KV_TYPE_K="${BONSAI_KV_TYPE_K:-}"
BONSAI_KV_TYPE_V="${BONSAI_KV_TYPE_V:-}"

# Types the pinned build accepts for --cache-type-k and --cache-type-v.
# tests/run.sh asserts this matches what the installed binary reports, so it
# cannot silently drift from the build.
KV_CACHE_TYPES="f32 f16 bf16 q8_0 q4_0 q4_1 iq4_nl q5_0 q5_1"

# kv_type_valid TYPE - succeed when TYPE is a KV cache type this build accepts.
kv_type_valid() {
    local _t
    for _t in $KV_CACHE_TYPES; do
        [ "$1" = "$_t" ] && return 0
    done
    return 1
}

# kv_type_k / kv_type_v - the resolved type for each half of the cache.
kv_type_k() { printf '%s' "${BONSAI_KV_TYPE_K:-$BONSAI_KV_TYPE}"; }
kv_type_v() { printf '%s' "${BONSAI_KV_TYPE_V:-$BONSAI_KV_TYPE}"; }

# kv_type_effective - print the KV type that will actually be applied, or "f16"
# when quantization is disabled on both halves.
kv_type_effective() {
    local _k _v
    _k="$(kv_type_k)"; _v="$(kv_type_v)"
    if [ "$_k" = "f16" ] && [ "$_v" = "f16" ]; then
        printf 'f16'
    elif [ "$_k" = "$_v" ]; then
        printf '%s' "$_k"
    else
        printf 'K=%s V=%s' "$_k" "$_v"
    fi
}

# ---------------------------------------------------------------------------
# Settings file
# ---------------------------------------------------------------------------

# A single editable file holding the settings, shared by the interactive
# launcher and the systemd unit. `./scripts/bonsai set` writes it, and the unit
# reads it through EnvironmentFile, so changing a setting never means
# reinstalling anything.
SETTINGS_FILE="$STATE_DIR/service.env"

# load_settings - apply the settings file. A value the caller set in the
# environment wins over the file, so a one-off override still works.
load_settings() {
    [ -f "$SETTINGS_FILE" ] || return 0
    local _line _key _val _skip
    while IFS= read -r _line; do
        case "$_line" in ''|'#'*) continue ;; esac
        _key="${_line%%=*}"
        _val="${_line#*=}"
        case "$_key" in BONSAI_*) ;; *) continue ;; esac
        _skip=0
        for _v in $_BONSAI_FROM_ENV; do
            [ "$_v" = "$_key" ] && _skip=1
        done
        [ "$_skip" = 1 ] && continue
        export "$_key=$_val"
    done < "$SETTINGS_FILE"
}

# ---------------------------------------------------------------------------
# Settings file helpers (used by `bonsai set` and `bonsai apply`)
# ---------------------------------------------------------------------------

# settings_set KEY VALUE - write one KEY=VALUE into the settings file,
# replacing any prior value for that key and preserving every other line.
settings_set() {
    mkdir -p "$STATE_DIR"
    local _k="$1" _v="$2" _tmp="${SETTINGS_FILE}.set"
    touch "$SETTINGS_FILE" 2>/dev/null || : > "$SETTINGS_FILE"
    grep -v "^${_k}=" "$SETTINGS_FILE" > "$_tmp" 2>/dev/null || : > "$_tmp"
    printf '%s=%s\n' "$_k" "$_v" >> "$_tmp"
    mv "$_tmp" "$SETTINGS_FILE"
}

# settings_unset KEY [KEY...] - remove these keys from the settings file.
settings_unset() {
    mkdir -p "$STATE_DIR"
    local _tmp="${SETTINGS_FILE}.unset" _k
    touch "$SETTINGS_FILE" 2>/dev/null || : > "$SETTINGS_FILE"
    cp "$SETTINGS_FILE" "$_tmp"
    for _k in "$@"; do
        grep -v "^${_k}=" "$_tmp" > "$_tmp.2" && mv "$_tmp.2" "$_tmp" || : > "$_tmp"
    done
    mv "$_tmp" "$SETTINGS_FILE"
}

# ---------------------------------------------------------------------------
# Tune result persistence
# ---------------------------------------------------------------------------

TUNE_BEST_FILE="$STATE_DIR/tune-best.env"

# write_tune_best ENVSTRING BACKEND - record the winning config of a
# `bonsai tune` run. ENVSTRING is the variant's KEY=VALUE settings (spec,
# n-max, ubatch, kv type). Backended-tagged so a later run on a different GPU
# does not apply a config measured under another backend. This is a record,
# not an automatic apply; use `apply_tune_best` (or `./scripts/bonsai apply`).
write_tune_best() {
    local _env="$1" _backend="$2" _k
    mkdir -p "$STATE_DIR"
    {
        printf '# Winner of the last `bonsai tune` run. Backended-tagged.\n'
        printf '# Apply safely with:  ./scripts/bonsai apply\n'
        printf 'BONSAI_TUNED_BACKEND=%s\n' "$_backend"
        printf 'BONSAI_TUNED_AT=%s\n' "$(date -Iseconds 2>/dev/null || date 2>/dev/null || echo now)"
        # Emit each KEY=VALUE the winner used. Start from a clean slate so
        # inherited ambient values (e.g. the BONSAI_THREADS default) are not
        # recorded as part of the winner. Then parse ENVSTRING with eval so
        # quoted values like BONSAI_EXTRA_ARGS="--ubatch-size 256" come through.
        ( unset BONSAI_KV_TYPE BONSAI_KV_TYPE_K BONSAI_KV_TYPE_V \
                BONSAI_SPEC_TYPE BONSAI_SPEC_DRAFT_N_MAX BONSAI_NGL \
                BONSAI_EXTRA_ARGS BONSAI_THREADS 2>/dev/null || true
            eval "$_env" 2>/dev/null || true
            for _k in BONSAI_KV_TYPE BONSAI_KV_TYPE_K BONSAI_KV_TYPE_V \
                      BONSAI_SPEC_TYPE BONSAI_SPEC_DRAFT_N_MAX BONSAI_NGL \
                      BONSAI_EXTRA_ARGS BONSAI_THREADS; do
                [ -n "${!_k}" ] && printf '%s=%s\n' "$_k" "${!_k}"
            done
            : # ensure the subshell returns success even if the last key was unset
        )
    } > "$TUNE_BEST_FILE"
}

# apply_tune_best - project the recorded winner onto the live settings file.
# Only machine-level knobs safe in router mode are persisted: BONSAI_THREADS
# and BONSAI_EXTRA_ARGS (ubatch). The KV cache type is left to `auto` (it is
# model-size-dependent and must re-decide per model). Speculative-decode
# settings are applied only when the backend matches the one the winner was
# measured under - draft efficiency is backend-specific, and a cross-backend
# apply would be slower, not faster.
apply_tune_best() {
    [ -f "$TUNE_BEST_FILE" ] || { warn "No tune result recorded. Run: ./scripts/bonsai tune"; return 1; }
    [ -n "${BACKEND:-}" ]     || { warn "No backend loaded. Run: ./scripts/detect.sh"; return 1; }
    # Clear ambient defaults first, so only the winner's recorded keys survive
    # - e.g. BONSAI_THREADS is always set by common.sh, but a winner that did
    # not measure threads must not drag the default into the settings file.
    unset BONSAI_KV_TYPE BONSAI_KV_TYPE_K BONSAI_KV_TYPE_V \
          BONSAI_SPEC_TYPE BONSAI_SPEC_DRAFT_N_MAX BONSAI_NGL \
          BONSAI_EXTRA_ARGS BONSAI_THREADS
    # shellcheck source=/dev/null
    . "$TUNE_BEST_FILE"
    local _tuned_backend="${BONSAI_TUNED_BACKEND:-}" _applied=0 _skip_spec=0
    if [ -n "$_tuned_backend" ] && [ "$_tuned_backend" != "$BACKEND" ]; then
        _skip_spec=1
        warn "Tune result was measured on backend '$_tuned_backend' but this machine is '$BACKEND'."
        warn "Speculative-decode settings were skipped; applying one of those would be slower here."
    fi
    # Safe, machine-level knobs. The offload split (NGL) and thread count are
    # machine-specific and backend-agnostic in the same way threads are, so they
    # are applied even on a cross-backend apply (only the spec-type is gated).
    [ -n "${BONSAI_THREADS:-}" ]     && { settings_set BONSAI_THREADS "$BONSAI_THREADS"; _applied=1; }
    [ -n "${BONSAI_EXTRA_ARGS:-}" ]  && { settings_set BONSAI_EXTRA_ARGS "$BONSAI_EXTRA_ARGS"; _applied=1; }
    [ -n "${BONSAI_NGL:-}" ]         && { settings_set BONSAI_NGL "$BONSAI_NGL"; _applied=1; }
    # Speculative settings: backend-specific. Only apply when the backend
    # matches the one the winner was measured under; otherwise drop any stale
    # value so a config tuned for Vulkan, say, does not end up running on ROCm
    # (where draft-n-max 2 is slower than baseline).
    if [ "$_skip_spec" = 1 ]; then
        if [ -n "${BONSAI_SPEC_TYPE:-}" ] || [ -n "${BONSAI_SPEC_DRAFT_N_MAX:-}" ]; then
            settings_unset BONSAI_SPEC_TYPE BONSAI_SPEC_DRAFT_N_MAX
            _did_specenv=""
            [ -n "${BONSAI_SPEC_TYPE:-}" ] && _did_specenv="BONSAI_SPEC_TYPE=${BONSAI_SPEC_TYPE}"
            [ -n "${BONSAI_SPEC_DRAFT_N_MAX:-}" ] && _did_specenv="${_did_specenv:+$_did_specenv }BONSAI_SPEC_DRAFT_N_MAX=${BONSAI_SPEC_DRAFT_N_MAX}"
            dim "  To use it on this backend anyway (MTP models only), run:"
            dim "    $_did_specenv ./scripts/start-server.sh"
        fi
    else
        [ -n "${BONSAI_SPEC_TYPE:-}" ] && { settings_set BONSAI_SPEC_TYPE "$BONSAI_SPEC_TYPE"; _applied=1; }
        [ -n "${BONSAI_SPEC_DRAFT_N_MAX:-}" ] && { settings_set BONSAI_SPEC_DRAFT_N_MAX "$BONSAI_SPEC_DRAFT_N_MAX"; _applied=1; }
    fi
    if [ "$_applied" = 0 ]; then
        # Winner was the default; make sure no stale tuned values linger.
        settings_unset BONSAI_THREADS BONSAI_EXTRA_ARGS BONSAI_NGL BONSAI_SPEC_TYPE BONSAI_SPEC_DRAFT_N_MAX
        info "Tune winner was the default config; nothing to apply."
    else
        info "Applied the tune winner to $SETTINGS_FILE."
        dim "  Restart to apply: ./scripts/bonsai restart"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'
    C_CYAN='\033[36m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''; C_RESET=''
fi

# All diagnostics go to stderr, so stdout stays clean for machine-readable
# output such as detect.sh --json.
info() { printf "${C_GREEN}[OK]${C_RESET}   %s\n" "$*" >&2; }
warn() { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*" >&2; }
err()  { printf "${C_RED}[ERR]${C_RESET}  %s\n" "$*" >&2; }
step() { printf "\n${C_CYAN}==> %s${C_RESET}\n" "$*" >&2; }
dim()  { printf "${C_DIM}%s${C_RESET}\n" "$*" >&2; }

die() { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

# tty_available - succeed when /dev/tty can actually be opened.
tty_available() { { : </dev/tty; } 2>/dev/null; }

# ask PROMPT [DEFAULT] - read a line, print only the answer on stdout.
# The prompt goes to stderr so callers can capture the value with $(...).
# Falls back to DEFAULT when no terminal is attached.
ask() {
    local _prompt="$1" _default="${2:-}"
    # REPLY is deliberately global: it is the documented output of this function.
    if [ -n "$_default" ]; then
        printf "%s [%s]: " "$_prompt" "$_default" >&2
    else
        printf "%s: " "$_prompt" >&2
    fi

    REPLY=""
    if tty_available; then
        read -r REPLY </dev/tty || REPLY=""
    elif [ -t 0 ]; then
        read -r REPLY || REPLY=""
    else
        printf "\n" >&2
    fi
    [ -z "$REPLY" ] && REPLY="$_default"
    printf '%s' "$REPLY"
}

# confirm PROMPT [y|n] - yes/no question. Defaults to no unless $2 is "y".
confirm() {
    local _prompt="$1" _default="${2:-n}"
    local _hint _reply
    if [ "$_default" = "y" ]; then _hint="Y/n"; else _hint="y/N"; fi
    printf "%s [%s]: " "$_prompt" "$_hint" >&2

    _reply=""
    if tty_available; then
        read -r _reply </dev/tty || _reply=""
    elif [ -t 0 ]; then
        read -r _reply || _reply=""
    else
        printf "\n" >&2
    fi
    [ -z "$_reply" ] && _reply="$_default"
    case "$_reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

# have_downloader - succeed if curl or wget is available.
have_downloader() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

# download URL DEST - resumable download, prints a short progress line.
download() {
    local _url="$1" _dest="$2"
    mkdir -p "$(dirname "$_dest")"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -C - -o "$_dest" "$_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -c -O "$_dest" "$_url"
    else
        die "Neither curl nor wget found. Install one and re-run."
    fi
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------

# version_ge A B - succeed when A >= B, comparing dotted numeric components.
version_ge() {
    local _a="$1" _b="$2" _ap _bp
    while [ -n "$_a" ] || [ -n "$_b" ]; do
        _ap="${_a%%.*}"; _bp="${_b%%.*}"
        if [ "$_a" = "$_ap" ]; then _a=""; else _a="${_a#*.}"; fi
        if [ "$_b" = "$_bp" ]; then _b=""; else _b="${_b#*.}"; fi
        [ -z "$_ap" ] && _ap=0
        [ -z "$_bp" ] && _bp=0
        [ "$_ap" -gt "$_bp" ] 2>/dev/null && return 0
        [ "$_ap" -lt "$_bp" ] 2>/dev/null && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# KV cache cost model
# ---------------------------------------------------------------------------

# Bits per cache element, derived from the formats themselves:
#   f16 / bf16        16
#   q8_0              8 bits plus a 16-bit scale per 32 elements = 8.5
#   q5_0 / q5_1       5 bits plus scale = 5.5
#   q4_0 / q4_1       4 bits plus scale = 4.5
#   iq4_nl            4 bits plus scale = 4.5
#   f32               32
#
# Verified exact against measured sizes on the 8B at 8192 cells: f16 1152 MiB,
# q8_0 612 (16/8.5 = 1.882), q4_0 324 (16/4.5 = 3.556). All four matched to
# 0.00%, so a model only needs measuring once, at f16.
kv_bits_per_element() {
    case "$1" in
        f32)              printf '32' ;;
        f16|bf16)         printf '16' ;;
        q8_0)             printf '8.5' ;;
        q5_0|q5_1)        printf '5.5' ;;
        q4_0|q4_1|iq4_nl) printf '4.5' ;;
        *) return 1 ;;
    esac
}

# KV_COST_CACHE - f16 bytes-per-cell per model, filled in by assess.sh --measure.
KV_COST_CACHE="$STATE_DIR/kv-costs.tsv"
# SPEED_CACHE - measured tokens per second per model, context and KV type.
SPEED_CACHE="$STATE_DIR/speeds.tsv"
COVERAGE_CACHE="$STATE_DIR/coverage.tsv"

# kv_cost_get MODEL - print the measured f16 bytes per cell, or nothing.
kv_cost_get() {
    [ -f "$KV_COST_CACHE" ] || return 1
    local _key
    _key="$(basename "$1")"
    awk -F'\t' -v k="$_key" '$1 == k { print $2; found=1 } END { exit !found }' "$KV_COST_CACHE"
}

# kv_cost_set MODEL BYTES_PER_CELL [LAYERS] - record a measurement, replacing
# any old one. The layer count lets the offload sweep choose sensible steps.
kv_cost_set() {
    mkdir -p "$STATE_DIR"
    local _key _tmp
    _key="$(basename "$1")"
    _tmp="$KV_COST_CACHE.tmp"
    if [ -f "$KV_COST_CACHE" ]; then
        awk -F'\t' -v k="$_key" '$1 != k' "$KV_COST_CACHE" > "$_tmp"
    else
        : > "$_tmp"
    fi
    printf '%s\t%s\t%s\n' "$_key" "$2" "${3:-}" >> "$_tmp"
    mv "$_tmp" "$KV_COST_CACHE"
}

# kv_layers_get MODEL - print the transformer layer count, or nothing.
kv_layers_get() {
    [ -f "$KV_COST_CACHE" ] || return 1
    local _key _v
    _key="$(basename "$1")"
    _v="$(awk -F'\t' -v k="$_key" '$1 == k { print $3; found=1 } END { exit !found }' "$KV_COST_CACHE")"
    [ -n "$_v" ] || return 1
    printf '%s' "$_v"
}

# kv_measured MODEL - succeed when the model has a complete measurement.
kv_measured() {
    kv_cost_get "$1" >/dev/null 2>&1 || return 1
    kv_layers_get "$1" >/dev/null 2>&1
}

# kv_mib MODEL CELLS TYPE - KV cache size in MiB for a measured model, or nothing.
kv_mib() {
    local _bpc _bits
    _bpc="$(kv_cost_get "$1")" || return 1
    _bits="$(kv_bits_per_element "$3")" || return 1
    awk -v bpc="$_bpc" -v cells="$2" -v bits="$_bits" \
        'BEGIN { printf "%.0f", bpc * (bits / 16) * cells / 1048576 }'
}

# coverage_set DIMENSION VALUE - record that a configuration dimension was explored.
#
# What improves a recommendation is not how many measurements were run but how
# many distinct dimensions were opened. Re-measuring inside one dimension
# (another ubatch, another cache type) buys a few percent at best, while a new
# dimension is where the step changes came from: the Vulkan backend was worth
# 15% and the MTP spec type 13%, against 3% for anything inside a dimension.
coverage_set() {
    mkdir -p "$STATE_DIR"
    local _tmp="$COVERAGE_CACHE.tmp"
    if [ -f "$COVERAGE_CACHE" ]; then
        # Already recorded: leave it in place so the report keeps a fixed order.
        if awk -F'\t' -v d="$1" -v v="$2" '$1 == d && $2 == v { f = 1 } END { exit !f }' \
                "$COVERAGE_CACHE"; then
            return 0
        fi
        cp "$COVERAGE_CACHE" "$_tmp"
    else
        : > "$_tmp"
    fi
    printf '%s\t%s\n' "$1" "$2" >> "$_tmp"
    mv "$_tmp" "$COVERAGE_CACHE"
}

# coverage_values DIMENSION - the values explored so far, one per line.
coverage_values() {
    [ -f "$COVERAGE_CACHE" ] || return 0
    awk -F'\t' -v d="$1" '$1 == d { print $2 }' "$COVERAGE_CACHE"
}

# speed_get MODEL CELLS TYPE [BACKEND] [RELEASE] - measured tokens per second.
#
# Keyed by backend and release as well as model and cache type. A speed measured
# on one backend does not transfer to another: the same model measured 36.1 on
# ROCm and 30.4 on Vulkan. Without the backend in the key, switching backends
# reported the old number as if it were current.
speed_get() {
    [ -f "$SPEED_CACHE" ] || return 1
    local _key _b _rel
    _key="$(basename "$1")"
    _b="${4:-${BACKEND:-unknown}}"
    _rel="${5:-${PRISM_RELEASE:-unknown}}"
    awk -F'\t' -v k="$_key" -v c="$2" -v t="$3" -v b="$_b" -v r="$_rel" \
        '$1 == k && $2 == c && $3 == t && $4 == b && $5 == r { print $6; found=1 } END { exit !found }' "$SPEED_CACHE"
}

# speed_set MODEL CELLS TYPE TPS [BACKEND] [RELEASE] - record a measurement.
speed_set() {
    mkdir -p "$STATE_DIR"
    local _key _tmp _b _rel
    _key="$(basename "$1")"
    _b="${5:-${BACKEND:-unknown}}"
    _rel="${6:-${PRISM_RELEASE:-unknown}}"
    _tmp="$SPEED_CACHE.tmp"
    if [ -f "$SPEED_CACHE" ]; then
        awk -F'\t' -v k="$_key" -v c="$2" -v t="$3" -v b="$_b" -v r="$_rel" \
            '!($1 == k && $2 == c && $3 == t && $4 == b && $5 == r)' "$SPEED_CACHE" > "$_tmp"
    else
        : > "$_tmp"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_key" "$2" "$3" "$_b" "$_rel" "$4" >> "$_tmp"
    mv "$_tmp" "$SPEED_CACHE"
}

# kv_placement LAYERS NGL WEIGHTS_GB KV_GB - print "VRAM RAM" in GB.
#
# The KV cache follows the layers. With -ngl 0 there are no GPU layers, so
# llama.cpp allocates a CPU KV buffer and the whole cache lives in RAM;
# offloading any layer moves the cache to VRAM. Verified against the loader:
# -ngl 0 logs "CPU KV buffer size", not a ROCm one.
kv_placement() {
    awk -v n="$1" -v g="$2" -v w="$3" -v kv="$4" 'BEGIN {
        vram = (g > 0) ? (n > 0 ? g/n*w : 0) + kv : 0
        ram  = (n > 0 ? (n-g)/n*w : 0) + ((g > 0) ? 0 : kv)
        printf "%.1f %.1f", vram, ram
    }'
}

# free_vram_gb - VRAM currently unused, in GB, or nothing when unknown.
# A benchmark needs free memory, not just total: another service holding VRAM
# squeezes allocations and produces numbers that do not reproduce.
free_vram_gb() {
    local _used _total
    _used="$(cat /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | head -1 || true)"
    _total="$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | head -1 || true)"
    [ -n "$_used" ] && [ -n "$_total" ] || return 1
    awk -v u="$_used" -v t="$_total" 'BEGIN { printf "%.1f", (t - u) / 1073741824 }'
}

# model_size_bytes MODEL - file size, or 0.
model_size_bytes() {
    stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0
}

# kv_type_auto - pick the fastest KV type that still fits the machine.
#
# f16 is measurably faster than q8_0 but needs 1.87x the cache, so it is only
# the right default when the largest installed model still fits with it. The
# largest model is the binding constraint: if it fits, everything does.
# kv_type_auto_choice - print "TYPE<TAB>REASON".
#
# The reason matters as much as the type. q8_0 comes out of four different
# situations and only one of them is a decision: no models, an unmeasured
# model, no budget, or a real fit. Reporting "fastest that fits" for the first
# three would claim a check that never ran, which is the same failure as a
# classifier labelling something it has never seen.
kv_type_auto_choice() {
    local _largest _w_gb _kv_gb _budget

    _largest="$(find "$MODELS_DIR" -name '*.gguf' \
        -not -name '*mmproj*' -not -name '*kv-mean-center-*' -not -name '*dspark*' \
        2>/dev/null | while IFS= read -r _f; do
            printf '%s\t%s\n' "$(model_size_bytes "$_f")" "$_f"
        done | sort -rn | head -1 | cut -f2)"

    [ -n "$_largest" ] || {
        printf 'q8_0\tno models installed, so the safe default'
        return 0
    }
    kv_measured "$_largest" 2>/dev/null || {
        printf 'q8_0\t%s is unmeasured, so the safe default; run --measure to decide' \
            "$(basename "$_largest")"
        return 0
    }

    _budget="$(kv_budget_gb)" || {
        printf 'q8_0\tno memory budget known, so the safe default'
        return 0
    }
    _w_gb="$(awk -v b="$(model_size_bytes "$_largest")" 'BEGIN { printf "%.2f", b/1073741824 }')"

    for _t in f16 q8_0; do
        _kv_gb="$(kv_mib "$_largest" "$BONSAI_CTX" "$_t" 2>/dev/null |
            awk '{ printf "%.2f", $1/1024 }')"
        [ -n "$_kv_gb" ] || continue
        if awk -v w="$_w_gb" -v k="$_kv_gb" -v b="$_budget" 'BEGIN { exit !(w + k <= b) }'; then
            if [ "$_t" = "f16" ]; then
                printf 'f16\tfastest type that fits the largest installed model'
            else
                printf 'q8_0\tf16 does not fit the largest installed model'
            fi
            return 0
        fi
    done
    printf 'q8_0\tneither f16 nor q8_0 fits the budget'
}

# kv_type_auto - the chosen type alone.
kv_type_auto() {
    kv_type_auto_choice | cut -f1
}

# kv_type_auto_reason - why that type was chosen.
kv_type_auto_reason() {
    kv_type_auto_choice | cut -f2
}

# kv_type_resolve - replace a configured "auto" with a concrete type, in place.
# Any entry point that needs the effective type must call this first, otherwise
# it sees the literal string "auto" and fails validation.
kv_type_resolve() {
    [ "${BONSAI_KV_TYPE:-}" = "auto" ] || return 0
    BONSAI_KV_TYPE="$(kv_type_auto)"
}

# kv_budget_gb - memory the models may use, with headroom held back.
kv_budget_gb() {
    local _gb _reserve
    if [ "${BACKEND:-cpu}" = "cpu" ]; then _gb="$RAM_GB"; _reserve=2
    else _gb="$VRAM_GB"; _reserve=1
    fi
    [ "${_gb:-0}" -gt 0 ] 2>/dev/null || return 1
    printf '%s' "$((_gb - _reserve))"
}

# ---------------------------------------------------------------------------
# Installed binary lookup
# ---------------------------------------------------------------------------

# llama_server_bin - print the path to the installed llama-server, or fail.
# Handles both archive layouts upstream has shipped: bin/llama-server and a
# flat llama-server next to its shared libraries.
llama_server_bin() {
    local _backend="${BACKEND:-}" _dir _c
    [ -n "$_backend" ] || return 1

    # A source build that carries the UI patch takes precedence over the
    # prebuilt, so running build-from-source.sh actually changes what runs.
    for _dir in "$BIN_DIR/$_backend-patched" "$BIN_DIR/$_backend"; do
        for _c in "$_dir/bin/llama-server" "$_dir/llama-server"; do
            if [ -x "$_c" ]; then printf '%s' "$_c"; return 0; fi
        done
    done
    return 1
}

# ---------------------------------------------------------------------------
# Detection cache
# ---------------------------------------------------------------------------

DETECT_ENV="$STATE_DIR/detect.env"

# load_detect - source the cached detection result, or fail with a clear hint.
load_detect() {
    [ -f "$DETECT_ENV" ] || die "No hardware detection found. Run: ./scripts/detect.sh"
    # shellcheck source=/dev/null
    . "$DETECT_ENV"
}

# detect_is_stale - succeed when the cache is missing or older than 24 hours.
detect_is_stale() {
    [ -f "$DETECT_ENV" ] || return 0
    local _now _mtime
    _now="$(date +%s)"
    _mtime="$(stat -c '%Y' "$DETECT_ENV" 2>/dev/null || stat -f '%m' "$DETECT_ENV" 2>/dev/null || echo 0)"
    [ "$((_now - _mtime))" -gt 86400 ]
}

# ---------------------------------------------------------------------------
# HF helpers
# ---------------------------------------------------------------------------

# hf_tree_raw REPO [REVISION] - print the raw HF tree JSON, or fail.
hf_tree_raw() {
    local _repo="$1" _rev="${2:-main}"
    local -a _auth=()
    _auth=()
    [ -n "${HF_TOKEN:-}" ] && _auth=(-H "Authorization: Bearer $HF_TOKEN")

    if command -v curl >/dev/null 2>&1; then
        curl -sf "${_auth[@]}" "https://huggingface.co/api/models/$_repo/tree/$_rev" 2>/dev/null
    else
        wget -qO- --header="Authorization: Bearer ${HF_TOKEN:-}" \
             "https://huggingface.co/api/models/$_repo/tree/$_rev" 2>/dev/null
    fi
}

# hf_tree REPO [REVISION] - print "SIZE PATH" per GGUF file. Succeeds with no
# output when the repo exists but holds no GGUF files; fails when unreadable.
hf_tree() {
    local _json _obj _path _size
    _json="$(hf_tree_raw "$1" "${2:-main}")" || return 1
    [ -n "$_json" ] || return 1

    printf '%s' "$_json" | tr -d '\n' | sed 's/},{/}\n{/g' | while IFS= read -r _obj; do
        _path="$(printf '%s' "$_obj" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
        _size="$(printf '%s' "$_obj" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')"
        case "$_path" in
            *.gguf) [ -n "$_path" ] && printf '%s %s\n' "${_size:-0}" "$_path" ;;
        esac
    done
}

# hf_file_hash REPO FILE - print "SHA256 SIZE" for a file on Hugging Face.
#
# Hugging Face serves large files through LFS, and a HEAD on the resolve URL
# returns the real size in x-linked-size and the SHA256 in x-linked-etag. That
# is a genuine integrity check, unlike the size the tree API reports.
hf_file_hash() {
    command -v curl >/dev/null 2>&1 || return 1
    local _repo="$1" _file="$2" _h _sha _size
    _h="$(curl -sIL --max-time 30 "https://huggingface.co/$_repo/resolve/main/$_file" 2>/dev/null || true)"
    [ -n "$_h" ] || return 1

    _sha="$(printf '%s\n' "$_h" \
        | sed -n 's/^[Xx]-[Ll]inked-[Ee]tag: *"\{0,1\}\([0-9a-f]\{64\}\)"\{0,1\}.*/\1/p' \
        | head -1)"
    _size="$(printf '%s\n' "$_h" \
        | sed -n 's/^[Xx]-[Ll]inked-[Ss]ize: *\([0-9]*\).*/\1/p' | head -1)"

    # Without an LFS hash there is nothing to verify against.
    [ -n "$_sha" ] || return 1
    printf '%s %s' "$_sha" "${_size:-0}"
}

# file_sha256 FILE - print the SHA256 of a local file, or nothing.
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    else
        return 1
    fi
}

# human_size BYTES - format a byte count for display.
human_size() {
    local _b="${1:-0}"
    if [ "$_b" -ge 1073741824 ] 2>/dev/null; then
        awk -v b="$_b" 'BEGIN { printf "%.1f GB", b/1073741824 }'
    elif [ "$_b" -ge 1048576 ] 2>/dev/null; then
        awk -v b="$_b" 'BEGIN { printf "%.0f MB", b/1048576 }'
    else
        printf '%s B' "$_b"
    fi
}

# ---------------------------------------------------------------------------
# Quant format support
# ---------------------------------------------------------------------------

# The PrismML fork supports these formats. Anything else must be refused or
# flagged, otherwise llama-server fails at load time with an opaque error.
# See docs/MODELS.md for the full matrix.

# quant_supported FILE - succeed when the filename names a supported format.
quant_supported() {
    local _f
    _f="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$_f" in
        *mlx*)      return 1 ;;   # Apple MLX, not a GGUF llama.cpp can load
        *gsq*)      return 1 ;;   # GSQ-RCO, no kernels in this fork
        *ninfer*)   return 1 ;;   # NInfer, separate runtime
        *awq*)      return 1 ;;
    esac
    return 0
}

# quant_label FILE - short human label for a GGUF filename.
quant_label() {
    local _f
    _f="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$_f" in
        *pq2_0*)  printf 'PQ2_0 (2.1 bpw)' ;;
        *ptq1_0*) printf 'PTQ1_0 (1.75 bpw)' ;;
        *q2_0*)   printf 'Q2_0' ;;
        *q1_0*)   printf 'Q1_0 (1-bit)' ;;
        *q4_k*)   printf 'Q4_K' ;;
        *q4_0*)   printf 'Q4_0' ;;
        *q5_k*)   printf 'Q5_K' ;;
        *q6_k*)   printf 'Q6_K' ;;
        *q8_0*)   printf 'Q8_0' ;;
        *mmproj*) printf 'vision projector' ;;
        *)        printf 'unknown' ;;
    esac
}

# quant_needs_vulkan_warning FILE - Vulkan has only partial PQ2_0/PTQ1_0 support.
quant_needs_vulkan_warning() {
    local _f
    _f="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$_f" in *pq2_0*|*ptq1_0*) return 0 ;; *) return 1 ;; esac
}
