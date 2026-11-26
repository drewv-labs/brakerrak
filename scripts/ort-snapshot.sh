#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared ORT & CTD Provenance Snapshot Dispatcher
# Path: brakerrak/scripts/ort-snapshot.sh
#
# Usage:
#   ./scripts/ort-snapshot.sh [--target <soc>] [--role <persona>] [--stage day0-pre-forge|day1-post-forge] [--out-dir ~/.brakerrak/snapshots]
#   sudo brakerrak ort [--role <persona>] [--stage day0-pre-forge|day1-post-forge] [--no-public] [--no-fail-exit]
#   brakerrak ort --target espressif-esp32p4 --role devbench --telemetry-json /Volumes/RVDK_P4_SD/telemetry/ort.json
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
  --target, --soc <slug>   Override silicon target (e.g. eswin-eic7700x, starfive-jh7110, espressif-esp32p4, generic-riscv64)
  --role <persona>         Override node role (databroker | databench | babbagebox | babbagebench |
                           visionbox | visionbench | devbench | snitchbench | lilsnitch)
  --stage <tag>            ORT stage tag (default: day0-pre-forge | day1-post-forge)
  --out-dir <dir>          Snapshot output directory (default: ~/.brakerrak/snapshots)
  --config <path>          Explicit node.env config path (default: /etc/brakerrak/node.env)
  --window <seconds>       Quiescent baseline profiling window (default: 5.0)
  --telemetry-json <path>  Host-proxied telemetry JSON (e.g. from ESP32-P4 SD or serial dump)
  --serial-port <dev>      Read-only USB-Serial-JTAG device path (e.g. /dev/ttyACM0, /dev/cu.usbmodem*)
  --no-public              Skip generating redacted .public.json artifact
  --no-fail-exit           Exit 0 even if overall_status == "FAIL"
  --quiet                  Suppress human-readable stdout summary banner
  -h, --help               Show this help message and exit

Examples:
  brakerrak ort --target espressif-esp32p4 --role devbench --telemetry-json /Volumes/RVDK_P4_SD/telemetry/ort.json
  brakerrak ort --target p4 --role snitchbench --serial-port /dev/ttyACM0 --stage day1-post-forge
EOF
}

TARGET_BOARD="${BRAKERRAK_TARGET:-}"
ROLE_OVERRIDE=""
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
        --role)
            brak_require_arg "$1" "${2:-}"
            ROLE_OVERRIDE="$2"
            shift 2
            ;;
        --role=*)
            ROLE_OVERRIDE="${1#*=}"
            brak_require_arg "--role" "$ROLE_OVERRIDE"
            shift
            ;;
        --stage|--out-dir|--config|--window|--telemetry-json|--serial-port)
            brak_require_arg "$1" "${2:-}"
            FORWARD_ARGS+=("$1" "$2")
            shift 2
            ;;
        --stage=*|--out-dir=*|--config=*|--window=*|--telemetry-json=*|--serial-port=*)
            _flag="${1%%=*}"
            _val="${1#*=}"
            brak_require_arg "$_flag" "$_val"
            FORWARD_ARGS+=("$_flag" "$_val")
            shift
            ;;
        --no-public|--no-fail-exit|--quiet)
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

if [[ -n "$ROLE_OVERRIDE" ]]; then
    _raw_role="$ROLE_OVERRIDE"
    ROLE_OVERRIDE="$(brak_normalize_role "$_raw_role")"
    if [[ -z "$ROLE_OVERRIDE" ]]; then
        log_fatal "Unknown role '${_raw_role}' (expected: databroker | databench | babbagebox | babbagebench | visionbox | visionbench | devbench | snitchbench | lilsnitch)"
    fi
    FORWARD_ARGS+=("--role" "$ROLE_OVERRIDE")
fi

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
