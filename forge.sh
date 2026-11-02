#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Universal Curl-to-Forge Dispatcher & CLI Entrypoint
# Usage (Remote Curl):
#   curl -fsSL https://raw.githubusercontent.com/drewv-labs/brakerrak/main/forge.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/drewv-labs/brakerrak/main/forge.sh | sudo bash -s -- --role databroker
#   curl -fsSL https://raw.githubusercontent.com/drewv-labs/brakerrak/main/forge.sh | sudo bash -s -- verify --use-pkg-cache
#
# Usage (Local CLI after bootstrap):
#   sudo brakerrak [--role databroker|databench]
#   sudo brakerrak ort [--stage day1-post-forge]
#   sudo brakerrak verify [--use-pkg-cache]
#   sudo brakerrak reset --confirm-destroy [--keep-pg-cache]
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[FATAL] Please pipe into 'sudo bash': curl -fsSL ... | sudo bash" >&2
        exit 1
    fi
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
BRAKER_DIR="${REAL_HOME}/.brakerrak"
ENGINE_DIR="${BRAKER_DIR}/engine"
REPO_URL="${BRAKERRAK_REPO_URL:-https://github.com/drewv-labs/brakerrak.git}"
REPO_BRANCH="${BRAKERRAK_BRANCH:-main}"

ACTION="forge"
if [[ $# -gt 0 ]]; then
    case "$1" in
        forge|ort|verify|reset)
            ACTION="$1"
            shift
            ;;
    esac
fi

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

if [[ -z "$TARGET_BOARD" ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")"
    case "$DT_MODEL" in
        *"Premier P550"*|*"EIC7700"*)
            TARGET_BOARD="sifive-p550"
            ;;
        *"VisionFive 2"*|*"JH7110"*)
            TARGET_BOARD="starfive-jh7110"
            ;;
        *"Jupiter"*|*"SpacemiT"*|*"K1"*|*"M1"*)
            TARGET_BOARD="spacemit-k1"
            ;;
        *"Titan"*|*"DP1000"*)
            TARGET_BOARD="ultrarisc-dp1000"
            ;;
        *)
            echo "[FATAL] Could not auto-detect silicon target from Device Tree: '${DT_MODEL}'" >&2
            echo "Pass --target <sifive-p550|starfive-jh7110> explicitly." >&2
            exit 1
            ;;
    esac
    echo "[BRAKERRAK] Auto-detected Silicon Target: ${TARGET_BOARD} (${DT_MODEL})"
fi

SCRIPT_SELF="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SELF" ]]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_SELF" 2>/dev/null || realpath "$SCRIPT_SELF" 2>/dev/null || echo "$SCRIPT_SELF")"
    CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
else
    CANDIDATE_ROOT=""
fi

if [[ -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/targets/${TARGET_BOARD}" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
else
    if ! command -v git >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=120 update -q
        apt-get -o DPkg::Lock::Timeout=120 install -y git ca-certificates curl
    fi
    install -d -m 0750 -o "$REAL_USER" -g "$REAL_USER" "$BRAKER_DIR"
    if [[ -d "${ENGINE_DIR}/.git" ]]; then
        echo "[BRAKERRAK] Syncing engine checkout in ${ENGINE_DIR}..."
        sudo -u "$REAL_USER" git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
        sudo -u "$REAL_USER" git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
    else
        echo "[BRAKERRAK] Cloning ${REPO_URL} into ${ENGINE_DIR}..."
        rm -rf "$ENGINE_DIR"
        sudo -u "$REAL_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
    fi
    LOCAL_ROOT="$ENGINE_DIR"
fi

ln -sf "${LOCAL_ROOT}/forge.sh" /usr/local/bin/brakerrak

TARGET_DIR="${LOCAL_ROOT}/targets/${TARGET_BOARD}"
case "$ACTION" in
    forge)  EXEC_CMD=(bash "${TARGET_DIR}/forge.sh") ;;
    ort)    EXEC_CMD=(python3 "${TARGET_DIR}/ort-snapshot.py") ;;
    verify) EXEC_CMD=(bash "${TARGET_DIR}/verify-convergence.sh") ;;
    reset)  EXEC_CMD=(bash "${TARGET_DIR}/reset-day0.sh") ;;
esac

echo "[BRAKERRAK] Dispatching [${ACTION}] -> ${TARGET_DIR} ${FORWARD_ARGS[*]:-}"
exec "${EXEC_CMD[@]}" "${FORWARD_ARGS[@]}"
