#!/usr/bin/env bash
# install-hermes-skill.sh - lay down the Kiln SKILL.md for the Hermes agent.
#
# Both setup.sh (repo-checkout path) and install.sh (install-to-prefix path)
# call this, so every install route teaches the local Hermes agent how to
# drive kiln. One implementation, no drift between the two entry points.
#
# Behaviour:
#   - Installs to the standard user-skill dir ~/.hermes/skills/kiln/.
#   - Only acts when ~/.hermes already exists: we teach an existing Hermes
#     install, we never create Hermes state on a machine that has none.
#   - Writes an .installed-by-kiln marker so --uninstall removes only the skill
#     we own, never a hand-edited or unrelated ~/.hermes/skills/kiln.
#   - A missing/failed skill install is NEVER a failed kiln install: kiln
#     works fine without Hermes. This script always exits 0.
#
# Env:
#   KILN_SKILL_SRC  override the SKILL.md source (default: alongside this file)
#   HERMES_SKILL_DIR override the destination (default: ~/.hermes/skills/kiln)

set -u
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo root is one level up from scripts/.
_REPO_ROOT="$(cd "$_SELF_DIR/.." && pwd)"

SRC="${KILN_SKILL_SRC:-$_REPO_ROOT/skills/kiln/SKILL.md}"
DST_DIR="${HERMES_SKILL_DIR:-$HOME/.hermes/skills/kiln}"
DST="$DST_DIR/SKILL.md"

# Quiet unless verbose: callers print their own framing. Set KILN_SKILL_VERBOSE=1
# to get the one-line confirmation.
_verbose="${KILN_SKILL_VERBOSE:-0}"

if [ ! -d "$HOME/.hermes" ]; then
    [ "$_verbose" = 1 ] && echo "Hermes skill skipped (no ~/.hermes here)."
    exit 0
fi
if [ ! -f "$SRC" ]; then
    [ "$_verbose" = 1 ] && echo "Hermes skill skipped (SKILL.md not found at $SRC)."
    exit 0
fi
if mkdir -p "$DST_DIR" 2>/dev/null && cp "$SRC" "$DST" 2>/dev/null; then
    printf 'installed by kiln\n' > "$DST_DIR/.installed-by-kiln" 2>/dev/null || true
    [ "$_verbose" = 1 ] && echo "Hermes skill installed: $DST"
    exit 0
fi
[ "$_verbose" = 1 ] && echo "Hermes skill skipped (could not write $DST)."
exit 0
