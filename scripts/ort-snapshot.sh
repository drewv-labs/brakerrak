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

# Auto-Detect Silicon Target from /etc/rvdk/kit.env -> /proc/device-tree/model
DT_MODEL="Unknown"
if [[ -z "$TARGET_BOARD" && -r /etc/rvdk/kit.env ]]; then
    # shellcheck disable=SC1091
    source /etc/rvdk/kit.env
    [[ -n "${RVDK_SOC_SLUG:-}" ]] && TARGET_BOARD="$RVDK_SOC_SLUG"
    [[ -n "${RVDK_DT_MODEL:-}" ]] && DT_MODEL="$RVDK_DT_MODEL"
fi

if [[ "$DT_MODEL" == "Unknown" && -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi

if [[ -z "$TARGET_BOARD" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"Megrez"*|*"StarPro64"*|*"EIC7700"*)
            TARGET_BOARD="eswin-eic7700x" ;;
        *"Unmatched"*|*"FU740"*)
            TARGET_BOARD="sifive-fu740" ;;
        *"OrangePi RV2"*|*"Orange Pi RV2"*|*"OrangePi R2S"*|*"Orange Pi R2S"*|*"BPI-F3"*|*"BPI-CM6"*)
            TARGET_BOARD="spacemit-k1" ;;
        *"VisionFive 2 Lite"*|*"VF2 Lite"*|*"JH7110S"*|*"JH-7110S"*|*"VisionFive 2"*|*"VF2"*|*"Mars"*|*"Star64"*|*"OrangePi RV"*|*"Orange Pi RV"*|*"JH7110"*)
            TARGET_BOARD="starfive-jh7110" ;;
        *"AIBOX-K3"*|*"Firefly"*K3*|*"Jupiter 2"*|*"SpacemiT K3"*|*"K3"*)
            TARGET_BOARD="spacemit-k3" ;;
        *"Jupiter"*|*"SpacemiT"*|*"K1"*|*"M1"*|*"Ky X1"*)
            TARGET_BOARD="spacemit-k1" ;;
        *"Titan"*|*"DP1000"*)
            TARGET_BOARD="ultrarisc-dp1000" ;;
        *"Atlantis"*|*"Ascalon"*)
            TARGET_BOARD="tenstorrent-atlantis" ;;
        *)
            log_fatal "Could not auto-detect silicon target from Device Tree: '${DT_MODEL}'. Pass --target <board>." ;;
    esac
else
    case "$TARGET_BOARD" in
        eswin-eic7700x|sifive-p550|milkv-megrez)      TARGET_BOARD="eswin-eic7700x" ;;
        sifive-fu740|sifive-unmatched)                TARGET_BOARD="sifive-fu740" ;;
        starfive-jh7110|starfive-vf2|starfive-vf2-lite|milkv-mars|orangepi-rv)
                                                      TARGET_BOARD="starfive-jh7110" ;;
        spacemit-k1|milkv-jupiter|orangepi-rv2|orangepi-r2s|bananapi-f3|bananapi-cm6)
                                                      TARGET_BOARD="spacemit-k1" ;;
        spacemit-k3|milkv-jupiter2|firefly-aibox-k3)  TARGET_BOARD="spacemit-k3" ;;
        ultrarisc-dp1000|milkv-titan)                 TARGET_BOARD="ultrarisc-dp1000" ;;
        tenstorrent-atlantis)                         TARGET_BOARD="tenstorrent-atlantis" ;;
    esac
fi

ORT_SCRIPT="${BRAKERRAK_ROOT}/soc-drawer/${TARGET_BOARD}/ort-snapshot.py"
ORT_SOC_ARGS=()
if [[ ! -f "$ORT_SCRIPT" ]]; then
    ORT_SCRIPT="${BRAKERRAK_ROOT}/soc-drawer/generic-riscv64/ort-snapshot.py"
    ORT_SOC_ARGS=("--soc" "$TARGET_BOARD")
fi
[[ ! -f "$ORT_SCRIPT" ]] && log_fatal "ORT collector not found: ${ORT_SCRIPT}"

log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) -> ${ORT_SCRIPT}"
exec python3 "$ORT_SCRIPT" ${ORT_SOC_ARGS[@]+"${ORT_SOC_ARGS[@]}"} ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
