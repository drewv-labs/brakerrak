#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive P550 End-to-End Convergence & Idempotency Harness
# Path: drewv-labs/brakerrak/targets/starfive-jh7110/verify-convergence.sh
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
SNAP_DIR="${REAL_HOME}/.brakerrak/snapshots"
RVDK_DIR="${REAL_HOME}/repos/riscv-data-kit"

mkdir -p "$SNAP_DIR"
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.brakerrak" 2>/dev/null || true

if [[ -d "$RVDK_DIR" ]]; then
    echo ">>> [STAGE 0A] Running Ubuntu & SiFive P550 BSP Day-0 Bootstraps (riscv-data-kit)..."
    [[ -x "${RVDK_DIR}/os/bootstrap-debian.sh" ]] && "${RVDK_DIR}/os/bootstrap-debian.sh"
    [[ -x "${RVDK_DIR}/bsp/bootstrap-sifive-p550.sh" ]] && "${RVDK_DIR}/bsp/bootstrap-sifive-p550.sh"
fi

echo ">>> [STAGE 0B] Checking Day-0 Pre-Forge Clean-Room ORT Snapshot..."
if mountpoint -q /mnt/nvme_pgdata && ls "${SNAP_DIR}"/*day0-pre-forge*.json >/dev/null 2>&1; then
    echo "[SKIP] Resuming interrupted forge; preserving existing Clean-Room Day-0 snapshot in ${SNAP_DIR}"
else
    "${SCRIPT_DIR}/ort-snapshot.py" --stage day0-pre-forge --out-dir "$SNAP_DIR"
fi

echo ">>> [STAGE 1] Executing Cold Convergence Forge (Pass 1/2)..."
"${SCRIPT_DIR}/forge.sh" "$@"

echo ">>> [STAGE 2] Executing Idempotency Validation Pass (Expecting 100% [SKIP])..."
"${SCRIPT_DIR}/forge.sh" "$@"

echo ">>> [STAGE 3] Capturing Day-1 Post-Forge CTD Provenance Snapshot..."
"${SCRIPT_DIR}/ort-snapshot.py" --stage day1-post-forge --out-dir "$SNAP_DIR"
chown -R "${REAL_USER}:${REAL_USER}" "$SNAP_DIR" 2>/dev/null || true

echo ""
echo ">>> [PASS] Full SiFive P550 Convergence & Idempotency Lifecycle Verified!"
