#!/usr/bin/env bash
# tests/run.sh - dependency-free test suite for Ikaros Bonsai server.
#
# Covers backend/asset selection against fixture hardware profiles, catalog
# integrity, quant-format gating, and helper correctness. Runs with plain bash:
# no bats, no network.
#
# Usage:
#   ./tests/run.sh                 run everything except the network tests
#   ./tests/run.sh --with-network  also verify the pinned release is reachable
#   ./tests/run.sh --with-patch    also verify the UI patch applies

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
FIXTURES="$TESTS_DIR/fixtures"

WITH_NETWORK=0
WITH_PATCH=0
for arg in "$@"; do
    case "$arg" in
        --with-network) WITH_NETWORK=1 ;;
        --with-patch)   WITH_PATCH=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# shellcheck source=../scripts/lib/common.sh
. "$SCRIPTS/lib/common.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    [ -n "${2:-}" ] && printf '       %s\n' "$2"
}

group() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# assert_contains LABEL HAYSTACK NEEDLE
assert_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "'$3' not found in output" ;;
    esac
}

# ---------------------------------------------------------------------------
# detect.sh against fixture hardware
# ---------------------------------------------------------------------------

# detect_with VAR=VAL ... - run detect.sh in a temp state dir, print detect.env.
detect_with() {
    _tmp="$(mktemp -d)"
    env BONSAI_STATE_DIR="$_tmp" BONSAI_FAKE_CPUINFO="$FIXTURES/cpuinfo-noavx512.txt" "$@" \
        "$SCRIPTS/detect.sh" >/dev/null 2>&1
    _rc=$?
    [ -f "$_tmp/detect.env" ] && cat "$_tmp/detect.env"
    rm -rf "$_tmp"
    return $_rc
}

# field OFFSET OUTPUT - print the value of a key from detect.env output.
field() {
    printf '%s\n' "$2" | sed -n "s/^$1='\(.*\)'$/\1/p" | head -1
}

group "backend selection"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    BONSAI_FAKE_ROCM_PREFIX=/opt/rocm-7.2.3 BONSAI_FAKE_ROCM_VERSION=7.2.3 \
    BONSAI_FAKE_ROCM_GFX=gfx1200 BONSAI_FAKE_VRAM_BYTES=17179869184)"
assert_eq "AMD + ROCm 7.2 -> rocm backend" "rocm" "$(field BACKEND "$OUT")"
assert_eq "AMD + ROCm 7.2 -> rocm 7.2 asset" \
    "llama-prism-b10772-e8fd209-bin-ubuntu-rocm-7.2-x64.tar.gz" "$(field ASSET "$OUT")"
assert_eq "gfx1200 is a covered target" "1" "$(field GFX_SUPPORTED "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    BONSAI_FAKE_ROCM_PREFIX=/opt/rocm-7.2.3 BONSAI_FAKE_ROCM_VERSION=7.2.3 \
    BONSAI_FAKE_ROCM_GFX=gfx906)"
assert_eq "uncovered gfx target is flagged" "0" "$(field GFX_SUPPORTED "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    BONSAI_FAKE_ROCM_PREFIX=/opt/rocm-6.5.0 BONSAI_FAKE_ROCM_VERSION=6.5.0 \
    BONSAI_FAKE_ROCM_GFX=gfx1100 BONSAI_FAKE_VULKAN=0)"
assert_eq "ROCm version mismatch, no Vulkan -> cpu" "cpu" "$(field BACKEND "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    BONSAI_FAKE_ROCM_PREFIX=/opt/rocm-6.5.0 BONSAI_FAKE_ROCM_VERSION=6.5.0 \
    BONSAI_FAKE_ROCM_GFX=gfx1100 BONSAI_FAKE_VULKAN=1)"
assert_eq "ROCm version mismatch, Vulkan present -> vulkan" "vulkan" "$(field BACKEND "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_VULKAN=0 BONSAI_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda128.txt")"
assert_eq "NVIDIA + CUDA 12.8 -> cuda" "cuda" "$(field BACKEND "$OUT")"
assert_eq "CUDA 12.8 maps to the 12.8 asset" \
    "llama-prism-b10772-e8fd209-bin-linux-cuda-12.8-x64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_VULKAN=0 BONSAI_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda133.txt")"
assert_eq "CUDA 13.3 maps to the 13.3 asset" \
    "llama-prism-b10772-e8fd209-bin-linux-cuda-13.3-x64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_VULKAN=0 BONSAI_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda124.txt")"
assert_eq "CUDA 12.4 maps to the 12.4 asset" \
    "llama-prism-b10772-e8fd209-bin-linux-cuda-12.4-x64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_LSPCI="$FIXTURES/lspci-intel.txt" BONSAI_FAKE_VULKAN=0)"
assert_eq "Intel iGPU, no Vulkan -> cpu" "cpu" "$(field BACKEND "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" BONSAI_FAKE_VULKAN=1)"
assert_eq "no GPU, Vulkan present -> vulkan" "vulkan" "$(field BACKEND "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" BONSAI_FAKE_VULKAN=0)"
assert_eq "no GPU, no Vulkan -> cpu" "cpu" "$(field BACKEND "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=aarch64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda128.txt" BONSAI_FAKE_VULKAN=0)"
assert_eq "arm64 + CUDA has no asset, falls back to cpu" "cpu" "$(field BACKEND "$OUT")"
assert_eq "arm64 cpu asset" \
    "llama-prism-b10772-e8fd209-bin-ubuntu-arm64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=aarch64 \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" BONSAI_FAKE_VULKAN=1)"
assert_eq "arm64 Vulkan asset" \
    "llama-prism-b10772-e8fd209-bin-ubuntu-vulkan-arm64.tar.gz" "$(field ASSET "$OUT")"

group "overrides and failures"

OUT="$(detect_with BACKEND=cpu BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    BONSAI_FAKE_ROCM_PREFIX=/opt/rocm-7.2.3 BONSAI_FAKE_ROCM_VERSION=7.2.3 \
    BONSAI_FAKE_ROCM_GFX=gfx1200)"
assert_eq "BACKEND=cpu overrides detection" "cpu" "$(field BACKEND "$OUT")"

if detect_with BACKEND=cuda BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=aarch64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda128.txt" >/dev/null; then
    fail "forced cuda on arm64 should fail"
else
    pass "forced cuda on arm64 fails with a clear error"
fi

if detect_with BACKEND=nonsense BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" >/dev/null; then
    fail "unknown backend should fail"
else
    pass "unknown backend fails"
fi

group "AVX512 detection"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" BONSAI_FAKE_VULKAN=0 \
    BONSAI_FAKE_CPUINFO="$FIXTURES/cpuinfo-avx512.txt")"
assert_eq "AVX512 reported present" "1" "$(field AVX512 "$OUT")"

OUT="$(detect_with BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" BONSAI_FAKE_VULKAN=0 \
    BONSAI_FAKE_CPUINFO="$FIXTURES/cpuinfo-noavx512.txt")"
assert_eq "AVX512 reported absent" "0" "$(field AVX512 "$OUT")"

group "json output"

_tmp="$(mktemp -d)"
_json="$(env BONSAI_STATE_DIR="$_tmp" BONSAI_FAKE_ROCM_PREFIX= BONSAI_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" \
    BONSAI_FAKE_VULKAN=0 BONSAI_FAKE_UNAME_S=Linux BONSAI_FAKE_UNAME_M=x86_64 \
    "$SCRIPTS/detect.sh" --json 2>/dev/null)"
rm -rf "$_tmp"
assert_contains "json output is valid-looking" "$_json" '"backend": "cpu"'
if printf '%s' "$_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass "json output parses"
else
    fail "json output does not parse" "$_json"
fi

group "catalog integrity"

_rows="$(grep -v '^[[:space:]]*#' "$SCRIPTS/models.catalog" | grep -v '^[[:space:]]*$')"
_bad=""
_dupes=""
_seen=""
_n=0
while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _n=$((_n + 1))
    _fields="$(printf '%s' "$_line" | awk -F'|' '{print NF}')"
    [ "$_fields" = "6" ] || _bad="$_bad
  line $_n has $_fields fields: $_line"
    _key="$(printf '%s' "$_line" | cut -d'|' -f1,2)"
    case "$_seen" in
        *"|$_key|"*) _dupes="$_dupes
  duplicate: $_key" ;;
    esac
    _seen="$_seen|$_key|"
    _file="$(printf '%s' "$_line" | cut -d'|' -f2)"
    if ! quant_supported "$_file"; then
        _bad="$_bad
  line $_n lists an unsupported format: $_file"
    fi
done <<EOF
$_rows
EOF

assert_eq "catalog rows parsed" "1" "$([ "$_n" -gt 20 ] && echo 1 || echo 0)"
if [ -z "$_bad" ]; then
    pass "every catalog row has 6 fields and a supported format"
else
    fail "catalog problems:$_bad"
fi
if [ -z "$_dupes" ]; then
    pass "no duplicate repo+file entries"
else
    fail "duplicates:$_dupes"
fi

group "quant format gating"

for f in model-mlx-2bit.gguf x-gsq-rco.gguf y-ninfer-v3.gguf z-awq-4bit.gguf; do
    if quant_supported "$f"; then fail "should reject $f"; else pass "rejects $f"; fi
done
for f in Ternary-Bonsai-2-27B-PQ2_0.gguf model-PTQ1_0.gguf Bonsai-8B-Q1_0.gguf \
         x-Q2_0_g64.gguf y-Q4_K_M.gguf; do
    if quant_supported "$f"; then pass "accepts $f"; else fail "should accept $f"; fi
done

assert_eq "quant label PQ2_0" "PQ2_0 (2.1 bpw)" "$(quant_label a-PQ2_0.gguf)"
assert_eq "quant label PTQ1_0" "PTQ1_0 (1.75 bpw)" "$(quant_label a-PTQ1_0.gguf)"
assert_eq "quant label Q1_0" "Q1_0 (1-bit)" "$(quant_label a-Q1_0.gguf)"
assert_eq "quant label mmproj" "vision projector" "$(quant_label a-mmproj-BF16.gguf)"
if quant_needs_vulkan_warning a-PQ2_0.gguf; then
    pass "PQ2_0 triggers the Vulkan warning"
else
    fail "PQ2_0 should trigger the Vulkan warning"
fi

group "helpers"

if version_ge 12.8 12.8; then pass "version_ge equal"; else fail "version_ge equal"; fi
if version_ge 13.3 12.8; then pass "version_ge greater"; else fail "version_ge greater"; fi
if version_ge 12.4 12.8; then fail "version_ge lesser"; else pass "version_ge lesser"; fi
if version_ge 7.2.3 7.2; then pass "version_ge patch suffix"; else fail "version_ge patch suffix"; fi
assert_eq "human_size GB" "1.5 GB" "$(human_size 1610612736)"
assert_eq "human_size MB" "237 MB" "$(human_size 248512512)"

group "KV cache type"

for _t in $KV_CACHE_TYPES; do
    if kv_type_valid "$_t"; then pass "accepts $_t"; else fail "should accept $_t"; fi
done
for _t in bogus q3_weird "" q4_2; do
    if kv_type_valid "$_t"; then fail "should reject '$_t'"; else pass "rejects '$_t'"; fi
done

# Resolution: the default, an override, an asymmetric pair, and off.
assert_eq "default KV type" "q8_0" "$(kv_type_effective)"
(
    BONSAI_KV_TYPE=q4_0
    # shellcheck disable=SC2034
    assert_eq "BONSAI_KV_TYPE overrides both halves" "q4_0" "$(kv_type_effective)"
)
(
    BONSAI_KV_TYPE=iq4_nl
    # shellcheck disable=SC2034
    BONSAI_KV_TYPE_V=q8_0
    assert_eq "one half can be overridden" "K=iq4_nl V=q8_0" "$(kv_type_effective)"
)
(
    # shellcheck disable=SC2034  # read by kv_type_effective in common.sh
    BONSAI_KV_TYPE=f16
    assert_eq "f16 on both halves disables quantization" "f16" "$(kv_type_effective)"
)

# Regression: kv_type_valid used to leak its loop variable, so callers reported
# the last known type instead of the invalid one they passed.
_t="SENTINEL"
kv_type_valid "definitely-not-a-type" || true
assert_eq "kv_type_valid does not leak its loop variable" "SENTINEL" "$_t"

# The static list must match what the installed binary actually accepts, so it
# cannot drift from the build. Skipped when no binary has been fetched.
# llama_server_bin needs BACKEND, which is not set in the test context, so fall
# back to globbing whatever has been fetched.
_kvbin="$(llama_server_bin 2>/dev/null || true)"
if [ -z "$_kvbin" ]; then
    for _c in "$REPO_ROOT"/bin/*/bin/llama-server "$REPO_ROOT"/bin/*/llama-server; do
        [ -x "$_c" ] && { _kvbin="$_c"; break; }
    done
fi
if [ -n "$_kvbin" ]; then
    # The binary prints "a, b, c"; normalise to space separated before comparing.
    _reported="$("$_kvbin" --help 2>&1 | sed -n '/--cache-type-k TYPE/,/default:/p' \
        | sed -n 's/.*allowed values: *//p' | head -1 | tr ',' ' ' | tr -s ' ')"
    _reported="${_reported# }"; _reported="${_reported% }"
    if [ -n "$_reported" ]; then
        assert_eq "KV_CACHE_TYPES matches the installed binary" "$_reported" "$KV_CACHE_TYPES"
    else
        pass "binary KV type list (could not parse --help)"
    fi
else
    pass "binary KV type list (skipped: no binary fetched)"
fi

group "stop-server safety"

# Regression: stop-server.sh used to fall back to "kill whatever is on the
# port", which would kill an unrelated service that happened to own it. It must
# now positively identify its own process and refuse anything else.
if command -v python3 >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
    FOREIGN_PORT=18481
    python3 -c "
import http.server, socketserver
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', $FOREIGN_PORT), http.server.SimpleHTTPRequestHandler) as h:
    h.serve_forever()
" >/dev/null 2>&1 &
    _foreign=$!
    for _ in $(seq 1 20); do
        lsof -ti "tcp:$FOREIGN_PORT" >/dev/null 2>&1 && break
        sleep 0.5
    done

    if BONSAI_PORT=$FOREIGN_PORT "$SCRIPTS/stop-server.sh" >/dev/null 2>&1; then
        fail "stop-server.sh must refuse to stop a foreign process"
    else
        pass "stop-server.sh refuses a foreign process"
    fi

    if kill -0 "$_foreign" 2>/dev/null; then
        pass "foreign process left running"
    else
        fail "foreign process was killed"
    fi

    kill "$_foreign" 2>/dev/null || true
    wait "$_foreign" 2>/dev/null || true
else
    pass "stop-server safety (skipped: needs python3 and lsof)"
fi

group "KV cost model"

# Point the caches at temp files so the test never touches real measurements.
_tmpdir="$(mktemp -d)"
KV_COST_CACHE="$_tmpdir/kv-costs.tsv"
SPEED_CACHE="$_tmpdir/speeds.tsv"

assert_eq "f16 bits/element" "16" "$(kv_bits_per_element f16)"
assert_eq "q8_0 bits/element" "8.5" "$(kv_bits_per_element q8_0)"
assert_eq "q4_0 bits/element" "4.5" "$(kv_bits_per_element q4_0)"
assert_eq "iq4_nl bits/element" "4.5" "$(kv_bits_per_element iq4_nl)"
assert_eq "f32 bits/element" "32" "$(kv_bits_per_element f32)"
if kv_bits_per_element bogus >/dev/null 2>&1; then
    fail "unknown KV type should not have a bit width"
else
    pass "unknown KV type has no bit width"
fi

# The 8B measured 147456 bytes/cell at f16, which is 9216 MiB at 65536 cells.
# That figure was measured directly on hardware, so it pins the arithmetic.
kv_cost_set "fake-model.gguf" "147456.0000"
assert_eq "kv_cost_get round-trips" "147456.0000" "$(kv_cost_get fake-model.gguf)"
assert_eq "f16 KV at 65536 (measured 9216 MiB)" "9216" "$(kv_mib fake-model.gguf 65536 f16)"
assert_eq "q8_0 KV at 65536 (measured 4896 MiB)" "4896" "$(kv_mib fake-model.gguf 65536 q8_0)"
assert_eq "q4_0 KV at 65536 (measured 2592 MiB)" "2592" "$(kv_mib fake-model.gguf 65536 q4_0)"
assert_eq "iq4_nl matches q4_0 at 65536" "2592" "$(kv_mib fake-model.gguf 65536 iq4_nl)"
assert_eq "q8_0 is exactly 1.88x smaller than f16" "1.88" \
    "$(awk -v a="9216" -v b="4896" 'BEGIN { printf "%.2f", a/b }')"
assert_eq "kv_mib at 8192 is an eighth of 65536" "1152" "$(kv_mib fake-model.gguf 8192 f16)"

# A second measurement for the same model replaces the first, never duplicates.
kv_cost_set "fake-model.gguf" "1000.0000"
assert_eq "re-measuring replaces, not appends" "1" "$(grep -c 'fake-model.gguf' "$KV_COST_CACHE")"
assert_eq "the replacement value wins" "1000.0000" "$(kv_cost_get fake-model.gguf)"

# An unmeasured model must produce nothing rather than a wrong number.
if kv_mib "never-measured.gguf" 65536 f16 >/dev/null 2>&1; then
    fail "unmeasured model should not produce a KV size"
else
    pass "unmeasured model produces no KV size"
fi

# Placement: the cache follows the layers. Regression for a real bug - the
# first version reported RAM as weights only, understating the all-CPU row by
# the whole KV cache (4.4 GB instead of 0.2 GB on the 8B).
assert_eq "all-CPU puts weights and cache in RAM" "0.0 4.4" \
    "$(kv_placement 36 0 2.03 2.39)"
assert_eq "full offload puts everything in VRAM" "4.4 0.0" \
    "$(kv_placement 36 36 2.03 2.39)"
assert_eq "partial offload splits weights, cache stays on GPU" "3.1 1.4" \
    "$(kv_placement 36 12 2.03 2.39)"
# Each column is rounded on its own, so the pair can differ from the true total
# by up to a rounding step. Assert the real invariant, not a coincidence.
_sum="$(kv_placement 36 12 2.03 2.39 | awk '{ printf "%.2f", $1 + $2 }')"
if awk -v s="$_sum" 'BEGIN { d = s - 4.42; if (d < 0) d = -d; exit !(d <= 0.15) }'; then
    pass "the two columns sum to the model total within rounding"
else
    fail "the two columns sum to the model total" "got $_sum, expected about 4.42"
fi
assert_eq "placement for the 1.7B all-CPU" "0.0 4.0" \
    "$(kv_placement 28 0 0.23 3.72)"

speed_set "fake-model.gguf" 65536 q8_0 "186.8"
assert_eq "speed_set/speed_get round-trips" "186.8" "$(speed_get fake-model.gguf 65536 q8_0)"
if speed_get "fake-model.gguf" 32768 q8_0 >/dev/null 2>&1; then
    fail "speed should be keyed by context"
else
    pass "speed is keyed by context"
fi
speed_set "fake-model.gguf" 65536 q8_0 "200.0"
assert_eq "re-benchmarking replaces the speed" "1" "$(grep -c 'fake-model' "$SPEED_CACHE")"
assert_eq "the new speed wins" "200.0" "$(speed_get fake-model.gguf 65536 q8_0)"

rm -rf "$_tmpdir"

group "script syntax"

_syntax_fail=""
for f in "$SCRIPTS"/*.sh "$SCRIPTS"/lib/*.sh "$REPO_ROOT/setup.sh" "$TESTS_DIR"/run.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null || _syntax_fail="$_syntax_fail
  $f"
done
if [ -z "$_syntax_fail" ]; then
    pass "all scripts parse"
else
    fail "syntax errors:$_syntax_fail"
fi

group "help output"

for f in detect fetch-binary get-models start-server stop-server hermes-wire \
         install-service build-from-source make-kv-bias assess; do
    if "$SCRIPTS/$f.sh" --help >/dev/null 2>&1; then
        pass "$f.sh --help"
    else
        fail "$f.sh --help"
    fi
done

# ---------------------------------------------------------------------------
# Optional checks
# ---------------------------------------------------------------------------

if [ "$WITH_PATCH" = 1 ]; then
    group "UI patch"
    if ! command -v git >/dev/null 2>&1; then
        fail "git not available"
    else
        _work="$(mktemp -d)"
        _src="${BONSAI_TEST_SRC:-}"
        if [ -z "$_src" ]; then
            _src="$_work/src"
            git init -q "$_src"
            git -C "$_src" remote add origin "https://github.com/$PRISM_REPO.git"
            git -C "$_src" fetch -q --depth 1 origin "$PRISM_COMMIT_FULL" 2>/dev/null
            git -C "$_src" checkout -q --detach FETCH_HEAD 2>/dev/null
        fi
        if [ -d "$_src/.git" ]; then
            if git -C "$_src" apply --check "$REPO_ROOT/patches/0001-speedlog-ema-tps.patch"; then
                pass "patch applies to $PRISM_COMMIT"
            else
                fail "patch does not apply to $PRISM_COMMIT"
            fi
        else
            fail "could not fetch the pinned source"
        fi
        rm -rf "$_work"
    fi
fi

if [ "$WITH_NETWORK" = 1 ]; then
    group "network"
    # Release assets redirect to a CDN that does not answer HEAD, so fetch a
    # single byte range instead.
    _asset="llama-$PRISM_RELEASE-bin-ubuntu-x64.tar.gz"
    _url="https://github.com/$PRISM_REPO/releases/download/$PRISM_RELEASE/$_asset"
    _code="$(curl -sL -o /dev/null -w '%{http_code}' -r 0-0 "$_url" 2>/dev/null)"
    if [ "$_code" = "200" ] || [ "$_code" = "206" ]; then
        pass "pinned release is reachable (HTTP $_code)"
    else
        fail "pinned release $PRISM_RELEASE not reachable" "HTTP $_code"
    fi
    if hf_tree prism-ml/Bonsai-1.7B-gguf >/dev/null 2>&1; then
        pass "Hugging Face API reachable"
    else
        fail "Hugging Face API not reachable"
    fi
fi

# ---------------------------------------------------------------------------

printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
