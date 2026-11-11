#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared End-to-End Convergence & Idempotency Verification Harness
# Path: brakerrak/scripts/verify-convergence.sh
#
# Usage:
#   sudo brakerrak verify [--role databroker|databench] [--hostname <name>] [--force-rebuild-pg]
#   sudo ./scripts/verify-convergence.sh [--out-dir ~/.brakerrak/snapshots]
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[VERIFY:FATAL] Run as root or via 'sudo brakerrak verify'." >&2
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAKERRAK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6 2>/dev/null || eval echo "~${REAL_USER}")"
[[ -z "$REAL_HOME" ]] && REAL_HOME="/root"

NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"
SNAP_DIR="${REAL_HOME}/.brakerrak/snapshots"
TARGET_BOARD="${BRAKERRAK_TARGET:-}"

PASS1_ARGS=()
PASS2_ARGS=()
ORT_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_BOARD="${2:-}"
            PASS1_ARGS+=("--target" "${2:-}")
            PASS2_ARGS+=("--target" "${2:-}")
            ORT_ARGS+=("--target" "${2:-}")
            shift 2
            ;;
        --out-dir)
            SNAP_DIR="${2:-}"
            shift 2
            ;;
        --force-wipe-nvme|--force-wipe-raid|--force-rebuild-pg|--force-build|--compile-pg|--no-pkg-cache)
            # Forward destructive/compile flags ONLY to Stage 1 so Stage 2 validates idempotency
            PASS1_ARGS+=("$1")
            shift
            ;;
        *)
            PASS1_ARGS+=("$1")
            PASS2_ARGS+=("$1")
            shift
            ;;
    esac
done

MOUNT_POINT="/mnt/nvme_pgdata"
if [[ -f "$NODE_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$NODE_ENV"
fi

install -d -m 0750 -o "$REAL_USER" -g "$REAL_USER" "$SNAP_DIR"

echo ">>> [STAGE 0] Checking Day-0 Pre-Forge Clean-Room ORT Snapshot..."
if mountpoint -q "$MOUNT_POINT" 2>/dev/null && ls "${SNAP_DIR}"/*day0-pre-forge*.json >/dev/null 2>&1; then
    echo "[SKIP] Resuming interrupted build; preserving existing Clean-Room Day-0 snapshot in ${SNAP_DIR}"
else
    bash "${SCRIPT_DIR}/ort-snapshot.sh" ${ORT_ARGS[@]+"${ORT_ARGS[@]}"} --stage day0-pre-forge --out-dir "$SNAP_DIR"
    chown -R "${REAL_USER}:${REAL_USER}" "$SNAP_DIR"
fi

echo ""
echo ">>> [STAGE 1] Executing Convergence Pass 1 (RVDK OS/BSP + 4Kn NVMe + PG 18.6 + Services)..."
bash "${BRAKERRAK_ROOT}/forge.sh" ${PASS1_ARGS[@]+"${PASS1_ARGS[@]}"}

echo ""
echo ">>> [STAGE 2] Executing Idempotency Validation Pass 2 (Expecting Converged [SKIP] States)..."
bash "${BRAKERRAK_ROOT}/forge.sh" ${PASS2_ARGS[@]+"${PASS2_ARGS[@]}"}

echo ""
echo ">>> [STAGE 3] Capturing Day-1 Post-Forge CTD Provenance Snapshot..."
bash "${SCRIPT_DIR}/ort-snapshot.sh" ${ORT_ARGS[@]+"${ORT_ARGS[@]}"} --stage day1-post-forge --out-dir "$SNAP_DIR"
chown -R "${REAL_USER}:${REAL_USER}" "$SNAP_DIR"

echo ""
echo ">>> [PASS] Full BrakerRak Convergence & Idempotency Lifecycle Verified!"
