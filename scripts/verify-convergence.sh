#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared End-to-End Convergence & Idempotency Verification Harness
# Path: brakerrak/scripts/verify-convergence.sh
#
# Usage:
#   sudo brakerrak verify [--role databroker|databench|babbagebox|babbagebench|visionbox|visionbench|devbench] [--hostname <name>] [--force-rebuild-pg] [--no-apt-update] [--noprogbar]
#   sudo ./scripts/verify-convergence.sh [--out-dir ~/.brakerrak/snapshots] [--noprogbar]
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAKERRAK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-common.sh"
brak_log_init "VERIFY"

usage() {
    cat <<'EOF'
Usage: sudo brakerrak verify [options] [forge-options...]

Options:
  --target <slug>    Override silicon target for ORT snapshots and forge passes
  --out-dir <dir>    Directory for Day-0 & Day-1 ORT snapshots (default: ~/.brakerrak/snapshots)
  -h, --help         Show this help message and exit

All other flags are forwarded to forge.sh. Destructive/rebuild flags
(--force-wipe-nvme, --force-wipe-raid, --force-rebuild-pg, --force-build,
--compile-pg, --no-pkg-cache) are applied ONLY to Stage 1 so Stage 2 validates
strict Pass-2 idempotency.
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        log_fatal "Run as root or via 'sudo brakerrak verify'."
    fi
fi

brak_resolve_user
brak_resolve_node_env --migrate

SNAP_DIR="${REAL_HOME}/.brakerrak/snapshots"
PASS1_ARGS=()
PASS2_ARGS=()
ORT_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            brak_require_arg "$1" "${2:-}"
            PASS1_ARGS+=("--target" "$2")
            PASS2_ARGS+=("--target" "$2")
            ORT_ARGS+=("--target" "$2")
            shift 2
            ;;
        --target=*)
            _tval="${1#*=}"
            brak_require_arg "--target" "$_tval"
            PASS1_ARGS+=("--target" "$_tval")
            PASS2_ARGS+=("--target" "$_tval")
            ORT_ARGS+=("--target" "$_tval")
            shift
            ;;
        --out-dir)
            brak_require_arg "$1" "${2:-}"
            SNAP_DIR="$2"
            shift 2
            ;;
        --out-dir=*)
            SNAP_DIR="${1#*=}"
            brak_require_arg "--out-dir" "$SNAP_DIR"
            shift
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
if [[ -r "$NODE_ENV" ]]; then
    brak_load_kv_env "$NODE_ENV" MOUNT_POINT || log_fatal "Failed to parse node config: ${NODE_ENV}"
fi

install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$SNAP_DIR"

RUNTIME_DIR="$(brak_runtime_dir)"
export BRAKERRAK_RUNTIME_DIR="$RUNTIME_DIR"
PASS2_LOG="${RUNTIME_DIR}/verify-pass2.$$.log"

_verify_cleanup() {
    rm -f "${PASS2_LOG:-}" 2>/dev/null || true
}
trap '_verify_cleanup' EXIT
trap '_verify_cleanup; trap - INT; kill -INT $$' INT
trap '_verify_cleanup; trap - TERM; kill -TERM $$' TERM

# Locate newest ORT snapshot JSON for <stage> in <snap_dir> and assert overall_status != "FAIL".
_verify_assert_ort_status() {
    local stage="$1"
    local snap_dir="$2"
    local latest_snap=""

    local f
    # Prefer full private snapshot JSON; fall back to any matching stage JSON
    for f in "${snap_dir}"/*"${stage}"*.json; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.public.json ]] && continue
        if [[ -z "$latest_snap" || "$f" -nt "$latest_snap" ]]; then
            latest_snap="$f"
        fi
    done
    if [[ -z "$latest_snap" ]]; then
        for f in "${snap_dir}"/*"${stage}"*.json; do
            [[ -f "$f" ]] || continue
            if [[ -z "$latest_snap" || "$f" -nt "$latest_snap" ]]; then
                latest_snap="$f"
            fi
        done
    fi

    if [[ -z "$latest_snap" || ! -r "$latest_snap" ]]; then
        log_fatal "ORT assertion FAILED: no snapshot JSON found for stage '${stage}' in ${snap_dir}."
    fi

    local status=""
    if command -v jq >/dev/null 2>&1; then
        status="$(jq -r '.operational_readiness_test.overall_status // .overall_status // empty' "$latest_snap" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
        status="$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1], encoding="utf-8")); ort = d.get("operational_readiness_test"); print((ort.get("overall_status") if isinstance(ort, dict) else None) or d.get("overall_status", ""))' "$latest_snap" 2>/dev/null || true)"
    else
        status="$(awk -F'"' '/"overall_status"/ {print $4; exit}' "$latest_snap" 2>/dev/null || true)"
    fi

    if [[ -z "$status" || "$status" == "FAIL" ]]; then
        log_fatal "ORT assertion FAILED for stage '${stage}': overall_status='${status:-missing}' (${latest_snap})."
    fi
    log_ok "ORT assertion passed for '${stage}': overall_status=${status} ($(basename "$latest_snap"))"
}

echo ">>> [STAGE 0] Checking Day-0 Pre-Forge Clean-Room ORT Snapshot..."
if mountpoint -q "$MOUNT_POINT" 2>/dev/null && compgen -G "${SNAP_DIR}/*day0-pre-forge*.json" >/dev/null 2>&1; then
    log_skip "Resuming interrupted build; preserving existing Clean-Room Day-0 snapshot in ${SNAP_DIR}"
    _verify_assert_ort_status "day0-pre-forge" "$SNAP_DIR"
else
    set +e
    bash "${SCRIPT_DIR}/ort-snapshot.sh" ${ORT_ARGS[@]+"${ORT_ARGS[@]}"} --stage day0-pre-forge --out-dir "$SNAP_DIR"
    STAGE0_RC=$?
    set -e
    chown -R "${REAL_USER}:${REAL_GRP}" "$SNAP_DIR"
    if (( STAGE0_RC != 0 )); then
        log_fatal "Stage 0 (day0-pre-forge) ORT snapshot failed with exit code ${STAGE0_RC}."
    fi
    _verify_assert_ort_status "day0-pre-forge" "$SNAP_DIR"
fi

echo ""
echo ">>> [STAGE 1] Executing Convergence Pass 1 (RVDK OS/BSP + 4Kn NVMe + PG 18.6 + Services)..."
bash "${BRAKERRAK_ROOT}/forge.sh" ${PASS1_ARGS[@]+"${PASS1_ARGS[@]}"}

echo ""
echo ">>> [STAGE 2] Executing Idempotency Validation Pass 2 (Expecting Converged [SKIP] States)..."
(
    umask 077
    : > "$PASS2_LOG"
)
set +e
APT_UPDATED="true" bash "${BRAKERRAK_ROOT}/forge.sh" ${PASS2_ARGS[@]+"${PASS2_ARGS[@]}"} 2>&1 | tee "$PASS2_LOG"
PASS2_RC=${PIPESTATUS[0]}
set -e
if (( PASS2_RC != 0 )); then
    log_fatal "Stage 2 (Pass 2) forge failed with exit code ${PASS2_RC}."
fi

DESTRUCTIVE_RE='nvme[[:space:]]+format|mkfs\.[a-z0-9]+|pg_createcluster|(^|[^[:alnum:]_])initdb([^[:alnum:]_]|$)'
if grep -E -i -n "$DESTRUCTIVE_RE" "$PASS2_LOG" >/dev/null 2>&1; then
    log_warn "Destructive storage or cluster initialization command(s) detected during Pass 2:"
    grep -E -i -n "$DESTRUCTIVE_RE" "$PASS2_LOG" >&2 || true
    log_fatal "Stage 2 idempotency assertion FAILED: Pass 2 must not execute nvme format, mkfs.*, pg_createcluster, or initdb."
fi
log_ok "Stage 2 idempotency assertion passed: zero destructive storage or cluster init commands ran during Pass 2."

echo ""
echo ">>> [STAGE 3] Capturing Day-1 Post-Forge CTD Provenance Snapshot..."
set +e
bash "${SCRIPT_DIR}/ort-snapshot.sh" ${ORT_ARGS[@]+"${ORT_ARGS[@]}"} --stage day1-post-forge --out-dir "$SNAP_DIR"
STAGE3_RC=$?
set -e
chown -R "${REAL_USER}:${REAL_GRP}" "$SNAP_DIR"
if (( STAGE3_RC != 0 )); then
    log_fatal "Stage 3 (day1-post-forge) ORT snapshot failed with exit code ${STAGE3_RC}."
fi
_verify_assert_ort_status "day1-post-forge" "$SNAP_DIR"

echo ""
echo ">>> [PASS] Full BrakerRak Convergence & Idempotency Lifecycle Verified!"
