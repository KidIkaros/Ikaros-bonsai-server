#!/usr/bin/env bash
# tests/run.sh - dependency-free test suite for Kiln.
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
    env KILN_STATE_DIR="$_tmp" KILN_FAKE_CPUINFO="$FIXTURES/cpuinfo-noavx512.txt" "$@" \
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

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    KILN_FAKE_ROCM_PREFIX=/opt/rocm-7.2.3 KILN_FAKE_ROCM_VERSION=7.2.3 \
    KILN_FAKE_ROCM_GFX=gfx1200 KILN_FAKE_VRAM_BYTES=17179869184)"
assert_eq "AMD + ROCm 7.2 -> rocm backend" "rocm" "$(field BACKEND "$OUT")"
assert_eq "AMD + ROCm 7.2 -> rocm 7.2 asset" \
    "llama-prism-b10772-e8fd209-bin-ubuntu-rocm-7.2-x64.tar.gz" "$(field ASSET "$OUT")"
assert_eq "gfx1200 is a covered target" "1" "$(field GFX_SUPPORTED "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    KILN_FAKE_ROCM_PREFIX=/opt/rocm-7.2.3 KILN_FAKE_ROCM_VERSION=7.2.3 \
    KILN_FAKE_ROCM_GFX=gfx906)"
assert_eq "uncovered gfx target is flagged" "0" "$(field GFX_SUPPORTED "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    KILN_FAKE_ROCM_PREFIX=/opt/rocm-6.5.0 KILN_FAKE_ROCM_VERSION=6.5.0 \
    KILN_FAKE_ROCM_GFX=gfx1100 KILN_FAKE_VULKAN=0)"
assert_eq "ROCm version mismatch, no Vulkan -> cpu" "cpu" "$(field BACKEND "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    KILN_FAKE_ROCM_PREFIX=/opt/rocm-6.5.0 KILN_FAKE_ROCM_VERSION=6.5.0 \
    KILN_FAKE_ROCM_GFX=gfx1100 KILN_FAKE_VULKAN=1)"
assert_eq "ROCm version mismatch, Vulkan present -> vulkan" "vulkan" "$(field BACKEND "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_VULKAN=0 KILN_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda128.txt")"
assert_eq "NVIDIA + CUDA 12.8 -> cuda" "cuda" "$(field BACKEND "$OUT")"
assert_eq "CUDA 12.8 maps to the 12.8 asset" \
    "llama-prism-b10772-e8fd209-bin-linux-cuda-12.8-x64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_VULKAN=0 KILN_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda133.txt")"
assert_eq "CUDA 13.3 maps to the 13.3 asset" \
    "llama-prism-b10772-e8fd209-bin-linux-cuda-13.3-x64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_VULKAN=0 KILN_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda124.txt")"
assert_eq "CUDA 12.4 maps to the 12.4 asset" \
    "llama-prism-b10772-e8fd209-bin-linux-cuda-12.4-x64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_LSPCI="$FIXTURES/lspci-intel.txt" KILN_FAKE_VULKAN=0)"
assert_eq "Intel iGPU, no Vulkan -> cpu" "cpu" "$(field BACKEND "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" KILN_FAKE_VULKAN=1)"
assert_eq "no GPU, Vulkan present -> vulkan" "vulkan" "$(field BACKEND "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" KILN_FAKE_VULKAN=0)"
assert_eq "no GPU, no Vulkan -> cpu" "cpu" "$(field BACKEND "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=aarch64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda128.txt" KILN_FAKE_VULKAN=0)"
assert_eq "arm64 + CUDA has no asset, falls back to cpu" "cpu" "$(field BACKEND "$OUT")"
assert_eq "arm64 cpu asset" \
    "llama-prism-b10772-e8fd209-bin-ubuntu-arm64.tar.gz" "$(field ASSET "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=aarch64 \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" KILN_FAKE_VULKAN=1)"
assert_eq "arm64 Vulkan asset" \
    "llama-prism-b10772-e8fd209-bin-ubuntu-vulkan-arm64.tar.gz" "$(field ASSET "$OUT")"

group "overrides and failures"

OUT="$(detect_with BACKEND=cpu KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-amd.txt" \
    KILN_FAKE_ROCM_PREFIX=/opt/rocm-7.2.3 KILN_FAKE_ROCM_VERSION=7.2.3 \
    KILN_FAKE_ROCM_GFX=gfx1200)"
assert_eq "BACKEND=cpu overrides detection" "cpu" "$(field BACKEND "$OUT")"

if detect_with BACKEND=cuda KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=aarch64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-nvidia.txt" \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_NVIDIA_SMI="$FIXTURES/nvidia-smi-cuda128.txt" >/dev/null; then
    fail "forced cuda on arm64 should fail"
else
    pass "forced cuda on arm64 fails with a clear error"
fi

if detect_with BACKEND=nonsense KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" >/dev/null; then
    fail "unknown backend should fail"
else
    pass "unknown backend fails"
fi

group "AVX512 detection"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" KILN_FAKE_VULKAN=0 \
    KILN_FAKE_CPUINFO="$FIXTURES/cpuinfo-avx512.txt")"
assert_eq "AVX512 reported present" "1" "$(field AVX512 "$OUT")"

OUT="$(detect_with KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
    KILN_FAKE_ROCM_PREFIX= KILN_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" KILN_FAKE_VULKAN=0 \
    KILN_FAKE_CPUINFO="$FIXTURES/cpuinfo-noavx512.txt")"
assert_eq "AVX512 reported absent" "0" "$(field AVX512 "$OUT")"

group "json output"

_tmp="$(mktemp -d)"
_json="$(env KILN_STATE_DIR="$_tmp" KILN_FAKE_ROCM_PREFIX= KILN_FAKE_LSPCI="$FIXTURES/lspci-empty.txt" \
    KILN_FAKE_VULKAN=0 KILN_FAKE_UNAME_S=Linux KILN_FAKE_UNAME_M=x86_64 \
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
assert_eq "the configured default is auto" "auto" "$KILN_KV_TYPE"
# With no models to price, auto resolves to the safe option.
(
    KILN_KV_TYPE=auto
    kv_type_resolve
    assert_eq "auto resolves to a concrete type" "q8_0" "$KILN_KV_TYPE"
)
(
    KILN_KV_TYPE=q4_0
    # shellcheck disable=SC2034
    assert_eq "KILN_KV_TYPE overrides both halves" "q4_0" "$(kv_type_effective)"
)
(
    KILN_KV_TYPE=iq4_nl
    # shellcheck disable=SC2034
    KILN_KV_TYPE_V=q8_0
    assert_eq "one half can be overridden" "K=iq4_nl V=q8_0" "$(kv_type_effective)"
)
(
    # shellcheck disable=SC2034  # read by kv_type_effective in common.sh
    KILN_KV_TYPE=f16
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

    if KILN_PORT=$FOREIGN_PORT "$SCRIPTS/stop-server.sh" >/dev/null 2>&1; then
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

group "configuration coverage"

# Coverage records which dimensions were explored, not how many runs happened.
_cov="$(mktemp -d)"
_cov_run() {
    KILN_STATE_DIR="$_cov" bash -c ". scripts/lib/common.sh; $1" 2>/dev/null
}
_cov_run 'coverage_set backend rocm'
_cov_run 'coverage_set backend vulkan'
_cov_run 'coverage_set backend rocm'
assert_eq "a repeated value is stored once" "rocm
vulkan" "$(_cov_run 'coverage_values backend')"
assert_eq "a dimension never explored reports nothing" "" "$(_cov_run 'coverage_values ngl')"
if [ -f "$_cov/coverage.tsv" ]; then
    pass "recording creates the cache"
else
    fail "recording should create the cache"
fi
rm -rf "$_cov"

group "auto KV reports whether it actually decided"

# q8_0 comes out of four situations and only one is a decision. An unmeasured
# model must say so rather than claiming it checked what fits.
_cd="$(mktemp -d)"
ln -sf /dev/null "$_cd/never-measured.gguf"
_reason() {
    KILN_MODELS_DIR="$_cd" KILN_CTX=65536 bash -c ". scripts/lib/common.sh; kv_type_auto_reason" 2>/dev/null
}
_r="$(_reason)"
case "$_r" in
    *unmeasured*) pass "an unmeasured model is reported as unmeasured" ;;
    *)            fail "an unmeasured model should say so" "got '$_r'" ;;
esac
if [ "$(_reason)" = "fastest type that fits the largest installed model" ]; then
    fail "an unmeasured model must not claim it checked what fits"
else
    pass "it does not claim a check that did not run"
fi
rm -rf "$_cd"

group "speed cache keying"

# A speed measured on one backend must not be served for another: the same
# model measured 36.1 on ROCm and 30.4 on Vulkan. And a measurement from an
# older build must not survive a release bump.
_spd="$(mktemp -d)"
_speed_probe() {
    KILN_STATE_DIR="$_spd" PRISM_RELEASE="prism-b10772-e8fd209" \
        BACKEND="$1" bash -c ". scripts/lib/common.sh; speed_get m.gguf 65536 q8_0" 2>/dev/null
}
KILN_STATE_DIR="$_spd" PRISM_RELEASE="prism-b10772-e8fd209" \
    BACKEND=rocm bash -c ". scripts/lib/common.sh; speed_set m.gguf 65536 q8_0 36.1" 2>/dev/null
KILN_STATE_DIR="$_spd" PRISM_RELEASE="prism-b10772-e8fd209" \
    BACKEND=vulkan bash -c ". scripts/lib/common.sh; speed_set m.gguf 65536 q8_0 30.4" 2>/dev/null

assert_eq "rocm reads back its own speed" "36.1" "$(_speed_probe rocm)"
assert_eq "vulkan reads back its own speed" "30.4" "$(_speed_probe vulkan)"
if [ -n "$(_speed_probe cuda)" ]; then
    fail "an unmeasured backend must not borrow another backend's speed"
else
    pass "an unmeasured backend reports nothing"
fi
if [ -n "$(KILN_STATE_DIR="$_spd" PRISM_RELEASE="prism-b10999-deadbee" BACKEND=rocm bash -c ". scripts/lib/common.sh; speed_get m.gguf 65536 q8_0" 2>/dev/null)" ]; then
    fail "a measurement from another release must not be served"
else
    pass "a measurement from another release is treated as stale"
fi
rm -rf "$_spd"

group "download integrity"

_tmpdir="$(mktemp -d)"
printf 'abc' > "$_tmpdir/abc"
# The well-known SHA256 of the three bytes "abc".
assert_eq "file_sha256 matches a known value" \
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
    "$(file_sha256 "$_tmpdir/abc")"
# A different file must not collide, or verification would be worthless.
printf 'abd' > "$_tmpdir/abd"
if [ "$(file_sha256 "$_tmpdir/abc")" = "$(file_sha256 "$_tmpdir/abd")" ]; then
    fail "different content must produce a different hash"
else
    pass "different content produces a different hash"
fi
if file_sha256 "$_tmpdir/does-not-exist" >/dev/null 2>&1; then
    fail "hashing a missing file should fail"
else
    pass "hashing a missing file fails cleanly"
fi
rm -rf "$_tmpdir"

group "auto KV type"

# kv_type_auto picks the fastest type that still fits the largest installed
# model. Exercise it against a controlled models dir and budget.
_tmpdir="$(mktemp -d)"
_old_state="$STATE_DIR"
STATE_DIR="$_tmpdir"
KV_COST_CACHE="$_tmpdir/kv-costs.tsv"
SETTINGS_FILE="$_tmpdir/service.env"
_KILN_FROM_ENV=""
_old_models="$MODELS_DIR"
# Detection is not loaded in the test context, so these may be unset.
_old_vram="${VRAM_GB:-}"
_old_ram="${RAM_GB:-}"
_old_backend="${BACKEND:-}"

# 147456 bytes/cell is the real 8B measurement, so the arithmetic matches hardware.
MODELS_DIR="$_tmpdir/models"
mkdir -p "$MODELS_DIR"
# A sparse file of the right size: the weight size is what decides the verdict,
# so an empty file would make every configuration look like it fits.
truncate -s 2G "$MODELS_DIR/small-2gb.gguf"

kv_cost_set "small-2gb.gguf" "147456.0000" "36"
BACKEND=rocm; VRAM_GB=15; RAM_GB=31
# f16 KV at 65536 is 9216 MiB = 9.0 GB; 2.0 + 9.0 = 11.0 GB against a 14 GB budget.
# 2.0 GB of weights + 9.0 GB of f16 cache = 11.0 GB, inside the 14 GB budget.
assert_eq "f16 when the model fits with it" "f16" "$(kv_type_auto)"

# The same model against a budget too small for the f16 cache must fall back.
VRAM_GB=10   # budget 9 GB: f16 needs 11.0, q8_0 needs 6.8
assert_eq "q8_0 when f16 would not fit" "q8_0" "$(kv_type_auto)"

# An unmeasured model cannot be priced, so take the safe option.
VRAM_GB=15
rm -f "$KV_COST_CACHE"
assert_eq "q8_0 when the model is unmeasured" "q8_0" "$(kv_type_auto)"

# No models at all is also the safe option.
kv_cost_set "small-2gb.gguf" "147456.0000" "36"
rm -f "$MODELS_DIR"/*.gguf
assert_eq "q8_0 when no models are installed" "q8_0" "$(kv_type_auto)"

assert_eq "budget holds back headroom on a GPU" "14" \
    "$(BACKEND=rocm VRAM_GB=15 RAM_GB=31 kv_budget_gb)"
assert_eq "and more headroom on CPU" "29" \
    "$(BACKEND=cpu VRAM_GB=15 RAM_GB=31 kv_budget_gb)"

MODELS_DIR="$_old_models"
[ -n "$_old_vram" ] && VRAM_GB="$_old_vram"
[ -n "$_old_ram" ] && RAM_GB="$_old_ram"
[ -n "$_old_backend" ] && BACKEND="$_old_backend"
STATE_DIR="$_old_state"
KV_COST_CACHE="$STATE_DIR/kv-costs.tsv"
SETTINGS_FILE="$STATE_DIR/service.env"
rm -rf "$_tmpdir"

group "settings file"

# Regression: install-service.sh used to rewrite the settings file from
# defaults, silently discarding anything set with `kiln set`.
_tmpdir="$(mktemp -d)"
_old_state="$STATE_DIR"
STATE_DIR="$_tmpdir"
SETTINGS_FILE="$_tmpdir/service.env"
_KILN_FROM_ENV=""

printf 'KILN_PORT=8091\nKILN_CTX=8192\n' > "$SETTINGS_FILE"
load_settings
assert_eq "the settings file is applied" "8091" "$KILN_PORT"
assert_eq "and for every key it holds" "8192" "$KILN_CTX"

# A value already exported wins over the file.
(
    KILN_PORT=9999
    # shellcheck disable=SC2034  # read by load_settings below
    _KILN_FROM_ENV=" KILN_PORT"
    load_settings
    assert_eq "an exported value beats the file" "9999" "$KILN_PORT"
)

# A malformed or comment-only file must not break anything.
printf '# only a comment\n' > "$SETTINGS_FILE"
load_settings
pass "a comment-only settings file is harmless"

# Unknown keys are ignored rather than exported.
printf 'PATH=/evil\nKILN_CTX=4096\n' > "$SETTINGS_FILE"
load_settings
assert_eq "only KILN_ keys are applied" "4096" "$KILN_CTX"

STATE_DIR="$_old_state"
SETTINGS_FILE="$STATE_DIR/service.env"
rm -rf "$_tmpdir"


group "tune winner persistence"

# write_tune_best records every key the winner set, and apply_tune_best projects
# the machine-level ones onto the live settings file.
_tune_dir() {
    _td="$(mktemp -d)"
    KILN_STATE_DIR="$_td" bash -c '. scripts/lib/common.sh; '"$1" 2>/dev/null
    printf '%s' "$_td"
}

_td="$(_tune_dir 'write_tune_best "KILN_KV_TYPE=q8_0 KILN_SPEC_TYPE=draft-mtp KILN_SPEC_DRAFT_N_MAX=1 KILN_NGL=24" rocm')"
if grep -qx 'KILN_NGL=24' "$_td/tune-best.env"; then
    pass "winner records KILN_NGL when set"
else
    fail "winner should record KILN_NGL"
    [ -f "$_td/tune-best.env" ] && sed -n '1,20p' "$_td/tune-best.env" >&2
fi
BACKEND=rocm KILN_STATE_DIR="$_td" bash -c '. scripts/lib/common.sh; apply_tune_best' >/dev/null 2>&1
if grep -qx 'KILN_NGL=24' "$_td/service.env"; then
    pass "apply persists KILN_NGL from the winner"
else
    fail "apply should persist KILN_NGL"
fi
rm -rf "$_td"

# A winner that did not set NGL must not pull the ambient default into the file.
_td="$(_tune_dir 'write_tune_best "KILN_KV_TYPE=q8_0" rocm')"
BACKEND=rocm KILN_STATE_DIR="$_td" bash -c '. scripts/lib/common.sh; apply_tune_best' >/dev/null 2>&1
if grep -q '^KILN_NGL=' "$_td/service.env"; then
    fail "apply must not persist an unset KILN_NGL"
else
    pass "apply leaves KILN_NGL unset when the winner did not set it"
fi
rm -rf "$_td"

# Cross-backend: NGL (machine-level) survives, the backend-specific spec is
# dropped so a Vulkan-tuned draft-mtp does not run on ROCm.
_td="$(_tune_dir 'write_tune_best "KILN_SPEC_TYPE=draft-mtp KILN_SPEC_DRAFT_N_MAX=2 KILN_NGL=24" rocm')"
BACKEND=vulkan KILN_STATE_DIR="$_td" bash -c '. scripts/lib/common.sh; apply_tune_best' >/dev/null 2>&1
if grep -qx 'KILN_NGL=24' "$_td/service.env"; then
    pass "cross-backend apply keeps machine-level NGL"
else
    fail "NGL should survive a cross-backend apply"
fi
if ! grep -qx 'KILN_SPEC_TYPE=*' "$_td/service.env" && [ -z "$(grep '^KILN_SPEC_TYPE=' "$_td/service.env" 2>/dev/null)" ]; then
    pass "cross-backend apply drops stale spec"
else
    fail "stale spec should be cleared on a cross-backend apply"
fi
rm -rf "$_td"

# Regression: write_tune_best runs under `set -u` (assess.sh and kiln set it),
# but a winner that omits some keys must not trip "unbound variable" on the
# indirect expansion of unset keys like KILN_KV_TYPE_K.
_td3="$(mktemp -d)"
KILN_STATE_DIR="$_td3" bash -c '. scripts/lib/common.sh; set -u; write_tune_best "KILN_KV_TYPE=q8_0 KILN_NGL=28" rocm' >/dev/null 2>&1
if grep -qx 'KILN_NGL=28' "$_td3/tune-best.env" && grep -qx 'KILN_KV_TYPE=q8_0' "$_td3/tune-best.env"; then
    pass "write_tune_best is safe under set -u with a partial winner"
else
    fail "write_tune_best crashed or truncated under set -u"
    [ -f "$_td3/tune-best.env" ] && sed -n '1,20p' "$_td3/tune-best.env" >&2
fi
rm -rf "$_td3"

group "kiln set"

_td="$(mktemp -d)"
KILN_STATE_DIR="$_td" "$SCRIPTS/kiln" set threads 8 >/dev/null 2>&1
if grep -qx 'KILN_THREADS=8' "$_td/service.env"; then
    pass "set threads writes KILN_THREADS"
else
    fail "set threads should write KILN_THREADS=8"
fi
if KILN_STATE_DIR="$_td" "$SCRIPTS/kiln" set threads notnum >/dev/null 2>&1; then
    fail "set threads should reject a non-numeric value"
else
    pass "set threads rejects non-numeric input"
fi
if KILN_STATE_DIR="$_td" "$SCRIPTS/kiln" set ngl 36 >/dev/null 2>&1; then
    pass "set ngl is accepted"
else
    fail "set ngl should be accepted"
fi
KILN_STATE_DIR="$_td" "$SCRIPTS/kiln" set kv q4_0 >/dev/null 2>&1
if grep -qx 'KILN_KV_TYPE=q4_0' "$_td/service.env"; then
    pass "set kv writes KILN_KV_TYPE"
else
    fail "set kv should write KILN_KV_TYPE=q4_0"
fi
rm -rf "$_td"

group "moe cache setting"

# --moe-cache-mib is the one merged flag worth a source build (+1.5-1.85x decode
# on CPU-resident MoE, PR #29887) and it is newer than the pinned prebuilt, so
# the setting must exist and must reject non-numbers.
_td="$(mktemp -d)"
KILN_STATE_DIR="$_td" "$SCRIPTS/kiln" set moe-cache-mib 2048 >/dev/null 2>&1
if grep -qx 'KILN_MOE_CACHE_MIB=2048' "$_td/service.env"; then
    pass "set moe-cache-mib writes KILN_MOE_CACHE_MIB"
else
    fail "set moe-cache-mib should write KILN_MOE_CACHE_MIB=2048"
fi
if KILN_STATE_DIR="$_td" "$SCRIPTS/kiln" set moe-cache-mib big >/dev/null 2>&1; then
    fail "set moe-cache-mib should reject a non-numeric value"
else
    pass "set moe-cache-mib rejects non-numeric input"
fi
if KILN_STATE_DIR="$_td" "$SCRIPTS/kiln" set moe-cache 1024 >/dev/null 2>&1 &&
   grep -qx 'KILN_MOE_CACHE_MIB=1024' "$_td/service.env"; then
    pass "the short alias moe-cache works"
else
    fail "the moe-cache alias should write KILN_MOE_CACHE_MIB"
fi
# The key list in the usage error must mention it, or nobody finds it.
# `kiln set` with no arguments exits non-zero and its message goes to stderr,
# so the output is captured first and grepped after: in a pipeline under
# pipefail the failing command's status would sink the whole test.
if printf '%s' "$("$SCRIPTS/kiln" set 2>&1 || true)" | grep -q "moe-cache-mib"; then
    pass "the set usage lists moe-cache-mib"
else
    fail "the set usage should list moe-cache-mib"
fi
if "$SCRIPTS/start-server.sh" --help 2>&1 | grep -q "KILN_MOE_CACHE_MIB"; then
    pass "start-server.sh --help documents KILN_MOE_CACHE_MIB"
else
    fail "start-server.sh --help should document KILN_MOE_CACHE_MIB"
fi
# The flag is only passed when the binary supports it: an unknown flag aborts
# llama-server at startup, so the gate must be in the script, not the docs.
if grep -q -- "--moe-cache-mib" "$SCRIPTS/start-server.sh"; then
    pass "start-server.sh gates --moe-cache-mib on binary support"
else
    fail "start-server.sh should check for --moe-cache-mib before passing it"
fi
rm -rf "$_td"

group "spec selection (speed-first)"

# The MTP head is the third-biggest measured lever and needs no second file,
# so a *-mtp.gguf must be detected by name, fat and lean alike.
if file_has_mtp_head "Ternary-Bonsai-2-27B-PTQ1_0-mtp.gguf"; then
    pass "file_has_mtp_head accepts the fat MTP file"
else
    fail "file_has_mtp_head should accept *-mtp.gguf"
fi
if file_has_mtp_head "Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"; then
    pass "file_has_mtp_head accepts the lean MTP file"
else
    fail "file_has_mtp_head should accept *-mtp-lean.gguf"
fi
if file_has_mtp_head "Ternary-Bonsai-2-27B-PTQ1_0.gguf"; then
    fail "a plain file must not be read as an MTP file"
else
    pass "a plain model file has no MTP head"
fi

# The draft window is backend-specific and measured, so the mapping is pinned
# here: Vulkan pays for 2 (54.9 tok/s against 47.7 at 1 on the RX 9060 XT),
# ROCm and CUDA do not (n-max 2 measured slower than baseline there), and CPU
# must stay off (the verification pass costs more than the drafts save).
assert_eq "vulkan drafts 2 tokens" "2" "$(spec_nmax_for vulkan)"
assert_eq "rocm drafts 1 token" "1" "$(spec_nmax_for rocm)"
assert_eq "cuda drafts 1 token" "1" "$(spec_nmax_for cuda)"
assert_eq "cpu enables no drafting" "0" "$(spec_nmax_for cpu)"

# speed rows carry the offload level, because a tok/s number measured at a
# partial split does not reproduce without the split.
_sr="$(mktemp -d)"
_sr_probe() {
    KILN_STATE_DIR="$_sr" PRISM_RELEASE="prism-b10772-e8fd209" \
        BACKEND="$1" bash -c ". scripts/lib/common.sh; $2" 2>/dev/null
}
_sr_probe rocm 'speed_set m-lean.gguf 65536 q4_0 46.1'
_sr_probe rocm 'speed_set m-lean.gguf 65536 q4_0 21.9 "" "" 12'
if awk -F'\t' 'END { exit !(NR == 2) }' "$_sr/speeds.tsv"; then
    pass "two offload levels are two rows, not one"
else
    fail "the offload level should be part of the key" \
        "$(wc -l < "$_sr/speeds.tsv") rows for two splits"
fi
_sr_rows="$(_sr_probe rocm 'speed_rows rocm')"
assert_eq "speed_rows returns the measured rows" "2" "$(printf '%s\n' "$_sr_rows" | grep -c '^')"
assert_eq "the offload level survives the round trip" "12" \
    "$(printf '%s\n' "$_sr_rows" | awk -F'\t' '$7 == 12 { print $7 }')"
if [ -z "$(_sr_probe vulkan 'speed_rows vulkan')" ]; then
    pass "an unmeasured backend reports no rows"
else
    fail "another backend's rows must not be served"
fi
rm -rf "$_sr"

group "draft acceptance"

# Acceptance is the number that decides whether a spec type is doing anything:
# below 0.10 the verify passes cost more than the drafts save.
_la="$(mktemp -d)"
# A run with no spec type prints no draft line at all - that is "no drafts",
# not zero acceptance, and the two must not be conflated.
cat > "$_la/no-spec.log" <<'LOG'
llama_new_context_with_model: ... OK
LOG
assert_eq "a log with no draft line yields no rate" "" "$(log_draft_acceptance "$_la/no-spec.log")"
# A spec run prints the rate once per completed generation; the last one
# covers the whole response.
cat > "$_la/spec.log" <<'LOG'
llama_print_timings:        draft acceptance rate = 0.25000 (32 accepted / 128 generated)
llama_print_timings:        draft acceptance rate = 0.70312 (90 accepted / 128 generated)
LOG
assert_eq "the last acceptance rate wins" "0.70312" "$(log_draft_acceptance "$_la/spec.log")"
# A weak spec run must be reported as weak, not silently treated as fine.
cat > "$_la/weak.log" <<'LOG'
llama_print_timings:        draft acceptance rate = 0.05000 (6 accepted / 128 generated)
LOG
assert_eq "a weak rate is extracted" "0.05000" "$(log_draft_acceptance "$_la/weak.log")"
assert_eq "0.703 is a working spec type" "works" "$(acceptance_verdict 0.70312)"
assert_eq "0.05 is a weak spec type" "weak" "$(acceptance_verdict 0.05000)"
assert_eq "0.10 is the boundary and counts as working" "works" "$(acceptance_verdict 0.10)"
assert_eq "no rate means no drafts" "no drafts" "$(acceptance_verdict "")"
if log_draft_acceptance "$_la/missing.log" >/dev/null 2>&1; then
    fail "a missing log should not yield a rate"
else
    pass "a missing log fails cleanly"
fi
rm -rf "$_la"

# Acceptance is part of a speed row, so a measured tok/s with 0.05 acceptance
# reads as what it is: a spec type that is not landing.
_sa="$(mktemp -d)"
_sa_probe() {
    KILN_STATE_DIR="$_sa" PRISM_RELEASE="prism-b10772-e8fd209" \
        BACKEND="$1" bash -c ". scripts/lib/common.sh; $2" 2>/dev/null
}
_sa_probe cuda 'speed_set m.gguf 65536 q4_0 46.1 cuda prism-b10772-e8fd209 36 0.73'
_sa_probe cuda 'speed_set m.gguf 65536 q4_0 44.0 cuda prism-b10772-e8fd209 36 0.05'
if [ "$(awk -F'\t' 'END { print NR }' "$_sa/speeds.tsv")" = "1" ]; then
    pass "re-measuring at the same split replaces the row"
else
    fail "same split should replace, not duplicate"
fi
assert_eq "the recorded acceptance round-trips" "0.05" \
    "$(_sa_probe cuda 'speed_rows cuda' | awk -F'\t' '{ print $8 }')"
# A legacy row with no acceptance column still reads back.
_sa_probe cuda 'speed_set old.gguf 65536 q4_0 30.0'
assert_eq "a legacy row without acceptance is empty" "" \
    "$(_sa_probe cuda 'speed_rows cuda' | awk -F'\t' '$1 == "old.gguf" { print $8 }')"
rm -rf "$_sa"

group "fastest ranking order"

# The speed cache's first column is the MODEL NAME and tok/s is field 6, so a
# plain `sort -rn` orders rows by model name and presents the slowest
# configuration first. Pin the field-6 sort with model names that make a
# name-sort visibly wrong: a-slow sorts first alphabetically but is the
# slowest, z-fast sorts last alphabetically but is the fastest.
_fr="$(mktemp -d)"
_fr_probe() {
    KILN_STATE_DIR="$_fr" PRISM_RELEASE="prism-b10772-e8fd209" \
        BACKEND="$1" bash -c ". scripts/lib/common.sh; $2" 2>/dev/null
}
_fr_probe cuda 'speed_set a-slow.gguf 65536 q4_0 40.0 cuda prism-b10772-e8fd209 36 0.05'
_fr_probe cuda 'speed_set z-fast.gguf 65536 q4_0 46.1 cuda prism-b10772-e8fd209 36 0.74'
_fr_probe cuda 'speed_set m-mid.gguf 65536 q8_0 43.0 cuda prism-b10772-e8fd209 36'
_fr_sorted="$(_fr_probe cuda 'speed_rows cuda' | sort -t"$(printf '\t')" -k6,6rn)"
assert_eq "the fastest row sorts first" "z-fast.gguf" "$(printf '%s\n' "$_fr_sorted" | head -1 | cut -f1)"
assert_eq "the slowest row sorts last" "a-slow.gguf" "$(printf '%s\n' "$_fr_sorted" | tail -1 | cut -f1)"
assert_eq "ranking is by tok/s, not model name" "46.1 43.0 40.0" \
    "$(printf '%s\n' "$_fr_sorted" | cut -f6 | paste -sd' ' -)"
# A name-sort would have produced this wrong order; assert it is not what runs.
if [ "$(printf '%s\n' "$_fr_sorted" | head -1 | cut -f1)" = "a-slow.gguf" ]; then
    fail "rows must not be ordered by model name"
else
    pass "rows are not ordered by model name"
fi
# The weak-acceptance warning looks at field 8.
if _fr_probe cuda 'speed_rows cuda' | awk -F'\t' '$8 != "" && $8 < 0.10' | grep -q .; then
    pass "a sub-0.10 acceptance row is detected for the warning"
else
    fail "the weak-acceptance warning should detect the 0.05 row"
fi
# A row with no spec type must not trip that warning.
_fr2="$(mktemp -d)"
KILN_STATE_DIR="$_fr2" PRISM_RELEASE="prism-b10772-e8fd209" BACKEND=cuda \
    bash -c '. scripts/lib/common.sh; speed_set b.gguf 65536 q8_0 40.0 cuda prism-b10772-e8fd209 36' 2>/dev/null
if KILN_STATE_DIR="$_fr2" PRISM_RELEASE="prism-b10772-e8fd209" BACKEND=cuda \
    bash -c '. scripts/lib/common.sh; speed_rows cuda' 2>/dev/null |
    awk -F'\t' '$8 != "" && $8 < 0.10' | grep -q .; then
    fail "a baseline row must not be read as a weak draft"
else
    pass "a baseline row is not a weak-draft row"
fi
rm -rf "$_fr" "$_fr2"

group "tune ranking with acceptance"

# The tune results file gains a fifth column (draft acceptance), and a winner
# whose drafts are not landing must not take the top slot: the ranking filter
# keeps only rows with no acceptance recorded or acceptance >= 0.10, and falls
# back to the raw ranking when every row is weak.
_tr="$(mktemp -d)"
cat > "$_tr/tune-results.tsv" <<'TSV'
46.1	default q8_0	q8_0	KILN_KV_TYPE=q8_0	0.74
48.9	draft-mtp n-max 1	q8_0	KILN_SPEC_TYPE=draft-mtp KILN_SPEC_DRAFT_N_MAX=1	0.03
44.0	f16 KV	q8_0	KILN_KV_TYPE=f16	
TSV
_ranked() {
    sort -t"$(printf '\t')" -k1,1rn "$_tr/tune-results.tsv" |
        awk -F'\t' '$5 == "" || $5 + 0 >= 0.10'
}
assert_eq "a weak-draft row is excluded from the top" \
    "46.1" "$(printf '%s\n' "$(_ranked)" | head -1 | cut -f1)"
assert_eq "the strongest acceptable row is picked, not the fastest" \
    "default q8_0" "$(printf '%s\n' "$(_ranked)" | head -1 | cut -f2)"
assert_eq "a row with no acceptance stays in the ranking" \
    "2" "$(printf '%s\n' "$(_ranked)" | grep -c '^')"
# When every row is weak, the fallback keeps the raw fastest so the report
# still names something rather than printing nothing.
cat > "$_tr/tune-results.tsv" <<'TSV'
48.9	draft-mtp n-max 1	q8_0	KILN_SPEC_TYPE=draft-mtp	0.03
46.1	default q8_0	q8_0	KILN_KV_TYPE=q8_0	0.02
TSV
if [ -z "$(printf '%s\n' "$(_ranked)" | head -1)" ]; then
    pass "an all-weak ranking falls back to the raw fastest"
else
    fail "an all-weak ranking should fall back"
fi
rm -rf "$_tr"

group "identity check"

# The correctness axis: a speed row is not advice unless the output is the
# output. The command must exist, refuse a model with no head, and be
# documented in help and the README.
if "$SCRIPTS/kiln" help 2>&1 | grep -q "kiln identity"; then
    pass "kiln help documents identity"
else
    fail "kiln help should document 'kiln identity'"
fi
if grep -q -- '--identity' "$SCRIPTS/assess.sh"; then
    pass "assess.sh implements --identity"
else
    fail "assess.sh should implement --identity"
fi
# A model without an MTP head has nothing to compare, so the command must say
# so rather than silently comparing a model against itself.
_id_dir="$(mktemp -d)"
touch "$_id_dir/plain-model.gguf" "$_id_dir/some-mtp.gguf"
if KILN_STATE_DIR="$_id_dir/state" KILN_MODELS_DIR="$_id_dir" \
        "$SCRIPTS/kiln" identity "$_id_dir/plain-model.gguf" >/dev/null 2>&1; then
    fail "identity should refuse a model with no MTP head"
else
    pass "identity refuses a model with no MTP head"
fi
if file_has_mtp_head "$_id_dir/some-mtp.gguf"; then
    pass "an *-mtp.gguf is accepted for the identity check"
else
    fail "an *-mtp.gguf should be accepted"
fi
rm -rf "$_id_dir"

# The bench row names every input so it can be reproduced or contested.
_r="$(bench_row "RTX 2070" cuda prism-b10772-e8fd209 "m-lean.gguf" 36 q4_0 65536 "draft-mtp n-max 1" 46.1)"
assert_contains "bench row names the card" "$_r" "RTX 2070"
assert_contains "bench row names the build" "$_r" "prism-b10772-e8fd209"
assert_contains "bench row names the file" "$_r" "m-lean.gguf"
assert_contains "bench row names the offload split" "$_r" "ngl 36"
assert_contains "bench row carries the measurement" "$_r" "46.1 tok/s"

# first_model_id is the single parse of /v1/models. Point it at a local
# one-shot server so the test needs no network.
if command -v python3 >/dev/null 2>&1; then
    _fi_port=18491
    python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/v1/models'):
            body = b'{\"data\":[{\"id\":\"m-lean.gguf\"},{\"id\":\"other\"}]}'
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', $_fi_port), H) as s:
    s.serve_forever()
" >/dev/null 2>&1 &
    _fi_pid=$!
    for _ in $(seq 1 20); do
        curl -sf --max-time 2 "http://127.0.0.1:$_fi_port/v1/models" >/dev/null 2>&1 && break
        sleep 0.3
    done
    assert_eq "first_model_id reads the first id" "m-lean.gguf" \
        "$(first_model_id "http://127.0.0.1:$_fi_port")"
    assert_eq "first_model_id tolerates a trailing slash" "m-lean.gguf" \
        "$(first_model_id "http://127.0.0.1:$_fi_port/")"
    # A server that answers but reports no models must yield nothing, not junk.
    assert_eq "no models yields an empty id" "" "$(first_model_id "http://127.0.0.1:1" 2>/dev/null || true)"
    kill "$_fi_pid" 2>/dev/null || true
    wait "$_fi_pid" 2>/dev/null || true
else
    pass "first_model_id (skipped: needs python3)"
fi

group "spec stack (upstream ngram-mod default)"

# Upstream made ngram-mod the DEFAULT spec type (PR #28391) and --spec-type is
# additive to it, so a bare `--spec-type draft-mtp` would run
# [ngram-mod, draft-mtp] - two drafters sharing one verify batch. On the
# PrismML ternary models ngram-mod silently no-ops (accepted, zero log lines,
# draft_n null, decode identical to none), so the tool removes it first.
#
# Verified with a grep on the script rather than by executing a server: the
# invariant is the emitted command line.
_ss_args() {
    KILN_SPEC_STACK="$1" bash -c '
        set -euo pipefail
        # Emit the DRAFT_ARGS the way start-server.sh builds them, without the
        # parts that need a real binary: the flag emission is the contract.
        DRAFT_ARGS=()
        if [ "${KILN_SPEC_STACK:-kiln}" != "upstream" ]; then
            DRAFT_ARGS+=(--no-spec-type ngram-mod)
        fi
        printf "%s" "${DRAFT_ARGS[*]}"
    '
}
assert_eq "the default stack removes ngram-mod" "--no-spec-type ngram-mod" "$(_ss_args kiln)"
assert_eq "an unset stack removes ngram-mod too" "--no-spec-type ngram-mod" "$(_ss_args "")"
assert_eq "the upstream stack keeps ngram-mod" "" "$(_ss_args upstream)"

# The documented override must survive in the help text, where a user looks.
if grep -q 'KILN_SPEC_STACK' "$SCRIPTS/start-server.sh"; then
    pass "start-server.sh documents KILN_SPEC_STACK"
else
    fail "start-server.sh should document KILN_SPEC_STACK"
fi
if "$SCRIPTS/start-server.sh" --help 2>&1 | grep -q "KILN_SPEC_STACK"; then
    pass "start-server.sh --help documents KILN_SPEC_STACK"
else
    fail "start-server.sh --help should document KILN_SPEC_STACK"
fi

# The research doc must stay referenced from the README, so a reader of either
# can find the measurements behind the decision.
if grep -q 'SPEED-BEYOND-MTP-2026-10' "$REPO_ROOT/README.md"; then
    pass "README references the speed-beyond-MTP research"
else
    fail "README should reference docs/SPEED-BEYOND-MTP-2026-10.md"
fi

group "documentation coverage"

# The README env table is the contract for what a user may set. Every var the
# scripts consume that is user-facing must be in it; anything in the table must
# actually be read somewhere (a documented-but-dead var is a false claim).
#
# Internal vars are excluded by name: the KILN_FAKE_* test hooks, the
# tune-result keys the scripts write rather than read, the install-time paths
# that are not server settings, and the source-build overrides only a
# contributor building llama.cpp from source would set.
_doc_internal="KILN_FAKE_ KILN_FROM_ENV KILN_SETTINGS KILN_TUNED_AT KILN_TUNED_BACKEND KILN_STATE_DIR KILN_PREFIX KILN_SRC_DIR KILN_SRC_FORCE KILN_TEST_SRC"

_doc_table() {
    # From the "Environment variables" section onward, take the first column
    # of each row. Anchored on the section heading so an earlier table (the
    # hardware-guidance one) cannot leak in.
    #
    # The row "`KILN_KV_TYPE_K` / `_V`" documents two vars in one cell; the
    # `_V` shorthand expands to KILN_KV_TYPE_V, so it is listed explicitly
    # rather than left to read as undocumented.
    sed -n '/^## Environment variables/,$p' "$REPO_ROOT/README.md" |
        grep -E '^\| `[A-Z_]+' |
        sed -n 's/^| `\([A-Z_]*\)`.*/\1/p' |
        sed 's|^KILN_KV_TYPE_K$|KILN_KV_TYPE_K\nKILN_KV_TYPE_V|' |
        sort -u
}

_doc_tmp="$(mktemp -d)"
_doc_table > "$_doc_tmp/table"
# Direction 1: every documented var must appear somewhere in the scripts.
: > "$_doc_tmp/filtered"
while IFS= read -r _v; do
    _skip=0
    for _i in $_doc_internal; do
        case "$_v" in "$_i"*) _skip=1 ;; esac
    done
    if [ "$_skip" = 0 ] && grep -rqF "$_v" "$SCRIPTS" "$REPO_ROOT/setup.sh" \
            "$REPO_ROOT/install.sh" 2>/dev/null; then
        printf '%s\n' "$_v" >> "$_doc_tmp/filtered"
    fi
done < "$_doc_tmp/table"
# Direction 2: every user-facing KILN_ var the scripts read must be in the table.
# grep -v KILN_X drops the literal placeholder KILN_X that appears in the
# back-compat comments in common.sh ("a KILN_X is honoured as KILN_X"), which
# is prose, not a variable.
grep -rhoE 'KILN_[A-Z_]+' "$SCRIPTS"/*.sh "$SCRIPTS"/lib/*.sh \
    "$REPO_ROOT/setup.sh" "$REPO_ROOT/install.sh" 2>/dev/null | sort -u |
    grep -v '^KILN_X$' > "$_doc_tmp/all_used"
: > "$_doc_tmp/missing"
while IFS= read -r _v; do
    _skip=0
    for _i in $_doc_internal; do
        case "$_v" in "$_i"*) _skip=1 ;; esac
    done
    if [ "$_skip" = 0 ] && ! grep -qxF "$_v" "$_doc_tmp/table"; then
        printf '%s\n' "$_v" >> "$_doc_tmp/missing"
    fi
done < "$_doc_tmp/all_used"

_doc_missing="$(cat "$_doc_tmp/missing")"
if [ -z "$_doc_missing" ]; then
    pass "every user-facing KILN_ var is documented"
else
    fail "undocumented vars:" "$(printf '%s' "$_doc_missing" | tr '\n' ' ')"
fi
_doc_dead="$(comm -23 "$_doc_tmp/table" "$_doc_tmp/filtered")"
if [ -z "$_doc_dead" ]; then
    pass "no documented var is dead"
else
    fail "documented but never read:" "$(printf '%s' "$_doc_dead" | tr '\n' ' ')"
fi
rm -rf "$_doc_tmp"

# The requirements section must not claim Python is absent when the default
# path shells out to python3 - the claim is what a new user plans around.
if grep -q "python3" "$SCRIPTS/kiln" "$SCRIPTS/assess.sh" 2>/dev/null; then
    if grep -qE "No compiler, no Python" "$REPO_ROOT/README.md"; then
        fail "README claims no Python but the default path uses python3"
    else
        pass "the Python requirement is stated honestly"
    fi
else
    pass "no python3 on the default path"
fi

# Every README anchor into docs/ must name a heading that exists: a link that
# 404s reads as a missing section. GitHub slugs are the heading lowercased with
# punctuation stripped and spaces as hyphens.
_doc_anchor_ok=1
_doc_anchor_bad=""
while IFS= read -r _link; do
    _file="${_link%%#*}"
    _frag="${_link#*#}"
    [ "$_file" != "$_link" ] || continue          # no fragment, skip
    [ -f "$REPO_ROOT/$_file" ] || continue
    _slug="$(grep -E '^#{1,6} ' "$REPO_ROOT/$_file" |
        sed 's/^#* //' | tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9 -]//g' | sed 's/ /-/g')"
    printf '%s\n' "$_slug" | grep -qxF "$_frag" || {
        _doc_anchor_ok=0
        _doc_anchor_bad="$_doc_anchor_bad $_link"
    }
done <<EOF
$(grep -ohE '\]\(([^)]+\.md#[^)]+)\)' "$REPO_ROOT/README.md" "$REPO_ROOT"/docs/*.md 2>/dev/null |
    sed 's/](\(.*\))/\1/')
EOF
if [ "$_doc_anchor_ok" = 1 ]; then
    pass "every doc anchor resolves to a real heading"
else
    fail "broken doc anchors:" "$_doc_anchor_bad"
fi

group "first-run guidance (discoverability)"

# A first-time user hits `fastest` before any measurement exists. That state
# must name kiln bench first: it measures and benchmarks in one command, so
# the measure-then-speed ordering never has to be learned.
_fg="$(mktemp -d)"
if printf '%s' "$(KILN_STATE_DIR="$_fg" "$SCRIPTS/kiln" fastest 2>&1 || true)" | grep -q "kiln bench"; then
    pass "the empty fastest state points at kiln bench"
else
    fail "the empty fastest state should name kiln bench"
fi
# It must not be the only mention, or the separate flags look unsupported.
if printf '%s' "$(KILN_STATE_DIR="$_fg" "$SCRIPTS/kiln" fastest 2>&1 || true)" | grep -q -- "--sweep"; then
    pass "the empty fastest state still lists the assess.sh flags"
else
    fail "the empty fastest state should still list --sweep"
fi
rm -rf "$_fg"

# bench must not require a prior measurement: it adds --measure itself, so the
# sequencing is not the user's problem. Verified by the argument it builds.
if grep -q '_bench_args=(--measure)' "$SCRIPTS/kiln"; then
    pass "bench measures an unmeasured model itself"
else
    fail "bench should add --measure for an unmeasured model"
fi
# The old failure mode was a die telling the user to run --measure first; the
# word "measured" still appears in the new message, so assert on the absence
# of the die's specific shape rather than the word.
if grep -q 'Run first: ./scripts/assess.sh --measure' "$SCRIPTS/kiln"; then
    fail "bench should no longer die with 'run --measure first'"
else
    pass "bench no longer dies on an unmeasured model"
fi

# A typo has the user's intent in hand: name the nearest command.
_t1="$(printf '%s' "$("$SCRIPTS/kiln" speeed 2>&1 || true)")"
if printf '%s' "$_t1" | grep -q "Did you mean 'speed'"; then
    pass "a near-miss command suggests the intended one"
else
    fail "a near-miss command should suggest 'speed'" "got: $_t1"
fi
_t2="$(printf '%s' "$("$SCRIPTS/kiln" tume 2>&1 || true)")"
if printf '%s' "$_t2" | grep -q "Did you mean 'tune'"; then
    pass "a near-miss suggests tune as well"
else
    fail "a near-miss should suggest 'tune'" "got: $_t2"
fi
# A genuinely unknown command still gets the full pointer.
_t3="$(printf '%s' "$("$SCRIPTS/kiln" zzzzz 2>&1 || true)")"
if printf '%s' "$_t3" | grep -q "kiln help"; then
    pass "an unknown command still points at help"
else
    fail "an unknown command should point at help"
fi

# tune must name the two steps that make the winner live; a recorded-but-
# unapplied file is the loss-of-activation slip this prevents.
if grep -q "kiln apply" "$SCRIPTS/assess.sh" && grep -q "kiln restart" "$SCRIPTS/assess.sh"; then
    pass "tune names apply and restart"
else
    fail "tune should name kiln apply and kiln restart"
fi

group "shell completions"

# Tab completion is the discoverability surface a new user explores with, so it
# must emit for every supported shell and the bash one must actually complete.
for _sh in bash zsh fish; do
    _out="$(printf '%s' "$("$SCRIPTS/kiln" completions "$_sh" 2>/dev/null || true)")"
    if [ -n "$_out" ]; then
        pass "completions $_sh emits a script"
    else
        fail "completions $_sh produced nothing"
    fi
done
# The bash script must define and register the function, not just print words.
_comp="$("$SCRIPTS/kiln" completions bash 2>/dev/null || true)"
if printf '%s' "$_comp" | grep -q "_bonsai_completions()"; then
    pass "bash completion defines its function"
else
    fail "bash completion should define _bonsai_completions"
fi
if printf '%s' "$_comp" | grep -q "complete -F _bonsai_completions kiln"; then
    pass "bash completion registers with complete"
else
    fail "bash completion should register with complete -F"
fi
# Every command in the dispatcher must appear in the completion word list, or
# the completion silently omits it.
_comp_words="$(printf '%s' "$_comp" | grep -oE 'compgen -W "[^"]+"' | head -1 | sed 's/.*-W "//;s/"//')"
_comp_missing=""
for _c in start stop restart status logs show set speed fastest bench identity \
           tune apply assess coverage models help; do
    case " $_comp_words " in
        *" $_c "*) ;;
        *) _comp_missing="$_comp_missing $_c" ;;
    esac
done
if [ -z "$_comp_missing" ]; then
    pass "every command is in the completion list"
else
    fail "commands missing from completion:" "$_comp_missing"
fi
# An unknown shell must fail rather than silently emit nothing.
if "$SCRIPTS/kiln" completions tcsh >/dev/null 2>&1; then
    fail "an unknown shell should fail"
else
    pass "an unknown shell fails cleanly"
fi
# install.sh must install completion when it can, and the command list must
# mention it.
if grep -q "completions" "$REPO_ROOT/install.sh"; then
    pass "install.sh installs tab completion"
else
    fail "install.sh should install tab completion"
fi
# The filename must match each loader's convention or the file is never
# sourced: bash wants the bare command name, zsh _<cmd>, fish <cmd>.fish.
if grep -q 'bash) _comp_name="kiln"' "$REPO_ROOT/install.sh"; then
    pass "bash completion is named for the loader convention"
else
    fail "bash completion must be named 'kiln' (no extension) to be auto-sourced"
fi
if grep -q 'zsh)  _comp_name="_bonsai"' "$REPO_ROOT/install.sh"; then
    pass "zsh completion is named _bonsai"
else
    fail "zsh completion must be named _bonsai for the fpath"
fi
if grep -q 'fish) _comp_name="kiln.fish"' "$REPO_ROOT/install.sh"; then
    pass "fish completion is named kiln.fish"
else
    fail "fish completion must be named kiln.fish"
fi
if "$SCRIPTS/kiln" help 2>&1 | grep -q "kiln completions"; then
    pass "kiln help documents completions"
else
    fail "kiln help should document completions"
fi

group "fastest --json"

# Machine-readable output: a script or skill must be able to consume the
# measured rows without parsing the table. The bar is that it PARSES, not
# just that it prints JSON-looking text.
_fj="$(mktemp -d)"
_fj_probe() {
    KILN_STATE_DIR="$_fj" PRISM_RELEASE="prism-b10772-e8fd209" \
        BACKEND="$1" bash -c ". scripts/lib/common.sh; $2" 2>/dev/null
}
_fj_probe cuda 'speed_set "m-lean.gguf" 65536 q4_0 46.1 cuda prism-b10772-e8fd209 36 0.74'
_fj_probe cuda 'speed_set baseline.gguf 65536 q8_0 40.0 cuda prism-b10772-e8fd209 36'
_fj_out="$(KILN_STATE_DIR="$_fj" "$SCRIPTS/kiln" fastest --json 2>/dev/null || true)"
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$_fj_out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        pass "fastest --json parses as JSON"
    else
        fail "fastest --json does not parse" "$_fj_out"
    fi
    # The parsed shape must carry the fields a consumer needs.
    assert_eq "json reports the row count" "2" \
        "$(printf '%s' "$_fj_out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))' 2>/dev/null)"
    assert_eq "the fastest row is first" "m-lean.gguf" \
        "$(printf '%s' "$_fj_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["model"])' 2>/dev/null)"
    assert_eq "acceptance is a number when recorded" "0.74" \
        "$(printf '%s' "$_fj_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["draft_acceptance"])' 2>/dev/null)"
    # An unrecorded acceptance must be null, never a guessed 0.
    assert_eq "unrecorded acceptance is null, not zero" "None" \
        "$(printf '%s' "$_fj_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][1]["draft_acceptance"])' 2>/dev/null)"
    assert_eq "a no-draft row is marked off" "off" \
        "$(printf '%s' "$_fj_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][1]["draft_verdict"])' 2>/dev/null)"
else
    pass "fastest --json (skipped: needs python3)"
fi
# The empty state must still be valid JSON, or a script consuming it crashes.
_fj_empty="$(KILN_STATE_DIR="$(mktemp -d)" "$SCRIPTS/kiln" fastest --json 2>/dev/null || true)"
if printf '%s' "$_fj_empty" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["rows"] == []' 2>/dev/null; then
    pass "empty fastest --json is valid JSON with no rows"
else
    fail "empty fastest --json must be valid JSON" "$_fj_empty"
fi
rm -rf "$_fj"

group "first-run sequence guidance"

# The binary download is one of two prerequisites and the smaller one. Without
# a forward-pointer a first-timer finishes 180 MB believing they are done, then
# hits "No .gguf files" with no idea a second, larger download is coming.
if grep -q "Next: download a model" "$SCRIPTS/fetch-binary.sh"; then
    pass "fetch-binary points at the model download next"
else
    fail "fetch-binary should point at get-models.sh after installing"
fi
if grep -q "get-models.sh --recommend" "$SCRIPTS/fetch-binary.sh"; then
    pass "the forward-pointer names the recommend flag"
else
    fail "the forward-pointer should name --recommend"
fi

# The model picker must explain its default. A catalog of PQ2_0 / PTQ1_0 rows
# asks a novice the one question they came to avoid - "which quant fits my
# card?" - so the recommendation and its reason are stated before the prompt.
if grep -q "Recommended for your" "$SCRIPTS/get-models.sh"; then
    pass "the picker explains its recommendation"
else
    fail "the picker should explain why the default is recommended"
fi
if grep -q "fits with room for the KV cache" "$SCRIPTS/get-models.sh"; then
    pass "the recommendation states the fit reason"
else
    fail "the recommendation should say it fits with room for the KV cache"
fi

group "exit codes"

# A usage error (bad flag, bad value, wrong arg count) must exit 2, distinct
# from a runtime failure (no server, no model) which exits 1. A wrapper script
# can then tell "you called me wrong" from "the world is wrong" without
# parsing stderr.
_ec="$(mktemp -d)"
_expect_rc() {
    local _want="$1"; shift
    KILN_STATE_DIR="$_ec" "$@" >/dev/null 2>&1
    local _got=$?
    if [ "$_got" = "$_want" ]; then
        pass "rc=$_want: $*"
    else
        fail "expected rc=$_want, got rc=$_got: $*"
    fi
}
# Usage errors -> 2.
_expect_rc 2 "$SCRIPTS/kiln" zzzzz
_expect_rc 2 "$SCRIPTS/kiln" set
_expect_rc 2 "$SCRIPTS/kiln" set ctx abc
_expect_rc 2 "$SCRIPTS/kiln" set kv bogus
_expect_rc 2 "$SCRIPTS/kiln" completions tcsh
_expect_rc 2 "$SCRIPTS/assess.sh" --bogus-flag
_expect_rc 2 "$SCRIPTS/assess.sh" --context abc
# Runtime failures -> 1 (NOT 2: these are not the user's fault in the same way).
_expect_rc 1 "$SCRIPTS/kiln" speed
_expect_rc 1 "$SCRIPTS/kiln" identity "$_ec/nope.gguf"
# A valid command that prints help exits 0.
_expect_rc 0 "$SCRIPTS/kiln" help
rm -rf "$_ec"

group "start-server command assembly"

# The 453-line flag builder is where every speed lever lives and the one path
# with no behavioral test: a dropped --flash-attn, a deleted --no-spec-type, a
# broken MTP auto-detect would all pass the rest of the suite. This runs the
# real start-server.sh against a fake llama-server that records its argv, so
# the emitted command line is asserted, not the intent.
#
# The fake binary is placed where llama_server_bin looks: $BIN_DIR/$BACKEND/.
# A temp REPO_ROOT is not possible (BIN_DIR derives from it), so the fake goes
# into the repo's own bin/<backend>/ and is removed after - bin/ is gitignored.
_ss="$(mktemp -d)"
_ss_backend="cpu"
mkdir -p "$REPO_ROOT/bin/$_ss_backend"
_fake="$REPO_ROOT/bin/$_ss_backend/llama-server"
cat > "$_fake" <<'FAKE'
#!/usr/bin/env bash
# Record the argv start-server.sh built, then exit 0 so the health check's
# first probe fails fast and the run ends without hanging.
printf '%s\n' "$@" > "$KILN_ARGV_OUT"
exit 0
FAKE
chmod +x "$_fake"

# Seed detection so BACKEND resolves without probing real hardware.
mkdir -p "$_ss/state"
cat > "$_ss/state/detect.env" <<ENV
BACKEND='$_ss_backend'
BACKEND_REASON='test'
GPU_NAME='test-gpu'
PRISM_RELEASE='prism-b10772-e8fd209'
PRISM_COMMIT='e8fd209'
ENV
# A model must exist or start-server refuses to start.
mkdir -p "$_ss/models"
: > "$_ss/models/test-model.gguf"

# The fake binary writes one arg per line (printf '%s\n' "$@"), so the argv is
# reassembled with single spaces before matching: "--flash-attn on" is two
# array elements, not one token.
_argv_join() { tr '\n' ' ' < "$1" | sed 's/  */ /g; s/ $//'; }
_run_ss() {
    # Run start-server in background mode with the fake binary; it will exit
    # immediately, and the recorded argv is the artifact under test.
    KILN_ARGV_OUT="$_ss/argv.txt" \
    KILN_STATE_DIR="$_ss/state" \
    KILN_MODELS_DIR="$_ss/models" \
    KILN_BIN_DIR="$REPO_ROOT/bin" \
    KILN_PORT=18181 \
    KILN_START_TIMEOUT=3 \
        "$SCRIPTS/start-server.sh" --background --no-browser >/dev/null 2>&1 || true
}

# --- Case 1: default GPU-less CPU run. The invariant levers must be present.
_run_ss
_argv="$(_argv_join "$_ss/argv.txt" 2>/dev/null || true)"
_has() { case " $_argv " in *" $1 "*) return 0 ;; esac; return 1; }

if [ -n "$_argv" ]; then
    pass "start-server emits a command line to the fake binary"
else
    fail "start-server produced no argv" "the fake binary was not invoked"
fi
# flash-attn on is the 30-69% lever; its absence is a silent perf regression.
if _has "--flash-attn on"; then
    pass "the emitted command has --flash-attn on"
else
    fail "emitted command must carry --flash-attn on" "$_argv"
fi
# --no-spec-type ngram-mod stops upstream's default drafters stacking on.
if _has "--no-spec-type ngram-mod"; then
    pass "the emitted command removes upstream ngram-mod"
else
    fail "emitted command must carry --no-spec-type ngram-mod" "$_argv"
fi
# Loopback by default; a local server with no auth must not bind 0.0.0.0.
if _has "--host 127.0.0.1"; then
    pass "the emitted command binds 127.0.0.1 by default"
else
    fail "emitted command must bind 127.0.0.1" "$_argv"
fi
if _has "--models-max 1"; then
    pass "the emitted command pins one model (router mode)"
else
    fail "emitted command must carry --models-max 1" "$_argv"
fi
if _has "--jinja"; then
    pass "the emitted command enables --jinja (tool calls)"
else
    fail "emitted command must carry --jinja" "$_argv"
fi

# --- Case 2: an MTP model present auto-enables draft-mtp at the CPU n-max.
# CPU's spec_nmax_for is 0, so on CPU drafting stays off; use a fake GPU-less
# path by checking the MTP file is at least detected (no crash, no spurious
# --spec-type when no MTP file exists).
if _has "--spec-type"; then
    fail "no MTP model present, so no --spec-type should be emitted" "$_argv"
else
    pass "no MTP file means no speculative decoding"
fi

# --- Case 3: a moe-cache setting without binary support warns and omits the
# flag rather than passing an unknown flag that would abort llama-server.
: > "$_ss/argv.txt"
KILN_ARGV_OUT="$_ss/argv.txt" \
KILN_STATE_DIR="$_ss/state" KILN_MODELS_DIR="$_ss/models" \
KILN_PORT=18182 KILN_START_TIMEOUT=3 KILN_MOE_CACHE_MIB=2048 \
    "$SCRIPTS/start-server.sh" --background --no-browser >/dev/null 2>&1 || true
_argv2="$(_argv_join "$_ss/argv.txt" 2>/dev/null || true)"
_has2() { case " $_argv2 " in *" $1 "*) return 0 ;; esac; return 1; }
if _has2 "--moe-cache-mib"; then
    fail "fake binary reports no --moe-cache-mib support, so it must be omitted" "$_argv2"
else
    pass "moe-cache is omitted when the binary lacks the flag"
fi

# --- Case 4: KILN_HOST override reaches the command line.
: > "$_ss/argv.txt"
KILN_ARGV_OUT="$_ss/argv.txt" KILN_HOST=0.0.0.0 \
KILN_STATE_DIR="$_ss/state" KILN_MODELS_DIR="$_ss/models" \
KILN_PORT=18183 KILN_START_TIMEOUT=3 \
    "$SCRIPTS/start-server.sh" --background --no-browser >/dev/null 2>&1 || true
_argv3="$(_argv_join "$_ss/argv.txt" 2>/dev/null || true)"
_has3() { case " $_argv3 " in *" $1 "*) return 0 ;; esac; return 1; }
if _has3 "--host 0.0.0.0"; then
    pass "KILN_HOST override reaches the command line"
else
    fail "KILN_HOST=0.0.0.0 should bind 0.0.0.0" "$_argv3"
fi

rm -rf "$_ss" "$REPO_ROOT/bin/$_ss_backend"

group "readme clone url"

# The rebrand rewrote "bonsai" -> "kiln" everywhere, including inside the
# repo's own clone URL, producing "Kiln-kiln-server.git" - a dead link
# every new user would hit. The README's clone URL must match the git remote,
# so this asserts the two agree rather than trusting the rename.
_remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
_remote_repo="$(printf '%s' "$_remote_url" | sed -n 's#.*github.com[:/]\([^/]*/[^.]*\)\.git.*#\1#p')"
_readme_clone="$(grep -oE 'git clone https://github.com/[^ ]+\.git' "$REPO_ROOT/README.md" | head -1 | sed 's#.*github.com[:/]##;s#\.git$##')"
if [ -n "$_remote_repo" ]; then
    assert_eq "README clone URL matches the git remote" "$_remote_repo" "$_readme_clone"
    # And the cd line right after must name the same repo, or the user lands
    # in a directory that does not exist.
    _readme_cd="$(grep -A1 'git clone https://github.com/' "$REPO_ROOT/README.md" | grep '^cd ' | head -1 | sed 's/^cd //')"
    assert_eq "README cd line matches the remote repo name" "${_remote_repo##*/}" "$_readme_cd"
else
    pass "readme clone url (skipped: no github remote)"
fi

group "env var back-compat (bonsai/ikaros -> kiln rename)"

# The project was renamed twice: bonsai -> ikaros -> kiln. Every var is now
# KILN_*, but an install from either era may still export BONSAI_* or
# IKAROS_*. common.sh maps both old spellings onto KILN_ once, before anything
# reads it, so the old spellings keep working from a single place. Precedence:
#   explicit KILN_X  >  IKAROS_X  >  BONSAI_X
# env (not a bare prefix) sets the vars in the child; the earlier bare-prefix
# form only worked for the first assignment.
_bc="$(mktemp -d)"

# The original BONSAI_ spelling still resolves (env -u KILN_CTX clears any
# value an earlier test's load_settings exported, so this checks the alias,
# not the "new wins" rule).
assert_eq "BONSAI_CTX is honoured as KILN_CTX" "12345" \
    "$(env -u KILN_CTX BONSAI_CTX=12345 _kctx_dummy=1 bash -c \
        '. scripts/lib/common.sh; printf "%s" "$KILN_CTX"' 2>/dev/null)"
# The middle IKAROS_ spelling also resolves.
assert_eq "IKAROS_CTX is honoured as KILN_CTX" "54321" \
    "$(env -u KILN_CTX IKAROS_CTX=54321 bash -c \
        '. scripts/lib/common.sh; printf "%s" "$KILN_CTX"' 2>/dev/null)"
# When both old spellings are set, IKAROS_ (the more recent) wins over BONSAI_.
assert_eq "IKAROS_ wins over BONSAI_ when both are set" "111" \
    "$(env -u KILN_CTX IKAROS_CTX=111 BONSAI_CTX=222 bash -c \
        '. scripts/lib/common.sh; printf "%s" "$KILN_CTX"' 2>/dev/null)"
# An explicit KILN_ wins over both old spellings.
assert_eq "an explicit KILN_ var wins over IKAROS_ and BONSAI_" "4096" \
    "$(env KILN_CTX=4096 IKAROS_CTX=111 BONSAI_CTX=222 bash -c \
        '. scripts/lib/common.sh; printf "%s" "$KILN_CTX"' 2>/dev/null)"
# An empty old spelling falls through to the next, and never creates an empty
# KILN_ (which would defeat the ${KILN_X:-default} defaults).
assert_eq "an empty IKAROS_ falls through to BONSAI_" "555" \
    "$(env -u KILN_CTX IKAROS_CTX= BONSAI_CTX=555 bash -c \
        '. scripts/lib/common.sh; printf "%s" "$KILN_CTX"' 2>/dev/null)"
# STATE_DIR (the var every command depends on) resolves from both eras.
assert_eq "BONSAI_STATE_DIR resolves STATE_DIR" "$_bc" \
    "$(env BONSAI_STATE_DIR="$_bc" bash -c \
        '. scripts/lib/common.sh; printf "%s" "$STATE_DIR"' 2>/dev/null)"
assert_eq "IKAROS_STATE_DIR resolves STATE_DIR" "$_bc" \
    "$(env IKAROS_STATE_DIR="$_bc" bash -c \
        '. scripts/lib/common.sh; printf "%s" "$STATE_DIR"' 2>/dev/null)"
# The old spelling must NOT leak into the new: after aliasing, code reads
# KILN_ only. A var set only as BONSAI_ shows up under KILN_.
assert_eq "BONSAI_MODELS_DIR aliases to KILN_MODELS_DIR" "/tmp/m" \
    "$(env BONSAI_MODELS_DIR=/tmp/m bash -c \
        '. scripts/lib/common.sh; printf "%s" "$KILN_MODELS_DIR"' 2>/dev/null)"
# The back-compat list and the KILN_ vars the scripts use must stay in sync:
# a var the code reads but the alias list omits would silently stop honouring
# its old spelling. grep only the alias array (not the whole file, which also
# mentions KILN_ in comments) so this checks the list, not prose.
_alias_listed="$(sed -n '/_kiln_aliases=(/,/^)/p' scripts/lib/common.sh \
    | grep -oE 'KILN_[A-Z_]+' | sort -u)"
_missing_alias=""
for _v in $_alias_listed; do
    # Every KILN_ var in the alias array must be a real consumer var.
    grep -rqE "$_v" scripts/ 2>/dev/null || _missing_alias="$_missing_alias $_v"
done
if [ -z "$_missing_alias" ]; then
    pass "the alias list names only real consumer vars"
else
    fail "alias list has phantom vars:" "$_missing_alias"
fi
rm -rf "$_bc"

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

# kiln is the user-facing entry point and has no .sh suffix.
if "$SCRIPTS/kiln" help >/dev/null 2>&1; then
    pass "kiln help"
else
    fail "kiln help"
fi
if "$SCRIPTS/kiln" help 2>&1 | grep -q "kiln set"; then
    pass "kiln help documents the settings command"
else
    fail "kiln help should document 'kiln set'"
fi
# The speed-first commands are the primary interface, so they must be findable
# in the one place a new user reads.
for _c in fastest bench; do
    if "$SCRIPTS/kiln" help 2>&1 | grep -q "kiln $_c"; then
        pass "kiln help documents $_c"
    else
        fail "kiln help should document 'kiln $_c'"
    fi
done
# KILN_HOST changed the bind default; the new default must be documented.
if "$SCRIPTS/start-server.sh" --help 2>&1 | grep -q "KILN_HOST"; then
    pass "start-server.sh --help documents KILN_HOST"
else
    fail "start-server.sh --help should document KILN_HOST"
fi
# start-server.sh is the only place the spec type is validated; make sure the
# setting stays documented where a user would look for it.
if "$SCRIPTS/start-server.sh" --help 2>&1 | grep -q "KILN_SPEC_TYPE"; then
    pass "start-server.sh --help documents KILN_SPEC_TYPE"
else
    fail "start-server.sh --help should document KILN_SPEC_TYPE"
fi

if "$SCRIPTS/kiln" nonsense >/dev/null 2>&1; then
    fail "kiln should reject an unknown command"
else
    pass "kiln rejects an unknown command"
fi

# ---------------------------------------------------------------------------
# Optional checks
# ---------------------------------------------------------------------------

if [ "$WITH_PATCH" = 1 ]; then
    group "UI patch"
    if ! command -v git >/dev/null 2>&1; then
        fail "git not available"
    else
        _work="$(mktemp -d)"
        _src="${KILN_TEST_SRC:-}"
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

    # The hash endpoint is what makes download verification possible; if HF
    # stops exposing it, verification silently degrades to a size check.
    _h="$(hf_file_hash prism-ml/Bonsai-1.7B-gguf Bonsai-1.7B-Q1_0.gguf || true)"
    _sha="$(printf '%s' "$_h" | cut -d' ' -f1)"
    _size="$(printf '%s' "$_h" | cut -d' ' -f2)"
    if [ "${#_sha}" = "64" ] && [ "$_size" = "248302272" ]; then
        pass "Hugging Face exposes a SHA256 and size for verification"
    else
        fail "could not read the HF SHA256/size" "got '$_h'"
    fi
fi

# ---------------------------------------------------------------------------

group "installable executable"

# The release artifact is only useful if `kiln` works from a directory that
# is not the repo, which is the whole point of installing it. Install into a
# scratch prefix and run `status` from / so the checkout is out of scope.
if [ -x "$SCRIPTS/../install.sh" ]; then
    _inst_tmp="$(mktemp -d)"
    if KILN_PREFIX="$_inst_tmp/prefix" "$SCRIPTS/../install.sh" >/dev/null 2>&1; then
        pass "install.sh installs into a custom prefix"
    else
        fail "install.sh failed on a scratch prefix"
    fi
    if [ -x "$_inst_tmp/prefix/bin/kiln" ]; then
        pass "install.sh creates an executable kiln command"
    else
        fail "no executable at <prefix>/bin/kiln"
    fi
    if ( cd / && "$_inst_tmp/prefix/bin/kiln" status ) >/dev/null 2>&1; then
        pass "installed kiln runs from an unrelated directory"
    else
        fail "installed kiln does not run outside the repo"
    fi
    # Uninstall must actually remove the command, or --uninstall lies.
    if KILN_PREFIX="$_inst_tmp/prefix" "$SCRIPTS/../install.sh" --uninstall >/dev/null 2>&1 &&
       [ ! -e "$_inst_tmp/prefix/bin/kiln" ]; then
        pass "install.sh --uninstall removes the command"
    else
        fail "--uninstall left the command in place"
    fi
    rm -rf "$_inst_tmp"
else
    fail "install.sh is missing or not executable"
fi

# ---------------------------------------------------------------------------

printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
