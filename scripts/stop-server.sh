#!/usr/bin/env bash
# stop-server.sh - stop the llama-server started by start-server.sh.
#
# Usage:
#   ./scripts/stop-server.sh            stop whatever is on BONSAI_PORT
#   ./scripts/stop-server.sh --status   report whether it is running

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STATUS_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --status) STATUS_ONLY=1 ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

# Only ever stop a process we can prove is ours. Ports are shared real estate:
# another service may legitimately own $BONSAI_PORT, and killing it because it
# happens to be on the same port would be a serious bug.
_is_ours() {
    _cmd="$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true)"
    [ -n "$_cmd" ] || return 1
    case "$_cmd" in
        *"$BIN_DIR"*)   return 0 ;;
        *"$REPO_ROOT"*) return 0 ;;
    esac
    return 1
}

_find_our_pid() {
    # 1. the pid we recorded, if it is still running our binary
    if [ -f "$STATE_DIR/server.pid" ]; then
        _p="$(cat "$STATE_DIR/server.pid" 2>/dev/null || true)"
        if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && _is_ours "$_p"; then
            printf '%s' "$_p"; return 0
        fi
    fi
    # 2. anything on our port that is running our binary
    if command -v lsof >/dev/null 2>&1; then
        for _p in $(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null || true); do
            if _is_ours "$_p"; then printf '%s' "$_p"; return 0; fi
        done
    fi
    return 1
}

_pid="$(_find_our_pid || true)"

if [ -z "$_pid" ]; then
    # Say clearly what is on the port, so a port clash is never silent.
    _other=""
    if command -v lsof >/dev/null 2>&1; then
        _other="$(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$_other" ]; then
        warn "Something is listening on port $BONSAI_PORT, but it is not from this repo."
        dim "  pid $_other: $(tr '\0' ' ' < "/proc/$_other/cmdline" 2>/dev/null | cut -c1-100)"
        echo "" >&2
        dim "  Leaving it alone. If it is your own service, stop it with systemd, e.g.:"
        dim "    systemctl --user stop <service>"
        dim "  Or run this repo on a different port:"
        dim "    BONSAI_PORT=9000 ./scripts/start-server.sh"
        exit 1
    fi
    info "Nothing from this repo is listening on port $BONSAI_PORT."
    exit 0
fi

if [ "$STATUS_ONLY" = 1 ]; then
    info "Running on port $BONSAI_PORT (pid $_pid)."
    exit 0
fi

step "Stopping server (pid $_pid)"
kill "$_pid" 2>/dev/null || true

for _ in $(seq 1 20); do
    kill -0 "$_pid" 2>/dev/null || break
    sleep 0.5
done

if kill -0 "$_pid" 2>/dev/null; then
    warn "Did not exit after 10s; sending SIGKILL."
    kill -9 "$_pid" 2>/dev/null || true
fi

rm -f "$STATE_DIR/server.pid"
info "Stopped."
