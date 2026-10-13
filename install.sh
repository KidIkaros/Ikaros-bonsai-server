#!/usr/bin/env bash
# install.sh - put the `bonsai` command on this machine's PATH.
#
# Like `pip install` for the project: after this, `bonsai` works from any
# directory, in any shell, without cloning or exporting anything.
#
# What it does:
#   1. picks an install prefix (~/.local by default, or --prefix)
#   2. copies the scripts there, so no absolute paths are baked in
#   3. symlinks `bonsai` into the prefix's bin/ (which it adds to PATH
#      guidance if needed)
#
# The install is self-contained: it does not reference the repo it was run
# from. Updating means re-running this script from a newer checkout.
#
# Usage:
#   ./install.sh                 install to ~/.local
#   ./install.sh --prefix /opt/bonsai
#   ./install.sh --uninstall     remove a previous install
#   ./install.sh --status        show what is installed and where
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${BONSAI_PREFIX:-$HOME/.local}"
UNINSTALL=0
STATUS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)     PREFIX="${2:-}"; shift ;;
        --uninstall)  UNINSTALL=1 ;;
        --status)     STATUS=1 ;;
        -h|--help)    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# The prefix's bin/ must exist for the symlink target to be valid.
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/ikaros-bonsai"
STATE_DIR="$PREFIX/state"
LINK="$BIN_DIR/bonsai"
MARKER="$LIB_DIR/.installed-from"

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
if [ "$STATUS" = 1 ]; then
    if [ -L "$LINK" ] || [ -f "$LINK" ]; then
        echo "installed: $LINK -> $(readlink -f "$LINK" 2>/dev/null || echo "$LINK")"
        [ -f "$MARKER" ] && echo "source:    $(cat "$MARKER")"
    else
        echo "not installed (no $LINK)"
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    rm -f "$LINK"
    rm -rf "$LIB_DIR"
    # state/ holds tuned settings and measured KV costs; only remove it when
    # empty so a reinstall does not silently drop a user's measurements.
    rmdir "$STATE_DIR" 2>/dev/null || true
    echo "Removed $LINK and $LIB_DIR"
    echo "Models in ~/models/bonsai-server were left in place."
    exit 0
fi

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
[ -d "$SELF_DIR/scripts" ] || { echo "Run this from the repo root (scripts/ not found)." >&2; exit 1; }

mkdir -p "$BIN_DIR" "$LIB_DIR" "$STATE_DIR"

# Copy, don't symlink, the script tree: the repo may move or be deleted, and
# a broken symlink in bin/ is worse than a stale copy. `bonsai` itself is a
# thin entry that sources the copied lib, so the copy is what runs.
cp -R "$SELF_DIR/scripts/." "$LIB_DIR/"
chmod +x "$LIB_DIR"/*.sh

# Point the copied install at its own state dir, not the repo's. REPO_ROOT is
# derived from the script location, so a copied tree is already relocatable;
# only STATE_DIR and MODELS_DIR need pinning so a user's tuned settings and
# downloaded models survive a repo update.
cat > "$LINK" <<EOF
#!/usr/bin/env bash
# Installed by ikaros-bonsai install.sh. Regenerate with --uninstall then install.
export BONSAI_STATE_DIR="\${BONSAI_STATE_DIR:-$STATE_DIR}"
export BONSAI_MODELS_DIR="\${BONSAI_MODELS_DIR:-\$HOME/models/bonsai-server}"
exec "$LIB_DIR/bonsai" "\$@"
EOF
chmod +x "$LINK"

printf '%s\n' "$SELF_DIR" > "$MARKER"

echo "Installed bonsai to $PREFIX"
echo "  command : $LINK"
echo "  scripts : $LIB_DIR"
echo "  state   : $STATE_DIR"
echo ""

# PATH guidance: only warn when the prefix's bin is genuinely absent from it.
case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo "bonsai is on your PATH. Try: bonsai status"
        ;;
    *)
        echo "NOTE: $BIN_DIR is not on your PATH. Add it with:"
        echo ""
        echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
        echo ""
        echo "Or run it directly for now: $LINK status"
        ;;
esac
echo ""
echo "First run: bonsai detect   (then: bonsai start)"
