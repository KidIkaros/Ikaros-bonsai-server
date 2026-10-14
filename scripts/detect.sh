#!/usr/bin/env bash
# detect.sh - probe this machine and decide which backend to use.
#
# Writes a shell-sourceable cache to .state/detect.env so every other script
# consumes the same result instead of re-deriving it.
#
# Nothing here is specific to any one machine: no hardcoded GPU model, no
# hardcoded ROCm version, no hardcoded gfx target.
#
# Usage:
#   ./scripts/detect.sh              probe and write the cache
#   ./scripts/detect.sh --json       machine-readable output
#
# Overrides:
#   BACKEND=cuda|rocm|vulkan|cpu     force a backend
#   ROCM_PATH=/opt/rocm-7.2.0        force a ROCm prefix
#   KILN_FAKE_*                    test hooks, see tests/fixtures/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

JSON=0
for arg in "$@"; do
    case "$arg" in
        --json) JSON=1 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

# Honour a user-forced backend, then stop treating BACKEND as an input.
BACKEND_OVERRIDE="${BACKEND:-}"
[ "$BACKEND_OVERRIDE" = "auto" ] && BACKEND_OVERRIDE=""

# ---------------------------------------------------------------------------
# Test hooks - every probe reads through these so fixtures can drive it.
# ---------------------------------------------------------------------------

_uname_s() { printf '%s' "${KILN_FAKE_UNAME_S:-$(uname -s)}"; }
_uname_m() { printf '%s' "${KILN_FAKE_UNAME_M:-$(uname -m)}"; }

_cpuinfo() {
    if [ -n "${KILN_FAKE_CPUINFO+set}" ]; then
        [ -n "$KILN_FAKE_CPUINFO" ] && cat "$KILN_FAKE_CPUINFO"
    elif [ -r /proc/cpuinfo ]; then
        cat /proc/cpuinfo
    fi
    return 0
}

_lspci() {
    if [ -n "${KILN_FAKE_LSPCI+set}" ]; then
        [ -n "$KILN_FAKE_LSPCI" ] && cat "$KILN_FAKE_LSPCI"
    elif command -v lspci >/dev/null 2>&1; then
        lspci 2>/dev/null
    fi
    return 0
}

_nvidia_smi_version() {
    # A set-but-empty value means "pretend nvidia-smi is absent".
    if [ -n "${KILN_FAKE_NVIDIA_SMI+set}" ]; then
        [ -n "$KILN_FAKE_NVIDIA_SMI" ] &&
            sed -n 's/.*CUDA[ A-Z]*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$KILN_FAKE_NVIDIA_SMI"
        return 0
    fi
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    nvidia-smi 2>/dev/null | sed -n 's/.*CUDA[ A-Z]*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' || true
}

_nvcc_version() {
    command -v nvcc >/dev/null 2>&1 || return 0
    nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p' || true
}

_vram_bytes() {
    if [ -n "${KILN_FAKE_VRAM_BYTES:-}" ]; then printf '%s' "$KILN_FAKE_VRAM_BYTES"; return 0; fi
    _v="$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | head -1 || true)"
    if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        _mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
        if [ -n "$_mib" ]; then printf '%s' "$(( _mib * 1024 * 1024 ))"; return 0; fi
    fi
    printf '0'
}

_ram_bytes() {
    if [ -n "${KILN_FAKE_RAM_KB:-}" ]; then printf '%s' "$(( KILN_FAKE_RAM_KB * 1024 ))"; return 0; fi
    _kb="$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null | head -1 || true)"
    if [ -n "$_kb" ]; then printf '%s' "$(( _kb * 1024 ))" ; else printf '0'; fi
}

# Discover a ROCm installation prefix.
_rocm_prefix() {
    # A set-but-empty value means "pretend no ROCm is installed".
    if [ -n "${KILN_FAKE_ROCM_PREFIX+set}" ]; then printf '%s' "$KILN_FAKE_ROCM_PREFIX"; return 0; fi
    if [ -n "${ROCM_PATH:-}" ] && [ -d "$ROCM_PATH" ]; then printf '%s' "$ROCM_PATH"; return 0; fi
    # Collect /opt/rocm-* then order newest version first, so a system with
    # several ROCm installs prefers the most recent one.
    _cands=()
    for _c in /opt/rocm-*; do
        [ -d "$_c" ] && _cands+=("$_c")
    done
    if [ "${#_cands[@]}" -gt 0 ]; then
        mapfile -t _cands < <(printf '%s\n' "${_cands[@]}" | sort -V -r)
    fi
    _cands+=(/opt/rocm)

    for _c in "${_cands[@]}"; do
        if [ -d "$_c" ] && { [ -x "$_c/bin/hipcc" ] || [ -e "$_c/lib/cmake/hip" ] || [ -x "$_c/bin/rocm_agent_enumerator" ]; }; then
            printf '%s' "${_c%/}"; return 0
        fi
    done
    printf ''
}

_rocm_version() {
    _p="$1"
    [ -n "$_p" ] || { printf ''; return 0; }
    if [ -n "${KILN_FAKE_ROCM_VERSION+set}" ]; then printf '%s' "$KILN_FAKE_ROCM_VERSION"; return 0; fi
    if [ -r "$_p/.info/version" ]; then
        sed -n 's/^\([0-9][0-9.]*\).*/\1/p' "$_p/.info/version" | head -1 || true
        return 0
    fi
    if [ -x "$_p/bin/hipcc" ]; then
        "$_p/bin/hipcc" --version 2>/dev/null | sed -n 's/^HIP version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1 || true
        return 0
    fi
    printf ''
}

# Ask ROCm which gfx target the installed card reports.
_rocm_gfx() {
    if [ -n "${KILN_FAKE_ROCM_GFX+set}" ]; then printf '%s' "$KILN_FAKE_ROCM_GFX"; return 0; fi
    _p="$1"
    [ -n "$_p" ] || { printf ''; return 0; }
    for _e in "$_p/bin/rocm_agent_enumerator" "$_p/libexec/rocm_agent_enumerator"; do
        if [ -x "$_e" ]; then
            "$_e" 2>/dev/null | grep -v '^gfx000$' | grep '^gfx' | head -1 || true
            return 0
        fi
    done
    printf ''
}

_has_vulkan() {
    if [ -n "${KILN_FAKE_VULKAN:-}" ]; then
        [ "$KILN_FAKE_VULKAN" = "1" ]
        return
    fi
    command -v vulkaninfo >/dev/null 2>&1 || return 1
    vulkaninfo --summary >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------

step "Detecting hardware and backend"

OS="$(_uname_s)"
ARCH_RAW="$(_uname_m)"
case "$ARCH_RAW" in
    x86_64|amd64)  ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)             ARCH="$ARCH_RAW" ;;
esac
info "OS: $OS   arch: $ARCH"

# AVX512 - only relevant to the CPU 1-bit kernel. Absence is fine, just slower.
AVX512=0
if _cpuinfo | grep -q 'avx512f'; then AVX512=1; fi
if [ "$AVX512" = 1 ]; then
    info "AVX512: present"
else
    info "AVX512: absent (fine, the CPU 1-bit kernel falls back to scalar)"
fi

# GPU vendor from PCI.
GPU_VENDOR="none"
GPU_NAME="(no PCI display device found)"
_pci="$(_lspci | grep -iE 'vga|3d controller|display' || true)"

# Match on vendor names, not loose substrings: a bare 'ati' also matches
# "Corporation", which would misclassify every NVIDIA card.
_pci_line=""
if printf '%s' "$_pci" | grep -qE 'NVIDIA'; then
    GPU_VENDOR="nvidia"; _pci_line="$(printf '%s' "$_pci" | grep -E 'NVIDIA' | head -1)"
elif printf '%s' "$_pci" | grep -qE 'Advanced Micro Devices|\[AMD/ATI\]|\bAMD\b|\bATI\b'; then
    GPU_VENDOR="amd";    _pci_line="$(printf '%s' "$_pci" | grep -E 'Advanced Micro Devices|\[AMD/ATI\]|\bAMD\b|\bATI\b' | head -1)"
elif printf '%s' "$_pci" | grep -qE 'Intel'; then
    GPU_VENDOR="intel";  _pci_line="$(printf '%s' "$_pci" | grep -E 'Intel' | head -1)"
fi

if [ -n "$_pci_line" ]; then
    GPU_NAME="$(printf '%s' "$_pci_line" | sed 's/.*controller: *//')"
fi
info "GPU: $GPU_NAME"

VRAM_BYTES="$(_vram_bytes)"
VRAM_GB=$(( VRAM_BYTES / 1024 / 1024 / 1024 ))
RAM_BYTES="$(_ram_bytes)"
RAM_GB=$(( RAM_BYTES / 1024 / 1024 / 1024 ))
if [ "$VRAM_GB" -gt 0 ]; then info "VRAM: ${VRAM_GB} GB"; fi
info "RAM:  ${RAM_GB} GB"

ROCM_PREFIX="$(_rocm_prefix)"
ROCM_VERSION=""
ROCM_GFX=""
if [ -n "$ROCM_PREFIX" ]; then
    ROCM_VERSION="$(_rocm_version "$ROCM_PREFIX")"
    ROCM_GFX="$(_rocm_gfx "$ROCM_PREFIX")"
    info "ROCm: $ROCM_PREFIX${ROCM_VERSION:+ (version $ROCM_VERSION)}${ROCM_GFX:+, gfx $ROCM_GFX}"
fi

CUDA_VERSION="$(_nvidia_smi_version)"
if [ -z "$CUDA_VERSION" ]; then CUDA_VERSION="$(_nvcc_version)"; fi
[ -n "$CUDA_VERSION" ] && info "CUDA: $CUDA_VERSION"

# ---------------------------------------------------------------------------
# Backend selection: CUDA -> ROCm -> Vulkan -> CPU
# ---------------------------------------------------------------------------

# gfx targets the pinned prebuilt is compiled for. Keep in sync with GPU_TARGETS
# in the upstream PrismML release workflow.
PRISM_GFX_TARGETS="gfx908 gfx90a gfx942 gfx1030 gfx1031 gfx1032 gfx1100 gfx1101 gfx1102 gfx1150 gfx1151 gfx1200 gfx1201"

# asset_for BACKEND - print the release asset name, or nothing when unavailable.
asset_for() {
    _backend="$1"
    case "$_backend" in
        cpu)    printf 'llama-%s-bin-ubuntu-%s.tar.gz' "$PRISM_RELEASE" "$ARCH" ;;
        rocm)
            if [ "$ARCH" = "x64" ]; then printf 'llama-%s-bin-ubuntu-rocm-7.2-x64.tar.gz' "$PRISM_RELEASE"; fi
            ;;
        vulkan) printf 'llama-%s-bin-ubuntu-vulkan-%s.tar.gz' "$PRISM_RELEASE" "$ARCH" ;;
        cuda)
            if [ "$ARCH" = "x64" ]; then
                if version_ge "$CUDA_VERSION" "13.3"; then _tag="13.3"
                elif version_ge "$CUDA_VERSION" "12.8"; then _tag="12.8"
                else _tag="12.4"
                fi
                printf 'llama-%s-bin-linux-cuda-%s-x64.tar.gz' "$PRISM_RELEASE" "$_tag"
            fi
            ;;
    esac
}

BACKEND=""
BACKEND_REASON=""

if [ -n "${BACKEND_OVERRIDE:-}" ]; then
    BACKEND="$BACKEND_OVERRIDE"
    _asset="$(asset_for "$BACKEND")"
    [ -n "$_asset" ] || die "Backend '$BACKEND' has no prebuilt for OS=$OS arch=$ARCH."
    BACKEND_REASON="forced"
else
    # Walk the candidates in order and take the first one that actually has a
    # prebuilt asset for this OS and architecture. A CUDA runtime on arm64, for
    # example, has no asset and must fall through rather than fail later.
    BACKEND=""
    BACKEND_REASON=""

    if [ -n "$CUDA_VERSION" ] && [ "$GPU_VENDOR" = "nvidia" ]; then
        if [ -n "$(asset_for cuda)" ]; then
            BACKEND="cuda"; BACKEND_REASON="NVIDIA GPU with CUDA $CUDA_VERSION"
        else
            warn "CUDA $CUDA_VERSION found, but no prebuilt CUDA asset for arch $ARCH."
        fi
    fi

    if [ -z "$BACKEND" ] && [ -n "$ROCM_PREFIX" ] && [ "$GPU_VENDOR" = "amd" ] && [ -n "$(asset_for rocm)" ]; then
        if version_ge "${ROCM_VERSION:-0}" "7.2"; then
            BACKEND="rocm"; BACKEND_REASON="AMD GPU with ROCm $ROCM_VERSION"
        else
            warn "ROCm ${ROCM_VERSION:-unknown} found; the pinned prebuilt targets ROCm 7.2."
            warn "Build from source for a matching HIP build: ./scripts/build-from-source.sh"
        fi
    fi

    if [ -z "$BACKEND" ] && _has_vulkan && [ -n "$(asset_for vulkan)" ]; then
        BACKEND="vulkan"; BACKEND_REASON="Vulkan runtime available"
    fi

    if [ -z "$BACKEND" ]; then
        BACKEND="cpu"; BACKEND_REASON="no usable GPU runtime, using CPU"
    fi
fi

info "Backend: $BACKEND ($BACKEND_REASON)"

# Warn when the GPU is a gfx target the prebuilt does not cover.
GFX_SUPPORTED=1
if [ "$BACKEND" = "rocm" ] && [ -n "$ROCM_GFX" ]; then
    GFX_SUPPORTED=0
    for _t in $PRISM_GFX_TARGETS; do
        [ "$ROCM_GFX" = "$_t" ] && GFX_SUPPORTED=1
    done
    if [ "$GFX_SUPPORTED" = 0 ]; then
        warn "gfx target $ROCM_GFX is not in the pinned prebuilt's GPU_TARGETS."
        warn "Either build from source (./scripts/build-from-source.sh), or try"
        warn "  HSA_OVERRIDE_GFX_VERSION=<supported> with a matching gfx value."
        warn "Supported: $PRISM_GFX_TARGETS"
    fi
fi

ASSET="$(asset_for "$BACKEND")"
[ -n "$ASSET" ] || die "No prebuilt asset resolved for backend '$BACKEND'."

if [ "$BACKEND" = "vulkan" ]; then
    warn "Vulkan has only partial PQ2_0/PTQ1_0 support; prefer Q2_0_g64 or Q1_0 files."
fi

# ---------------------------------------------------------------------------
# Persist
# ---------------------------------------------------------------------------

mkdir -p "$STATE_DIR"
{
    printf '# Generated by scripts/detect.sh - do not edit by hand.\n'
    printf "DETECTED_AT='%s'\n" "$(date -Iseconds)"
    printf "OS='%s'\n" "$OS"
    printf "ARCH='%s'\n" "$ARCH"
    printf "AVX512='%s'\n" "$AVX512"
    printf "GPU_VENDOR='%s'\n" "$GPU_VENDOR"
    printf "GPU_NAME='%s'\n" "$GPU_NAME"
    printf "VRAM_GB='%s'\n" "$VRAM_GB"
    printf "RAM_GB='%s'\n" "$RAM_GB"
    printf "ROCM_PREFIX='%s'\n" "$ROCM_PREFIX"
    printf "ROCM_VERSION='%s'\n" "$ROCM_VERSION"
    printf "ROCM_GFX='%s'\n" "$ROCM_GFX"
    printf "GFX_SUPPORTED='%s'\n" "$GFX_SUPPORTED"
    printf "CUDA_VERSION='%s'\n" "$CUDA_VERSION"
    printf "BACKEND='%s'\n" "$BACKEND"
    printf "BACKEND_REASON='%s'\n" "$BACKEND_REASON"
    printf "ASSET='%s'\n" "$ASSET"
    printf "PRISM_RELEASE='%s'\n" "$PRISM_RELEASE"
    printf "PRISM_COMMIT='%s'\n" "$PRISM_COMMIT"
    printf "BACKEND_BIN_DIR='%s'\n" "$BIN_DIR/$BACKEND"
} > "$DETECT_ENV"

if [ "$JSON" = 1 ]; then
    printf '{'
    printf '"os": "%s", ' "$OS"
    printf '"arch": "%s", ' "$ARCH"
    printf '"avx512": %s, ' "$AVX512"
    printf '"gpu_vendor": "%s", ' "$GPU_VENDOR"
    printf '"gpu_name": "%s", ' "$(printf '%s' "$GPU_NAME" | sed 's/"/\\"/g')"
    printf '"vram_gb": %s, ' "$VRAM_GB"
    printf '"ram_gb": %s, ' "$RAM_GB"
    printf '"rocm_prefix": "%s", ' "$ROCM_PREFIX"
    printf '"rocm_version": "%s", ' "$ROCM_VERSION"
    printf '"rocm_gfx": "%s", ' "$ROCM_GFX"
    printf '"gfx_supported": %s, ' "$GFX_SUPPORTED"
    printf '"cuda_version": "%s", ' "$CUDA_VERSION"
    printf '"backend": "%s", ' "$BACKEND"
    printf '"backend_reason": "%s", ' "$BACKEND_REASON"
    printf '"asset": "%s", ' "$ASSET"
    printf '"release": "%s"' "$PRISM_RELEASE"
    printf '}\n'
else
    info "Detection written to $DETECT_ENV"
fi
