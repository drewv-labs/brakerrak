#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared ORT & CTD Provenance Snapshot Dispatcher
# Path: brakerrak/scripts/ort-snapshot.sh
#
# Usage:
#   ./scripts/ort-snapshot.sh [--stage day0-pre-forge|day1-post-forge] [--out-dir ~/.brakerrak/snapshots]
#   sudo brakerrak ort [--stage day0-pre-forge|day1-post-forge]
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAKERRAK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log_brak()  { printf "\033[1;35m[BRAKERRAK:ORT]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[BRAKERRAK:ORT:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

TARGET_BOARD="${BRAKERRAK_TARGET:-}"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_BOARD="${2:-}"
            shift 2
            ;;
        *)
            FORWARD_ARGS+=("$1")
            shift
            ;;
    esac
done

# Auto-Detect Silicon Target from /proc/device-tree/model if not explicitly passed
DT_MODEL="Unknown"
if [[ -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi

if [[ -z "$TARGET_BOARD" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"EIC7700"*|*"Megrez"*)
            TARGET_BOARD="eswin-eic7700x" ;;
        *"VisionFive 2"*|*"JH7110"*|*"Mars"*|*"OrangePi RV"*)
            TARGET_BOARD="starfive-jh7110" ;;
        *"Jupiter 2"*|*"SpacemiT K3"*|*"K3"*)
            TARGET_BOARD="spacemit-k3" ;;
        *"Jupiter"*|*"SpacemiT"*|*"K1"*|*"M1"*|*"Ky X1"*|*"OrangePi RV2"*)
            TARGET_BOARD="spacemit-k1" ;;
        *"Titan"*|*"DP1000"*)
            TARGET_BOARD="ultrarisc-dp1000" ;;
        *)
            log_fatal "Could not auto-detect silicon target from Device Tree: '${DT_MODEL}'. Pass --target <board>." ;;
    esac
else
    case "$TARGET_BOARD" in
        eswin-eic7700x|sifive-p550) TARGET_BOARD="eswin-eic7700x" ;;
    esac
fi

ORT_SCRIPT="${BRAKERRAK_ROOT}/soc-drawer/${TARGET_BOARD}/ort-snapshot.py"
[[ ! -f "$ORT_SCRIPT" ]] && log_fatal "ORT collector not found: ${ORT_SCRIPT}"

log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) -> ${ORT_SCRIPT}"
exec python3 "$ORT_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
