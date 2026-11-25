#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Master 2-Row Stacked VT100 Progress Dock
# Path: brakerrak/scripts/lib-progbar.sh
#
# Layout when active on an interactive TTY:
#   Rows [1 .. ROWS-2] : Scrolling command & APT/compiler output (DECSTBM)
#   Row  [ROWS-1]      : Current RVDK sub-process progress bar (#1c49f2 blue)
#   Row  [ROWS]        : BrakerRak master pipeline progress bar (#5a26e5 purple)
#
# Passes generic RVDK_PARENT_* dock hooks to child RVDK invocations so RVDK
# stays platform-agnostic while docking cleanly above BrakerRak's master bar.
# Suppressed via `--noprogbar` (`BRAKERRAK_NO_PROGBAR=1`), non-TTY stdout,
# `TERM=dumb`, or small terminals (<10x40), cascading `RVDK_NO_PROGBAR=1`.
# ==============================================================================

if [[ "${_BRAKERRAK_PROGBAR_SOURCED:-0}" == "1" ]]; then
    return 0
fi
_BRAKERRAK_PROGBAR_SOURCED="1"

if [[ "${_BRAKERRAK_COMMON_SOURCED:-0}" != "1" ]]; then
    _BRAK_PROG_SCRIPT_DIR=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        _BRAK_PROG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ -n "$_BRAK_PROG_SCRIPT_DIR" && -f "${_BRAK_PROG_SCRIPT_DIR}/lib-common.sh" ]]; then
        # shellcheck disable=SC1091
        source "${_BRAK_PROG_SCRIPT_DIR}/lib-common.sh"
    fi
    unset _BRAK_PROG_SCRIPT_DIR
fi

# Literal ESC byte (0x1B). Never pass `\0337` through `printf "%b"`, because
# bash parses `\0` + 3 octal digits (`\0337` -> 0xDF) instead of ESC + '7'!
_BRAK_ESC=$'\033'

# Brand palette:
#   RVDK Blue       : #1c49f2 -> RGB(28, 73, 242)
#   BrakerRak Purple: #5a26e5 -> RGB(90, 38, 229)
if [[ "${TERM:-}" == "linux" ]]; then
    _BRAK_RVDK_BADGE_SGR="${_BRAK_ESC}[44;97;1m"
    _BRAK_RVDK_BAR_SGR="${_BRAK_ESC}[1;34m"
    _BRAK_MASTER_BADGE_SGR="${_BRAK_ESC}[45;97;1m"
    _BRAK_MASTER_BAR_SGR="${_BRAK_ESC}[1;35m"
else
    _BRAK_RVDK_BADGE_SGR="${_BRAK_ESC}[48;2;28;73;242;38;2;255;255;255;1m"
    _BRAK_RVDK_BAR_SGR="${_BRAK_ESC}[38;2;28;73;242;1m"
    _BRAK_MASTER_BADGE_SGR="${_BRAK_ESC}[48;2;90;38;229;38;2;255;255;255;1m"
    _BRAK_MASTER_BAR_SGR="${_BRAK_ESC}[38;2;90;38;229;1m"
fi

_BRAK_PROG_ACTIVE="0"
_BRAK_PROG_ROWS=0
_BRAK_PROG_COLS=0
_BRAK_MASTER_PCT=0
_BRAK_MASTER_MSG=""
_BRAK_SUB_PCT=0
_BRAK_SUB_MSG="Ready"

_BRAK_FILL_TEMPLATE="########################################"
_BRAK_DOTS_TEMPLATE="........................................"

_brak_prog_out() {
    if [[ -t 1 ]]; then
        printf '%s' "$1" 2>/dev/null || true
    fi
    return 0
}

_brak_prog_query_geom() {
    local sz="" r="" c=""
    sz="$(stty size <&1 2>/dev/null || stty size < /dev/tty 2>/dev/null || stty size <&2 2>/dev/null || true)"
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
    local esc="$_BRAK_ESC"

    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    local max_vis=$(( cols - 1 ))
    if (( max_vis < 24 )); then
        printf ''
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
    msg="${msg//"$esc"/}"
    local msg_budget=$(( max_vis - 18 - bar_w - 3 - 1 ))
    local msg_part=""
    if (( msg_budget >= 4 )) && [[ -n "$msg" ]]; then
        if (( ${#msg} > msg_budget )); then
            msg_part=" ${msg:0:$(( msg_budget - 3 ))}..."
        else
            msg_part=" ${msg}"
        fi
    fi

    printf '%s%s%s[0m[%s%s%s[0m%s[2m%s%s[0m]%s' \
        "$badge_ansi" "$badge_txt" "$esc" \
        "$bar_ansi" "$hashes" "$esc" \
        "$esc" "$dots" "$esc" \
        "$msg_part"
    return 0
}

_brak_prog_sync_sub_from_disk() {
    if [[ -n "${RVDK_SUB_STATE:-}" && -r "${RVDK_SUB_STATE}" ]]; then
        local s_raw="" s_pct="" s_msg=""
        IFS= read -r s_raw < "${RVDK_SUB_STATE}" 2>/dev/null || true
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

    local esc="$_BRAK_ESC"
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
    sub_line="$(_brak_prog_format_line "RVDK" "$_BRAK_RVDK_BADGE_SGR" "$_BRAK_RVDK_BAR_SGR" "$_BRAK_SUB_PCT" "$_BRAK_SUB_MSG" "$cols")"
    master_line="$(_brak_prog_format_line "BrakerRak" "$_BRAK_MASTER_BADGE_SGR" "$_BRAK_MASTER_BAR_SGR" "$_BRAK_MASTER_PCT" "$_BRAK_MASTER_MSG" "$cols")"

    local seq="${esc}7${esc}[1;${scroll_end}r"
    if (( prev_rows > 0 && prev_rows != rows )); then
        local old_sub=$(( prev_rows - 1 ))
        if (( old_sub >= 1 && old_sub <= rows )); then
            seq+="${esc}[${old_sub};1H${esc}[0K"
        fi
        if (( prev_rows >= 1 && prev_rows <= rows )); then
            seq+="${esc}[${prev_rows};1H${esc}[0K"
        fi
    fi
    seq+="${esc}[${sub_row};1H${sub_line}${esc}[0K${esc}[${master_row};1H${master_line}${esc}[0K${esc}8"
    if (( prev_rows > 0 && prev_rows > rows )); then
        seq+="${esc}[${scroll_end};1H"
    fi
    _brak_prog_out "$seq"
    return 0
}

brak_prog_init() {
    local init_msg="${1:-Initializing BrakerRak forge...}"
    local esc="$_BRAK_ESC"

    if declare -F brak_register_exit_hook >/dev/null 2>&1 && declare -F _brak_cleanup_tmpfiles >/dev/null 2>&1; then
        _BRAK_LEGACY_TMPFILES_PID="${BASHPID:-$$}"
        brak_register_exit_hook _brak_cleanup_tmpfiles
    fi

    if [[ "${BRAKERRAK_NO_PROGBAR:-0}" == "1" || "${NO_PROGBAR:-0}" == "1" ]]; then
        export RVDK_NO_PROGBAR="1"
        return 0
    fi
    if [[ ! -t 1 || "${TERM:-dumb}" == "dumb" ]]; then
        return 0
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

    local prog_rt_dir=""
    if declare -F brak_runtime_dir >/dev/null 2>&1; then
        prog_rt_dir="$(brak_runtime_dir)"
    elif [[ "$(uname -s)" == "Linux" && "${EUID:-$(id -u)}" -eq 0 && -d /run ]]; then
        prog_rt_dir="/run/brakerrak"
        install -d -m 0700 -o 0 -g 0 "$prog_rt_dir"
    else
        prog_rt_dir="$(mktemp -d "${TMPDIR:-/tmp}/brakerrak.XXXXXX")"
        chmod 0700 "$prog_rt_dir"
    fi
    _BRAK_PROG_RT_DIR="$prog_rt_dir"

    export RVDK_PARENT_PROGBAR="1"
    export RVDK_PARENT_LABEL="BrakerRak"
    export RVDK_PARENT_BADGE_SGR="$_BRAK_MASTER_BADGE_SGR"
    export RVDK_PARENT_BAR_SGR="$_BRAK_MASTER_BAR_SGR"
    export RVDK_PARENT_STATE="${prog_rt_dir}/progbar.$$.master"
    export RVDK_SUB_STATE="${prog_rt_dir}/progbar.$$.sub"

    (
        umask 077
        printf '%s|%s\n' "$_BRAK_MASTER_PCT" "$_BRAK_MASTER_MSG" > "$RVDK_PARENT_STATE"
        printf '%s|%s\n' "$_BRAK_SUB_PCT" "$_BRAK_SUB_MSG" > "$RVDK_SUB_STATE"
    ) 2>/dev/null || true

    # Advance 2 lines (scrolling existing bottom content up) and step up 2 rows
    # BEFORE DECSC so the saved cursor is guaranteed inside [1 .. scroll_end].
    local scroll_end=$(( _BRAK_PROG_ROWS - 2 ))
    _brak_prog_out $'\n\n'"${esc}[2A${esc}7${esc}[1;${scroll_end}r${esc}8"

    if declare -F brak_register_exit_hook >/dev/null 2>&1; then
        brak_register_exit_hook brak_prog_cleanup
    else
        trap 'brak_prog_cleanup' EXIT
        trap 'brak_prog_cleanup; trap - INT; kill -INT $$' INT
        trap 'brak_prog_cleanup; trap - TERM; kill -TERM $$' TERM
    fi
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

    if [[ -n "${RVDK_PARENT_STATE:-}" ]]; then
        printf '%s|%s\n' "$_BRAK_MASTER_PCT" "$_BRAK_MASTER_MSG" > "$RVDK_PARENT_STATE" 2>/dev/null || true
    fi

    if [[ $# -ge 3 ]]; then
        local spct="${3:-0}"
        local smsg="${4:-}"
        [[ "$spct" =~ ^[0-9]+$ ]] || spct=0
        (( spct < 0 )) && spct=0
        (( spct > 100 )) && spct=100
        _BRAK_SUB_PCT="$spct"
        _BRAK_SUB_MSG="$smsg"
        if [[ -n "${RVDK_SUB_STATE:-}" ]]; then
            printf '%s|%s\n' "$_BRAK_SUB_PCT" "$_BRAK_SUB_MSG" > "$RVDK_SUB_STATE" 2>/dev/null || true
        fi
    fi

    _brak_prog_render
    return 0
}

brak_prog_cleanup() {
    local rc="${1:-$?}"
    local esc="$_BRAK_ESC"
    if [[ "$_BRAK_PROG_ACTIVE" == "1" ]]; then
        _brak_prog_query_geom
        local rows="$_BRAK_PROG_ROWS"
        if (( rows >= 3 )); then
            local sub_row=$(( rows - 1 ))
            _brak_prog_out "${esc}7${esc}[1;${rows}r${esc}[${sub_row};1H${esc}[0K${esc}[${rows};1H${esc}[0K${esc}8"
        fi
        _BRAK_PROG_ACTIVE="0"
    fi
    if [[ -n "${RVDK_PARENT_STATE:-}" ]]; then
        rm -f "${RVDK_PARENT_STATE}" 2>/dev/null || true
    fi
    if [[ -n "${RVDK_SUB_STATE:-}" ]]; then
        rm -f "${RVDK_SUB_STATE}" 2>/dev/null || true
    fi
    if [[ -n "${RVDK_APT_STAMP_FILE:-}" ]]; then
        rm -f "${RVDK_APT_STAMP_FILE}" 2>/dev/null || true
    fi
    if [[ -n "${_BRAK_PROG_RT_DIR:-}" && "$_BRAK_PROG_RT_DIR" != "/run/brakerrak" && "$_BRAK_PROG_RT_DIR" != "${BRAKERRAK_RUNTIME_DIR:-}" ]]; then
        rmdir "${_BRAK_PROG_RT_DIR}" 2>/dev/null || true
    fi
    _BRAK_PROG_RT_DIR=""
    unset RVDK_PARENT_PROGBAR RVDK_PARENT_LABEL RVDK_PARENT_BADGE_SGR RVDK_PARENT_BAR_SGR RVDK_PARENT_STATE RVDK_SUB_STATE 2>/dev/null || true
    return "$rc"
}
