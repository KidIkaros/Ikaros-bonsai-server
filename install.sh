#!/usr/bin/env bash
# install.sh - put the `kiln` command on this machine's PATH.
#
# Like `pip install` for the project: after this, `kiln` works from any
# directory, in any shell, without cloning or exporting anything.
#
# What it does:
#   1. picks an install prefix (~/.local by default, or --prefix)
#   2. copies the scripts there, so no absolute paths are baked in
#   3. symlinks `kiln` into the prefix's bin/ (which it adds to PATH
#      guidance if needed)
#
# The install is self-contained: it does not reference the repo it was run
# from. Updating means re-running this script from a newer checkout.
#
# Usage:
#   ./install.sh                 install to ~/.local
#   ./install.sh --prefix /opt/kiln
#   ./install.sh --uninstall     remove a previous install
#   ./install.sh --status        show what is installed and where
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${KILN_PREFIX:-$HOME/.local}"
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
LIB_DIR="$PREFIX/lib/kiln"
STATE_DIR="$PREFIX/state"
LINK="$BIN_DIR/kiln"
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
    # Remove the Hermes skill we installed, but only the one we own: leave a
    # hand-edited or unrelated ~/.hermes/skills/kiln alone if the marker file
    # we wrote is gone.
    _skill_dst="$HOME/.hermes/skills/kiln/SKILL.md"
    if [ -f "$HOME/.hermes/skills/kiln/.installed-by-kiln" ]; then
        rm -rf "$HOME/.hermes/skills/kiln"
        echo "Removed the Hermes skill (~/.hermes/skills/kiln)"
    fi
    # state/ holds tuned settings and measured KV costs; only remove it when
    # empty so a reinstall does not silently drop a user's measurements.
    rmdir "$STATE_DIR" 2>/dev/null || true
    echo "Removed $LINK and $LIB_DIR"
    echo "Models in ~/models/kiln-server were left in place."
    exit 0
fi

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
[ -d "$SELF_DIR/scripts" ] || { echo "Run this from the repo root (scripts/ not found)." >&2; exit 1; }

mkdir -p "$BIN_DIR" "$LIB_DIR" "$STATE_DIR"

# Copy, don't symlink, the script tree: the repo may move or be deleted, and
# a broken symlink in bin/ is worse than a stale copy. `kiln` itself is a
# thin entry that sources the copied lib, so the copy is what runs.
cp -R "$SELF_DIR/scripts/." "$LIB_DIR/"
chmod +x "$LIB_DIR"/*.sh

# Point the copied install at its own state dir, not the repo's. REPO_ROOT is
# derived from the script location, so a copied tree is already relocatable;
# only STATE_DIR and MODELS_DIR need pinning so a user's tuned settings and
# downloaded models survive a repo update.
cat > "$LINK" <<EOF
#!/usr/bin/env bash
# Installed by kiln install.sh. Regenerate with --uninstall then install.
export KILN_STATE_DIR="\${KILN_STATE_DIR:-$STATE_DIR}"
export KILN_MODELS_DIR="\${KILN_MODELS_DIR:-\$HOME/models/kiln-server}"
exec "$LIB_DIR/kiln" "\$@"
EOF
chmod +x "$LINK"

printf '%s\n' "$SELF_DIR" > "$MARKER"

# Shell completion, installed when the shell's completion directory is
# discoverable. Silently skipped otherwise: a missing completion dir is not a
# failed install, and the command is always available via
# `kiln completions <shell>` for anyone who wants to place it by hand.
_completion_dir=""
case "${SHELL:-}" in
    */zsh)
        _completion_dir="${ZDOTDIR:-$HOME}/.zfunc"
        ;;
    */fish)
        _completion_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions"
        ;;
    *)
        _completion_dir="${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions}"
        ;;
esac

echo "Installed kiln to $PREFIX"
echo "  command : $LINK"
echo "  scripts : $LIB_DIR"
echo "  state   : $STATE_DIR"
echo ""

if [ -n "$_completion_dir" ] && mkdir -p "$_completion_dir" 2>/dev/null; then
    _shell="bash"
    case "${SHELL:-}" in */zsh) _shell="zsh" ;; */fish) _shell="fish" ;; esac
    # bash's completion loader only auto-sources files named exactly after the
    # command (no extension); zsh expects _<cmd> on the fpath; fish expects
    # <cmd>.fish. Writing the wrong name means the file is never loaded.
    case "$_shell" in
        bash) _comp_name="kiln" ;;
        zsh)  _comp_name="_kiln" ;;
        fish) _comp_name="kiln.fish" ;;
    esac
    if "$LINK" completions "$_shell" > "$_completion_dir/$_comp_name" 2>/dev/null &&
       [ -s "$_completion_dir/$_comp_name" ]; then
        echo "Tab completion installed: $_completion_dir/$_comp_name"
        case "$_shell" in
            zsh)  echo "  zsh: ensure ~/.zfunc is on your fpath, then: autoload -U compinit && compinit" ;;
            fish) echo "  Restart fish to pick it up." ;;
            *)    echo "  Start a new shell to pick it up." ;;
        esac
    else
        echo "Tab completion skipped (could not write $_completion_dir)."
        echo "  Install it by hand: kiln completions $_shell"
    fi
else
    echo "Tab completion not installed (no writable completion dir found)."
    echo "  Install it by hand: kiln completions <bash|zsh|fish>"
fi
echo ""

# ---------------------------------------------------------------------------
# Hermes skill
# ---------------------------------------------------------------------------
# Ship a SKILL.md so the Hermes agent on THIS machine learns how to drive
# kiln. Shared with setup.sh via install-hermes-skill.sh, so both install
# routes install the same skill from one implementation (no drift). Only acts
# when ~/.hermes exists; a missing skill is never a failed install.
KILN_SKILL_VERBOSE=1 "$SELF_DIR/scripts/install-hermes-skill.sh"
echo ""

# PATH guidance: only warn when the prefix's bin is genuinely absent from it.
case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo "kiln is on your PATH. Try: kiln status"
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
echo "First run: kiln detect   (then: kiln start)"
