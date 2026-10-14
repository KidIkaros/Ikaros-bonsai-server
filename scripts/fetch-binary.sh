#!/usr/bin/env bash
# fetch-binary.sh - download the pinned PrismML prebuilt for this machine.
#
# Reads .state/detect.env (run ./scripts/detect.sh first, or just ./setup.sh)
# and extracts into bin/<backend>/. Re-running is cheap: the tarball is cached
# and a release stamp prevents pointless re-extraction.
#
# Usage:
#   ./scripts/fetch-binary.sh            fetch for the detected backend
#   ./scripts/fetch-binary.sh --force    re-download even if cached
#
# Overrides:
#   BACKEND=cpu ./scripts/fetch-binary.sh
#   PRISM_RELEASE=prism-bNNNNN-abcdef1 ./scripts/fetch-binary.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

# Re-run detection when there is no cache, or when a backend was forced.
if detect_is_stale || [ -n "${BACKEND:-}" ]; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

[ "$OS" = "Linux" ] || die "Prebuilt assets here are Linux-only (detected OS: $OS)."

DEST="$BIN_DIR/$BACKEND"
CACHE_DIR="$BIN_DIR/.cache"
TARBALL="$CACHE_DIR/$ASSET"
URL="https://github.com/$PRISM_REPO/releases/download/$PRISM_RELEASE/$ASSET"

# A CUDA build must refresh when the resolved CUDA tag changes.
STAMP="$PRISM_RELEASE"
if [ "$BACKEND" = "cuda" ] && [ -n "$CUDA_VERSION" ]; then
    STAMP="$PRISM_RELEASE cuda-$CUDA_VERSION"
fi

if [ "$FORCE" = 0 ] && [ -f "$DEST/.llama_release" ] && [ "$(cat "$DEST/.llama_release")" = "$STAMP" ]; then
    info "Binaries already present in bin/$BACKEND/ ($STAMP)."
    exit 0
fi

step "Fetching prebuilt binary"
info "Backend : $BACKEND"
info "Release : $PRISM_RELEASE"
info "Asset   : $ASSET"

have_downloader || die "Neither curl nor wget found. Install one and re-run."

mkdir -p "$CACHE_DIR"

if [ "$FORCE" = 1 ] && [ -f "$TARBALL" ]; then
    rm -f "$TARBALL"
fi

if [ -f "$TARBALL" ]; then
    info "Using cached download: $TARBALL"
else
    info "Downloading $URL"
    download "$URL" "$TARBALL"
fi

# A truncated or error-page download is the most common failure. Catch it here
# rather than with an opaque tar error.
if ! gzip -t "$TARBALL" 2>/dev/null; then
    rm -f "$TARBALL"
    die "Downloaded file is not a valid gzip archive. Removed it; re-run to retry."
fi

step "Extracting"

TMP_EXTRACT="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$TMP_EXTRACT'" EXIT

tar -xzf "$TARBALL" -C "$TMP_EXTRACT"

# The archive layout has changed upstream before: it may nest everything under a
# single version directory, may have a bin/ subdirectory, or may be flat. Locate
# the real binary and treat its containing directory as the payload root, since
# the server needs its sibling shared libraries alongside it.
_found="$(find "$TMP_EXTRACT" -type f -name llama-server -print -quit 2>/dev/null || true)"
[ -n "$_found" ] || die "Archive does not contain llama-server. Layout may have changed upstream."

PAYLOAD="$(dirname "$_found")"
if [ "$(basename "$PAYLOAD")" = "bin" ]; then
    PAYLOAD="$(dirname "$PAYLOAD")"
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$PAYLOAD/." "$DEST/"

printf '%s' "$STAMP" > "$DEST/.llama_release"

SERVER_BIN="$(llama_server_bin)" || die "Expected a llama-server binary under $DEST after extraction."
chmod +x "$DEST/llama-server" "$DEST/bin/llama-server" 2>/dev/null || true

step "Verifying"

if "$SERVER_BIN" --version >/dev/null 2>&1; then
    _v="$("$SERVER_BIN" --version 2>&1 | head -1)"
    info "llama-server OK: $_v"
else
    warn "llama-server did not run cleanly. On a HIP build this usually means the"
    warn "ROCm runtime version does not match the prebuilt (targets ROCm 7.2)."
    warn "Try: ./scripts/build-from-source.sh"
    exit 1
fi

info "Installed to $DEST"
dim "  server: $SERVER_BIN"
echo ""
# The binary is one of two prerequisites, and it is the smaller one. Without
# a forward-pointer a first-time user finishes a 180 MB download believing
# they are done, then hits "No .gguf files" with no idea a second, larger
# download is coming.
info "Next: download a model, then start the server:"
dim "  ./scripts/get-models.sh --recommend   # the best fit for this machine"
dim "  ./scripts/start-server.sh"
