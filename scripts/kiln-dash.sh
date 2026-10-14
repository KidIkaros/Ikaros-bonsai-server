#!/usr/bin/env bash
# kiln dash - a full-screen status dashboard for the Kiln local model server.
#
# Pure bash + ANSI, no toolchain and no extra dependency, so it honours the
# repo's dependency-free promise (git clone && ./setup.sh, tests on plain
# bash). It reads the same state the other commands read and drives the same
# commands, so it is a view over kiln, not a parallel implementation.
#
# Layout: a branded header, a live status block, the measured-speed ranking,
# and a key legend. Keys: q quit, s start, x stop, r restart, b bench,
# f fastest (re-rank), l logs. Colors follow the Kiln palette and fall back
# to plain text when stdout is not a TTY or NO_COLOR is set - in that case
# dash prints one static snapshot and exits, so it is safe in pipes and CI.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Rendering primitives (raw ANSI; colors already gated to TTY by common.sh)
# ---------------------------------------------------------------------------

# term_w / term_h - terminal size, with a sane fallback when not a TTY.
term_w() { tput cols  2>/dev/null || echo 80; }
term_h() { tput lines 2>/dev/null || echo 24; }

# cursor_hide / cursor_show - park the cursor while redrawing.
cursor_hide() { printf '\033[?25l'; }
cursor_show() { printf '\033[?25h'; }
# clear_screen / home - full repaint each frame.
clear_screen() { printf '\033[2J'; }
home() { printf '\033[H'; }
# clear_to_eol - erase the rest of the line before drawing.
clear_to_eol() { printf '\033[K'; }

# hr WIDTH [CHAR] - a horizontal rule of WIDTH, default a thin line.
hr() { local w="$1" c="${2:-─}" i out=""; for ((i=0;i<w;i++)); do out+="$c"; done; printf '%s' "$out"; }

# center TEXT WIDTH - centre TEXT within WIDTH using spaces.
center() {
    local text="$1" width="$2" pad
    pad=$(( (width - ${#text}) / 2 ))
    (( pad < 0 )) && pad=0
    printf '%*s%s' "$pad" "" "$text"
}

# box_top / box_mid / box_bot WIDTH LABEL - a rounded box frame in Ash.
box_top() { printf "${C_ASH}╭─ %s %s╮${C_RESET}" "$1" "$(hr $(( $2 - ${#1} - 5 )) )"; }
box_bot() { printf "${C_ASH}╰%s╯${C_RESET}" "$(hr "$1")"; }

# kv LABEL VALUE - one aligned "label : value" row; the value is Ash unless
# it carries meaning (status), in which case the caller pre-colors it.
kv() { printf "  ${C_ASH}%-11s${C_RESET} %s\n" "$1:" "$2"; }

# ---------------------------------------------------------------------------
# Data gathering (reuse the existing commands; never reimplement)
# ---------------------------------------------------------------------------

# server_up - 0 if something answers on the port.
server_up() {
    local port="${KILN_PORT:-8081}"
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}

# tps_now - current tokens/sec from the running server, or "-".
tps_now() {
    local out
    out="$("$SCRIPT_DIR/kiln" speed 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    printf '%s' "${out:--}"
}

# ranked - the measured speed rows, fastest first (model, tok/s), max 6.
ranked() {
    "$SCRIPT_DIR/kiln" fastest 2>/dev/null | grep -E 'tok/s' | head -6
}

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

draw_header() {
    local w; w="$(term_w)"
    printf "${C_ASH}%s${C_RESET}\n" "$(hr "$w" '─')"
    printf "${C_EMBER}%s${C_RESET}\n" "$(center "Kiln" "$w")"
    printf "${C_ASH}%s${C_RESET}\n" "$(center "local model server · fired hot" "$w")"
    printf "${C_ASH}%s${C_RESET}\n" "$(hr "$w" '─')"
}

draw_status() {
    local w; w="$(term_w)"
    local state badge
    if server_up; then state="running"; badge="${C_OK}● running${C_RESET}"
    else state="stopped"; badge="${C_ASH}○ stopped${C_RESET}"; fi
    printf "\n"
    printf "%s\n" "$(box_top "server" "$w")"
    kv "port" "${C_CLAY}${KILN_PORT:-8081}${C_RESET}"
    kv "state" "$badge"
    if [ "$state" = running ]; then
        kv "speed" "${C_EMBER}$(tps_now) tok/s${C_RESET}"
    fi
    kv "gpu" "${C_ASH}$(printf '%s' "${GPU_NAME:-unknown}" | cut -c1-40)${C_RESET}"
    printf "%s\n" "$(box_bot "$w")"
}

draw_ranked() {
    local w; w="$(term_w)"
    local rows; rows="$(ranked)"
    printf "\n"
    printf "%s\n" "$(box_top "fastest measured" "$w")"
    if [ -n "$rows" ]; then
        printf '%s\n' "$rows" | while IFS= read -r line; do
            # highlight the tok/s number in ember, rest in ash
            printf "  ${C_ASH}%s${C_RESET}\n" "$line" | sed "s/\([0-9][0-9.]*\) tok\/s/${C_EMBER}\1 tok\/s${C_RESET}/g"
        done
    else
        printf "  ${C_ASH}no measurements yet — run: kiln tune${C_RESET}\n"
    fi
    printf "%s\n" "$(box_bot "$w")"
}

draw_keys() {
    local w; w="$(term_w)"
    printf "\n"
    printf "  ${C_ASH}[s]${C_RESET} start  ${C_ASH}[x]${C_RESET} stop  ${C_ASH}[r]${C_RESET} restart  ${C_ASH}[b]${C_RESET} bench  ${C_ASH}[l]${C_RESET} logs  ${C_ASH}[q]${C_RESET} quit\n"
    printf "${C_ASH}%s${C_RESET}\n" "$(hr "$w" '─')"
}

draw() { clear_screen; home; draw_header; draw_status; draw_ranked; draw_keys; }

# ---------------------------------------------------------------------------
# Main: interactive loop on a TTY, one snapshot otherwise
# ---------------------------------------------------------------------------

if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
    # Not interactive: print a single static snapshot and exit, with no
    # screen-control escapes (no clear/home) so it is clean in pipes and CI.
    # Only the color vars are empty; the box frame still draws as plain text.
    draw_header; draw_status; draw_ranked; draw_keys
    exit 0
fi

# Interactive: raw mode, read one key per frame, redraw.
stty_saved="$(stty -g 2>/dev/null || true)"
restore() { [ -n "$stty_saved" ] && stty "$stty_saved" 2>/dev/null; cursor_show; clear_screen; home; }
trap restore EXIT INT TERM

cursor_hide
stty -echo -icanon time 0 min 1 2>/dev/null || true

draw
while :; do
    key=""
    IFS= read -rsn1 key 2>/dev/null || key=""
    case "$key" in
        q|Q) break ;;
        s|S) "$SCRIPT_DIR/kiln" start >/dev/null 2>&1 & ;;
        x|X) "$SCRIPT_DIR/kiln" stop  >/dev/null 2>&1 & ;;
        r|R) "$SCRIPT_DIR/kiln" restart >/dev/null 2>&1 & ;;
        l|L) clear_screen; home; "$SCRIPT_DIR/kiln" logs -n 40 2>&1 | head -"$(( $(term_h) - 3 ))"; printf "\n${C_ASH}press any key…${C_RESET}"; IFS= read -rsn1 _ 2>/dev/null ;;
        b|B) : ;;  # bench runs in the foreground terminal, not the dashboard
        *)   : ;;  # any other key: just redraw (refresh)
    esac
    draw
done
restore
