#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared ORT & CTD Provenance Snapshot Dispatcher
# Path: brakerrak/scripts/ort-snapshot.sh
#
# Usage:
#   ./scripts/ort-snapshot.sh [--target <soc>] [--stage day0-pre-forge|day1-post-forge] [--out-dir ~/.brakerrak/snapshots]
#   sudo brakerrak ort [--stage day0-pre-forge|day1-post-forge] [--no-public] [--no-fail-exit]
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAKERRAK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-common.sh"
brak_log_init "BRAKERRAK:ORT"

usage() {
    cat <<'EOF'
Usage: brakerrak ort [options]

Options:
  --target, --soc <slug>   Override silicon target (e.g. eswin-eic7700x, starfive-jh7110, generic-riscv64)
  --stage <tag>            ORT stage tag (default: day0-pre-forge | day1-post-forge)
  --out-dir <dir>          Snapshot output directory (default: ~/.brakerrak/snapshots)
  --config <path>          Explicit node.env config path (default: /etc/brakerrak/node.env)
  --window <seconds>       Quiescent baseline profiling window (default: 5.0)
  --no-public              Skip generating redacted .public.json artifact
  --no-fail-exit           Exit 0 even if overall_status == "FAIL"
  -h, --help               Show this help message and exit
EOF
}

TARGET_BOARD="${BRAKERRAK_TARGET:-}"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--soc)
            brak_require_arg "$1" "${2:-}"
            TARGET_BOARD="$2"
            shift 2
            ;;
        --target=*|--soc=*)
            TARGET_BOARD="${1#*=}"
            brak_require_arg "${1%%=*}" "$TARGET_BOARD"
            shift
            ;;
        --stage|--out-dir|--config|--window)
            brak_require_arg "$1" "${2:-}"
            FORWARD_ARGS+=("$1" "$2")
            shift 2
            ;;
        --stage=*|--out-dir=*|--config=*|--window=*)
            _flag="${1%%=*}"
            _val="${1#*=}"
            brak_require_arg "$_flag" "$_val"
            FORWARD_ARGS+=("$_flag" "$_val")
            shift
            ;;
        --no-public|--no-fail-exit)
            FORWARD_ARGS+=("$1")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_fatal "Unknown argument: $1 (try 'brakerrak ort --help')"
            ;;
    esac
done

# Auto-detect silicon target via unified vendor-qualified resolver
if ! brak_resolve_silicon "$TARGET_BOARD"; then
    log_fatal "Could not auto-detect silicon target from Device Tree: '${DT_MODEL}'. Pass --target <board>."
fi

# Prefer unified stdlib-only `brakerrak_ort` package:
#   1. `uv run --no-sync` when uv + pyproject.toml + usable .venv are present
#   2. Stock stdlib `python3 -m brakerrak_ort` fallback for bare Day-0 Stage 0 runs before `uv`
if [[ -d "${BRAKERRAK_ROOT}/brakerrak_ort" ]]; then
    if command -v uv >/dev/null 2>&1 \
       && [[ -f "${BRAKERRAK_ROOT}/pyproject.toml" && -x "${BRAKERRAK_ROOT}/.venv/bin/python" ]]; then
        log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) -> uv run python -m brakerrak_ort"
        exec uv run --project "${BRAKERRAK_ROOT}" --no-sync python -m brakerrak_ort \
            --soc "$TARGET_BOARD" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_fatal "python3 not found; cannot execute brakerrak_ort collector."
    fi
    log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) -> python3 -m brakerrak_ort"
    export PYTHONPATH="${BRAKERRAK_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"
    exec python3 -m brakerrak_ort --soc "$TARGET_BOARD" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
fi

# Legacy shim fallback if brakerrak_ort package directory is absent
ORT_SCRIPT="${BRAKERRAK_ROOT}/soc-drawer/${TARGET_BOARD}/ort-snapshot.py"
ORT_SOC_ARGS=()
if [[ ! -f "$ORT_SCRIPT" ]]; then
    ORT_SCRIPT="${BRAKERRAK_ROOT}/soc-drawer/generic-riscv64/ort-snapshot.py"
    ORT_SOC_ARGS=("--soc" "$TARGET_BOARD")
fi
[[ ! -f "$ORT_SCRIPT" ]] && log_fatal "ORT collector not found: ${ORT_SCRIPT}"

log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) -> ${ORT_SCRIPT}"
exec python3 "$ORT_SCRIPT" ${ORT_SOC_ARGS[@]+"${ORT_SOC_ARGS[@]}"} ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
