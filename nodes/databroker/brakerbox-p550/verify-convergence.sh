#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // End-to-End Convergence & Idempotency Verification Harness
# Path: brakerrak/nodes/databrokers/brakerbox-p550/verify-convergence.sh
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAKERRAK_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PARENT_DIR="$(cd "${BRAKERRAK_ROOT}/.." && pwd)"
DATAKIT_ROOT="${DATAKIT_ROOT:-${PARENT_DIR}/riscv-data-kit}"
DATAKIT_REPO_URL="${DATAKIT_REPO_URL:-https://github.com/drewv-labs/riscv-data-kit.git}"
SNAP_DIR="${SCRIPT_DIR}/snapshots"

FORGE_EXTRA_ARGS=()
for arg in "$@"; do
    [[ "$arg" == "--use-pkg-cache" ]] && FORGE_EXTRA_ARGS+=("--use-pkg-cache")
done

mkdir -p "$SNAP_DIR"

# Ensure riscv-data-kit is present as a sibling repo (or at DATAKIT_ROOT)
if [[ ! -d "$DATAKIT_ROOT" ]]; then
    echo ">>> [PREFLIGHT] Sibling riscv-data-kit not found at ${DATAKIT_ROOT}; cloning..."
    git clone "$DATAKIT_REPO_URL" "$DATAKIT_ROOT"
fi

echo ">>> [STAGE 0A] Running Ubuntu & SiFive P550 BSP Day-0 Bootstraps (riscv-data-kit)..."
sudo "${DATAKIT_ROOT}/os/bootstrap-ubuntu.sh" --user drew --hostname brakerbox-p550 --nopasswd
sudo "${DATAKIT_ROOT}/sifive/hifive-premier-p550/bootstrap.sh"

echo ">>> [STAGE 0B] Capturing Day-0 Pre-Forge Clean-Room ORT Snapshot..."
sudo "${SCRIPT_DIR}/ort-snapshot.py" --stage day0-pre-forge --out-dir "$SNAP_DIR"

echo ">>> [STAGE 1] Executing Cold Convergence Forge (NVMe 4Kn + Btrfs RAID10 + PG18)..."
sudo "${SCRIPT_DIR}/forge.sh" --role prod --with-raid "${FORGE_EXTRA_ARGS[@]}"

echo ">>> [STAGE 2] Executing Idempotency Validation Pass (Expecting 100% [SKIP])..."
sudo "${SCRIPT_DIR}/forge.sh" --role prod --with-raid "${FORGE_EXTRA_ARGS[@]}"

echo ">>> [STAGE 3] Capturing Day-1 Post-Forge CTD Provenance Snapshot..."
sudo "${SCRIPT_DIR}/ort-snapshot.py" --stage day1-post-forge --out-dir "$SNAP_DIR"

echo ""
echo ">>> [PASS] Full BrakerBox-P550 Convergence & Idempotency Lifecycle Verified!"
