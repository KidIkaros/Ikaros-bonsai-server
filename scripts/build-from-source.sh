#!/usr/bin/env bash
# build-from-source.sh - build llama-server from the PrismML fork with the
# speed-log UI patch applied.
#
# The prebuilt binaries in the official releases are built from unmodified
# upstream source, so they cannot contain this project's UI changes. This script
# clones the fork at a pinned commit, applies patches/, and builds.
#
# Because building the UI from source is required for the patch to take effect,
# this path needs Node.js and a C++ toolchain. It also takes considerably longer
# than ./scripts/fetch-binary.sh.
#
# Usage:
#   ./scripts/build-from-source.sh              build for the detected backend
#   ./scripts/build-from-source.sh --check      apply the patch to a scratch
#                                               clone and stop (fast sanity test)
#   ./scripts/build-from-source.sh --jobs 8     limit build parallelism
#
# A source build is the only way to get flags newer than the pinned prebuilt:
# it reports which decode-speed capabilities the result carries
# (--moe-cache-mib, --spec-type) by checking the binary's own --help, so the
# build's value is visible rather than assumed. See
# docs/SPEED-BEYOND-MTP-2026-10.md for what each is worth.
#
# Overrides:
#   BACKEND=cpu|vulkan|cuda|rocm   force a backend
#   PRISM_COMMIT=<sha>             build a different fork commit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CHECK_ONLY=0
JOBS="$(nproc 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --jobs)  JOBS="${2:-4}"; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

if detect_is_stale || [ -n "${BACKEND:-}" ]; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

PATCH="$REPO_ROOT/patches/0001-speedlog-ema-tps.patch"
[ -f "$PATCH" ] || die "Patch not found: $PATCH"

SRC_DIR="${KILN_SRC_DIR:-$REPO_ROOT/.build/llama.cpp}"
DEST="$BIN_DIR/$BACKEND-patched"

# ---------------------------------------------------------------------------
# Fetch the pinned source
# ---------------------------------------------------------------------------

step "Preparing source"
info "Fork   : $PRISM_REPO"
info "Commit : $PRISM_COMMIT"

if [ -d "$SRC_DIR/.git" ] && [ -z "${KILN_SRC_FORCE:-}" ]; then
    info "Reusing existing checkout at $SRC_DIR"
else
    rm -rf "$SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git init -q "$SRC_DIR"
    git -C "$SRC_DIR" remote add origin "https://github.com/$PRISM_REPO.git"
fi

info "Fetching commit $PRISM_COMMIT (this downloads the source tree)"
# GitHub serves a fetch by full sha; an abbreviated sha is not a valid ref.
if ! git -C "$SRC_DIR" fetch --depth 1 origin "$PRISM_COMMIT_FULL"; then
    warn "Could not fetch $PRISM_COMMIT_FULL directly."
    warn "Falling back to the tip of the fork's main branch, which may differ."
    git -C "$SRC_DIR" fetch --depth 1 origin HEAD ||
        die "Could not fetch from $PRISM_REPO."
fi

git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD
_actual="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$_actual" != "$PRISM_COMMIT_FULL" ]; then
    warn "Checked out $_actual, not the pinned $PRISM_COMMIT_FULL."
    warn "The patch may not apply; regenerate it if the UI changed."
fi

# Start from a clean tree so re-runs are predictable.
git -C "$SRC_DIR" reset -q --hard
git -C "$SRC_DIR" clean -qfd -e node_modules -e dist

# ---------------------------------------------------------------------------
# Apply the patch
# ---------------------------------------------------------------------------

step "Applying patch"
if git -C "$SRC_DIR" apply --check "$PATCH"; then
    git -C "$SRC_DIR" apply "$PATCH"
    info "Applied $(basename "$PATCH")"
else
    die "Patch does not apply to $PRISM_COMMIT. The upstream UI likely changed;
       regenerate the patch against the new commit."
fi

if [ "$CHECK_ONLY" = 1 ]; then
    info "Patch applies cleanly. Stopping (--check)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

command -v cmake >/dev/null 2>&1 || die "cmake not found. Install it and re-run."
if ! command -v node >/dev/null 2>&1; then
    die "Node.js not found. The UI is built from source here, so Node is required.
       Install Node 20+, or use ./scripts/fetch-binary.sh instead (no UI patch)."
fi

BACKEND_FLAGS=()
case "$BACKEND" in
    cpu)    BACKEND_FLAGS=(-DGGML_VULKAN=OFF -DGGML_CUDA=OFF -DGGML_HIP=OFF) ;;
    vulkan) BACKEND_FLAGS=(-DGGML_VULKAN=ON) ;;
    cuda)   BACKEND_FLAGS=(-DGGML_CUDA=ON) ;;
    rocm)
        [ -n "$ROCM_PREFIX" ] || die "No ROCm installation found; cannot build the HIP backend."
        # CMAKE_PREFIX_PATH is required: without it find_package(hip) fails and
        # the configure step dies with "Could not find a package configuration
        # file provided by hip", which does not point at the real cause.
        BACKEND_FLAGS=(
            -DGGML_HIP=ON
            -DCMAKE_PREFIX_PATH="$ROCM_PREFIX"
            -DCMAKE_HIP_COMPILER="$ROCM_PREFIX/lib/llvm/bin/clang++"
        )
        if [ -n "$ROCM_GFX" ]; then
            BACKEND_FLAGS+=(-DCMAKE_HIP_ARCHITECTURES="$ROCM_GFX" -DAMDGPU_TARGETS="$ROCM_GFX")
        fi
        ;;
esac

# LLAMA_USE_PREBUILT_UI must be OFF: a downloaded UI bundle would not carry the
# patch, which would make this build indistinguishable from the prebuilt.
step "Configuring ($BACKEND)"
cmake -S "$SRC_DIR" -B "$SRC_DIR/build-$BACKEND" \
    -DCMAKE_BUILD_TYPE=Release \
    "${BACKEND_FLAGS[@]}" \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_UI=ON \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF

step "Building with $JOBS jobs"
cmake --build "$SRC_DIR/build-$BACKEND" --config Release -j "$JOBS" --target llama-server

# ---------------------------------------------------------------------------
# Verify the patch actually made it into the binary
# ---------------------------------------------------------------------------

step "Verifying the UI patch landed"

BUILT_BIN="$SRC_DIR/build-$BACKEND/bin/llama-server"
[ -f "$BUILT_BIN" ] || die "Build finished but $BUILT_BIN is missing."

# The built UI is embedded into the server. Search the compiled bundle for the
# speed log's storage key, which only exists when the patch is present.
_ui_dist="$SRC_DIR/build-$BACKEND/tools/ui/dist"
_found=0
if [ -d "$_ui_dist" ] && grep -rqs "bonsai_speed_log" "$_ui_dist" 2>/dev/null; then
    _found=1
elif grep -aqs "bonsai_speed_log" "$BUILT_BIN" 2>/dev/null; then
    _found=1
fi

if [ "$_found" = 1 ]; then
    info "Speed-log UI patch confirmed present in the build."
else
    warn "Could not confirm the speed-log patch in the build output."
    warn "The server will still work; only the extra UI panel may be missing."
fi

# Report the decode-speed flags this build carries beyond the pinned prebuilt.
# A source build is the only way to get these, so the report is what tells the
# user whether the long build bought anything they will actually use:
#   --moe-cache-mib   1.5-1.85x decode on CPU-resident MoE experts (PR #29887)
#   CUDA graphs       Volta/Turing enabled (PR #25749)
# Every line is checked against the binary's own --help, never assumed.
step "Decode-speed capabilities of this build"
_help_text="$("$BUILT_BIN" --help 2>&1 || true)"
if printf '%s' "$_help_text" | grep -q -- '--moe-cache-mib'; then
    info "--moe-cache-mib present (MoE expert cache; +1.5-1.85x decode, PR #29887)."
    dim "  Use it: KILN_MOE_CACHE_MIB=2048 ./scripts/start-server.sh"
else
    dim "  --moe-cache-mib not in this build (needs a newer llama.cpp than $PRISM_COMMIT)."
fi
if printf '%s' "$_help_text" | grep -q -- '--spec-type'; then
    dim "  --spec-type present (draft-mtp, ngram-* and the other spec types)."
else
    warn "--spec-type missing from this build; speculative decoding is unavailable."
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC_DIR/build-$BACKEND/bin/." "$DEST/"
printf '%s' "$PRISM_COMMIT+ui-patch" > "$DEST/.llama_release"

info "Installed to $DEST"
dim "  This build now takes precedence over the prebuilt binary."
dim "  Remove it with: rm -rf $DEST"
echo ""
info "Start the server: ./scripts/start-server.sh"
