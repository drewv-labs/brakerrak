#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Master 2-Row Stacked VT100 Progress Dock
# Path: brakerrak/scripts/lib-progbar.sh
#
# Layout when active on an interactive TTY:
#   Rows [1 .. ROWS-2] : Scrolling command & APT/compiler output (DECSTBM)
#   Row  [ROWS-1]      : Current RVDK sub-process progress bar (cyan badge)
#   Row  [ROWS]        : BrakerRak master pipeline progress bar (magenta badge)
#
# Suppressed via `--noprogbar` (`BRAKERRAK_NO_PROGBAR=1`), non-TTY stdout,
# `TERM=dumb`, or small terminals (<10x40), cascading `RVDK_NO_PROGBAR=1` to
# child RVDK invocations.
# ==============================================================================

if [[ "${_BRAKERRAK_PROGBAR_SOURCED:-0}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_BRAKERRAK_PROGBAR_SOURCED="1"

_BRAK_PROG_ACTIVE="0"
_BRAK_PROG_ROWS=0
_BRAK_PROG_COLS=0
_BRAK_MASTER_PCT=0
_BRAK_MASTER_MSG=""
_BRAK_SUB_PCT=0
_BRAK_SUB_MSG="Ready"
_BRAK_PROG_TTY=""

_BRAK_FILL_TEMPLATE="########################################"
_BRAK_DOTS_TEMPLATE="........................................"

_brak_prog_out() {
    if [[ -n "$_BRAK_PROG_TTY" ]]; then
        printf "%b" "$1" > "$_BRAK_PROG_TTY" 2>/dev/null || true
    else
        printf "%b" "$1" 2>/dev/null || true
    fi
    return 0
}

_brak_prog_query_geom() {
    local sz="" r="" c=""
    if [[ -n "$_BRAK_PROG_TTY" ]]; then
        sz="$(stty size < "$_BRAK_PROG_TTY" 2>/dev/null || true)"
    fi
    if [[ -z "$sz" ]]; then
        sz="$(stty size <&1 2>/dev/null || stty size <&2 2>/dev/null || true)"
    fi
    if [[ -n "$sz" ]]; then
        r="${sz%% *}"
        c="${sz##* }"
    fi
    if [[ ! "$r" =~ ^[0-9]+$ ]] || (( r <= 0 )); then
        r="$(tput lines 2>/dev/null || echo "${LINES:-24}")"
    fi
    if [[ ! "$c" =~ ^[0-9]+$ ]] || (( c <= 0 )); then
        c="$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")"
    fi
    [[ "$r" =~ ^[0-9]+$ ]] || r=24
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    _BRAK_PROG_ROWS="$r"
    _BRAK_PROG_COLS="$c"
    return 0
}

# Format a single progress bar row (strictly <= COLS - 1 visible chars)
# Matches riscv-data-kit/lib/progbar.sh badge/gauge alignment to the column.
_brak_prog_format_line() {
    local label="$1"
    local badge_ansi="$2"
    local bar_ansi="$3"
    local pct="$4"
    local msg="$5"
    local cols="$6"

    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    local max_vis=$(( cols - 1 ))
    if (( max_vis < 24 )); then
        printf ""
        return 0
    fi

    local badge_txt
    badge_txt="$(printf " %-9s [%3d%%] " "$label" "$pct")"

    local bar_w=$(( cols / 4 ))
    (( bar_w < 10 )) && bar_w=10
    (( bar_w > 36 )) && bar_w=36

    if (( 18 + bar_w + 3 > max_vis )); then
        bar_w=$(( max_vis - 21 ))
        (( bar_w < 4 )) && bar_w=4
    fi

    local filled=$(( pct * bar_w / 100 ))
    local empty=$(( bar_w - filled ))
    local hashes="${_BRAK_FILL_TEMPLATE:0:$filled}"
    local dots="${_BRAK_DOTS_TEMPLATE:0:$empty}"

    msg="${msg//$'\r'/}"
    msg="${msg//$'\n'/ }"
    local msg_budget=$(( max_vis - 18 - bar_w - 3 - 1 ))
    local msg_part=""
    if (( msg_budget >= 4 )) && [[ -n "$msg" ]]; then
        if (( ${#msg} > msg_budget )); then
            msg_part=" ${msg:0:$(( msg_budget - 3 ))}..."
        else
            msg_part=" ${msg}"
        fi
    fi

    printf "%b%s\033[0m[%b%s\033[0m\033[2m%s\033[0m]%s" \
        "$badge_ansi" "$badge_txt" "$bar_ansi" "$hashes" "$dots" "$msg_part"
    return 0
}

_brak_prog_sync_sub_from_disk() {
    if [[ -n "${BRAKERRAK_SUB_STATE:-}" && -r "${BRAKERRAK_SUB_STATE}" ]]; then
        local s_raw="" s_pct="" s_msg=""
        IFS= read -r s_raw < "${BRAKERRAK_SUB_STATE}" 2>/dev/null || true
        if [[ -n "$s_raw" ]]; then
            s_pct="${s_raw%%|*}"
            s_msg="${s_raw#*|}"
            if [[ "$s_pct" =~ ^[0-9]+$ ]]; then
                _BRAK_SUB_PCT="$s_pct"
                _BRAK_SUB_MSG="$s_msg"
            fi
        fi
    fi
    return 0
}

_brak_prog_render() {
    [[ "$_BRAK_PROG_ACTIVE" != "1" ]] && return 0

    local prev_rows="$_BRAK_PROG_ROWS"
    _brak_prog_query_geom
    local rows="$_BRAK_PROG_ROWS"
    local cols="$_BRAK_PROG_COLS"
    (( rows < 10 || cols < 40 )) && return 0

    _brak_prog_sync_sub_from_disk

    local scroll_end=$(( rows - 2 ))
    local sub_row=$(( rows - 1 ))
    local master_row="$rows"

    local sub_line master_line
    sub_line="$(_brak_prog_format_line "RVDK" "\033[46;30;1m" "\033[1;36m" "$_BRAK_SUB_PCT" "$_BRAK_SUB_MSG" "$cols")"
    master_line="$(_brak_prog_format_line "BrakerRak" "\033[45;37;1m" "\033[1;35m" "$_BRAK_MASTER_PCT" "$_BRAK_MASTER_MSG" "$cols")"

    local seq="\0337\033[1;${scroll_end}r"
    if (( prev_rows > 0 && prev_rows != rows )); then
        local old_sub=$(( prev_rows - 1 ))
        if (( old_sub >= 1 && old_sub <= rows )); then
            seq+="\033[${old_sub};1f\033[0K"
        fi
        if (( prev_rows >= 1 && prev_rows <= rows )); then
            seq+="\033[${prev_rows};1f\033[0K"
        fi
    fi
    seq+="\033[${sub_row};1f${sub_line}\033[0K\033[${master_row};1f${master_line}\033[0K\0338"
    _brak_prog_out "$seq"
    return 0
}

brak_prog_init() {
    local init_msg="${1:-Initializing BrakerRak forge...}"

    if [[ "${BRAKERRAK_NO_PROGBAR:-0}" == "1" || "${NO_PROGBAR:-0}" == "1" ]]; then
        export RVDK_NO_PROGBAR="1"
        return 0
    fi
    if [[ ! -t 1 || "${TERM:-dumb}" == "dumb" ]]; then
        return 0
    fi
    if (: > /dev/tty) 2>/dev/null; then
        _BRAK_PROG_TTY="/dev/tty"
    else
        _BRAK_PROG_TTY=""
    fi

    _brak_prog_query_geom
    if (( _BRAK_PROG_ROWS < 10 || _BRAK_PROG_COLS < 40 )); then
        return 0
    fi

    _BRAK_PROG_ACTIVE="1"
    _BRAK_MASTER_PCT=2
    _BRAK_MASTER_MSG="$init_msg"
    _BRAK_SUB_PCT=0
    _BRAK_SUB_MSG="Standing by..."

    export BRAKERRAK_PROGBAR_ACTIVE="1"
    export BRAKERRAK_MASTER_STATE="/tmp/.brakerrak-progbar.$$.master"
    export BRAKERRAK_SUB_STATE="/tmp/.brakerrak-progbar.$$.sub"

    (
        umask 077
        printf "%s|%s\n" "$_BRAK_MASTER_PCT" "$_BRAK_MASTER_MSG" > "$BRAKERRAK_MASTER_STATE"
        printf "%s|%s\n" "$_BRAK_SUB_PCT" "$_BRAK_SUB_MSG" > "$BRAKERRAK_SUB_STATE"
    ) 2>/dev/null || true

    local scroll_end=$(( _BRAK_PROG_ROWS - 2 ))
    _brak_prog_out "\n\n\0337\033[1;${scroll_end}r\0338\033[2A"

    trap 'brak_prog_cleanup' EXIT
    trap 'brak_prog_cleanup; trap - INT; kill -INT $$' INT
    trap 'brak_prog_cleanup; trap - TERM; kill -TERM $$' TERM
    trap '_brak_prog_render' WINCH

    _brak_prog_render
    return 0
}

# Usage: brak_prog <master_pct> <master_msg> [<sub_pct> <sub_msg>]
brak_prog() {
    [[ "$_BRAK_PROG_ACTIVE" != "1" ]] && return 0

    local pct="${1:-0}"
    local msg="${2:-}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    _BRAK_MASTER_PCT="$pct"
    [[ -n "$msg" ]] && _BRAK_MASTER_MSG="$msg"

    if [[ -n "${BRAKERRAK_MASTER_STATE:-}" ]]; then
        printf "%s|%s\n" "$_BRAK_MASTER_PCT" "$_BRAK_MASTER_MSG" > "$BRAKERRAK_MASTER_STATE" 2>/dev/null || true
    fi

    if [[ $# -ge 3 ]]; then
        local spct="${3:-0}"
        local smsg="${4:-}"
        [[ "$spct" =~ ^[0-9]+$ ]] || spct=0
        (( spct < 0 )) && spct=0
        (( spct > 100 )) && spct=100
        _BRAK_SUB_PCT="$spct"
        _BRAK_SUB_MSG="$smsg"
        if [[ -n "${BRAKERRAK_SUB_STATE:-}" ]]; then
            printf "%s|%s\n" "$_BRAK_SUB_PCT" "$_BRAK_SUB_MSG" > "$BRAKERRAK_SUB_STATE" 2>/dev/null || true
        fi
    fi

    _brak_prog_render
    return 0
}

brak_prog_cleanup() {
    local rc=$?
    if [[ "$_BRAK_PROG_ACTIVE" == "1" ]]; then
        _brak_prog_query_geom
        local rows="$_BRAK_PROG_ROWS"
        if (( rows >= 3 )); then
            local sub_row=$(( rows - 1 ))
            _brak_prog_out "\0337\033[1;${rows}r\033[${sub_row};1f\033[0K\033[${rows};1f\033[0K\0338"
        fi
        _BRAK_PROG_ACTIVE="0"
    fi
    if [[ -n "${BRAKERRAK_MASTER_STATE:-}" ]]; then
        rm -f "${BRAKERRAK_MASTER_STATE}" 2>/dev/null || true
    fi
    if [[ -n "${BRAKERRAK_SUB_STATE:-}" ]]; then
        rm -f "${BRAKERRAK_SUB_STATE}" 2>/dev/null || true
    fi
    unset BRAKERRAK_PROGBAR_ACTIVE BRAKERRAK_MASTER_STATE BRAKERRAK_SUB_STATE 2>/dev/null || true
    return "$rc"
}
