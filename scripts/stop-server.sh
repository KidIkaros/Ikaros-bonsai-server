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

# Prefer the recorded pid; fall back to whatever holds the port.
_pid=""
if [ -f "$STATE_DIR/server.pid" ]; then
    _pid="$(cat "$STATE_DIR/server.pid" 2>/dev/null || true)"
    # Guard against a recycled pid.
    if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then _pid=""; fi
fi
if [ -z "$_pid" ] && command -v lsof >/dev/null 2>&1; then
    _pid="$(lsof -ti "tcp:$BONSAI_PORT" 2>/dev/null || true)"
fi

if [ -z "$_pid" ]; then
    info "Nothing listening on port $BONSAI_PORT."
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
