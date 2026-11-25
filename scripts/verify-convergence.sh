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
  --target <slug>        Override silicon target for ORT snapshots and forge passes
  --mount-point <path>   Override NVMe mountpoint (forwarded to forge passes)
  --out-dir <dir>        Directory for Day-0 & Day-1 ORT snapshots (default: ~/.brakerrak/snapshots)
  -h, --help             Show this help message and exit

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
        _sudo_preserve_env="BRAKERRAK_NODE_ENV,BRAKERRAK_RUNTIME_DIR,BRAKERRAK_NO_PROGBAR,BRAKERRAK_TARGET,BRAKERRAK_ENGINE_DIR,BRAKERRAK_REPO_URL,BRAKERRAK_BRANCH,BRAKERRAK_BASE_URL,RVDK_ENV_FILE,RVDK_BASE_URL,RVDK_NO_PROGBAR,NO_PROGBAR,APT_UPDATED,TS_AUTHKEY,RVDK_INSTALL_SHA256,BRAKERRAK_INSTALL_SHA256,TERM,COLORTERM,LINES,COLUMNS,LANG,LC_ALL"
        exec sudo --preserve-env="$_sudo_preserve_env" bash "${BASH_SOURCE[0]}" "$@"
    else
        log_fatal "Run as root or via 'sudo brakerrak verify'."
    fi
fi

brak_resolve_user
brak_resolve_node_env --migrate

SNAP_DIR="${REAL_HOME}/.brakerrak/snapshots"
CLI_MOUNT_POINT=""
CLI_ENABLE_PG=""
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
        --mount-point)
            brak_require_arg "$1" "${2:-}"
            CLI_MOUNT_POINT="$2"
            PASS1_ARGS+=("--mount-point" "$2")
            PASS2_ARGS+=("--mount-point" "$2")
            shift 2
            ;;
        --mount-point=*)
            CLI_MOUNT_POINT="${1#*=}"
            brak_require_arg "--mount-point" "$CLI_MOUNT_POINT"
            PASS1_ARGS+=("--mount-point" "$CLI_MOUNT_POINT")
            PASS2_ARGS+=("--mount-point" "$CLI_MOUNT_POINT")
            shift
            ;;
        --with-pg)
            CLI_ENABLE_PG="true"
            PASS1_ARGS+=("$1")
            PASS2_ARGS+=("$1")
            shift
            ;;
        --no-pg)
            CLI_ENABLE_PG="false"
            PASS1_ARGS+=("$1")
            PASS2_ARGS+=("$1")
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

_verify_refresh_node_vars() {
    MOUNT_POINT="/mnt/nvme_pgdata"
    ENABLE_POSTGRES="true"
    if [[ -r "$NODE_ENV" ]]; then
        brak_load_kv_env "$NODE_ENV" MOUNT_POINT ENABLE_POSTGRES || log_fatal "Failed to parse node config: ${NODE_ENV}"
    fi
    if [[ -n "$CLI_MOUNT_POINT" ]]; then
        MOUNT_POINT="$CLI_MOUNT_POINT"
    fi
    if [[ -n "$CLI_ENABLE_PG" ]]; then
        ENABLE_POSTGRES="$CLI_ENABLE_PG"
    fi
}

_verify_refresh_node_vars

install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$SNAP_DIR"

RUNTIME_DIR="$(brak_runtime_dir)"
export BRAKERRAK_RUNTIME_DIR="$RUNTIME_DIR"
PASS2_LOG="${RUNTIME_DIR}/verify-pass2.$$.log"

_verify_cleanup() {
    rm -f "${PASS2_LOG:-}" 2>/dev/null || true
}
brak_register_exit_hook _verify_cleanup

_verify_get_xfs_uuid() {
    local mp="$1"
    local fstype="" src="" uuid=""
    if command -v findmnt >/dev/null 2>&1; then
        fstype="$(findmnt -n -o FSTYPE "$mp" 2>/dev/null | head -n1 || true)"
        src="$(findmnt -n -o SOURCE "$mp" 2>/dev/null | head -n1 || true)"
        uuid="$(findmnt -n -o UUID "$mp" 2>/dev/null | head -n1 || true)"
    fi
    if [[ -n "$fstype" && "$fstype" != "xfs" ]]; then
        log_fatal "Convergence assertion FAILED: expected XFS on ${mp}, found '${fstype}'."
    fi
    if [[ -z "$uuid" && -n "$src" ]] && command -v blkid >/dev/null 2>&1; then
        uuid="$(blkid -s UUID -o value "$src" 2>/dev/null | head -n1 || true)"
    fi
    if [[ -z "$uuid" && -n "$src" ]] && command -v lsblk >/dev/null 2>&1; then
        uuid="$(lsblk -ndo UUID "$src" 2>/dev/null | head -n1 || true)"
    fi
    printf '%s\n' "$uuid"
}

_verify_get_pg_sysid() {
    local sysid=""
    if command -v psql >/dev/null 2>&1; then
        if command -v sudo >/dev/null 2>&1; then
            sysid="$(sudo -u postgres psql -tAc "SELECT system_identifier FROM pg_control_system();" 2>/dev/null | tr -d '[:space:]' || true)"
        fi
        if [[ -z "$sysid" ]]; then
            sysid="$(psql -U postgres -tAc "SELECT system_identifier FROM pg_control_system();" 2>/dev/null | tr -d '[:space:]' || true)"
        fi
    fi
    local pg_controldata_bin=""
    if command -v pg_controldata >/dev/null 2>&1; then
        pg_controldata_bin="$(command -v pg_controldata)"
    else
        local cand_bin
        for cand_bin in /usr/lib/postgresql/*/bin/pg_controldata; do
            if [[ -x "$cand_bin" ]]; then
                pg_controldata_bin="$cand_bin"
                break
            fi
        done
    fi
    if [[ -z "$sysid" && -n "$pg_controldata_bin" ]]; then
        local pgdata="" cand
        if command -v psql >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
            pgdata="$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null | tr -d '[:space:]' || true)"
        fi
        if [[ -z "$pgdata" ]]; then
            for cand in "${MOUNT_POINT}/pgdata" /var/lib/postgresql/18/main /var/lib/postgresql/*/main; do
                if [[ -f "${cand}/global/pg_control" ]]; then
                    pgdata="$cand"
                    break
                fi
            done
        fi
        if [[ -n "$pgdata" && -d "$pgdata" ]]; then
            sysid="$("$pg_controldata_bin" "$pgdata" 2>/dev/null | awk -F: '/Database system identifier/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' || true)"
        fi
    fi
    printf '%s\n' "$sysid"
}

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

_verify_refresh_node_vars

PASS1_XFS_UUID=""
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    PASS1_XFS_UUID="$(_verify_get_xfs_uuid "$MOUNT_POINT")"
fi
if [[ -z "$PASS1_XFS_UUID" ]]; then
    log_fatal "Stage 1 assertion FAILED: unable to resolve XFS filesystem UUID on ${MOUNT_POINT}."
fi

PASS1_PG_SYSID=""
if [[ "$ENABLE_POSTGRES" == "true" ]]; then
    PASS1_PG_SYSID="$(_verify_get_pg_sysid)"
    if [[ -z "$PASS1_PG_SYSID" ]]; then
        log_fatal "Stage 1 assertion FAILED: unable to resolve PostgreSQL system_identifier."
    fi
fi

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

SKIP_MARKER_COUNT="$(sed -E $'s/\x1b\\[[0-9;]*[[:alpha:]]//g' "$PASS2_LOG" | grep -cE '(^|[[:space:]])\[SKIP\]([[:space:]]|$)' || true)"
if [[ ! "$SKIP_MARKER_COUNT" =~ ^[0-9]+$ ]] || (( SKIP_MARKER_COUNT == 0 )); then
    log_fatal "Stage 2 idempotency assertion FAILED: expected structured [SKIP] convergence markers in Pass 2 output, found 0."
fi

PASS2_XFS_UUID=""
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    PASS2_XFS_UUID="$(_verify_get_xfs_uuid "$MOUNT_POINT")"
fi
if [[ -z "$PASS2_XFS_UUID" || "$PASS2_XFS_UUID" != "$PASS1_XFS_UUID" ]]; then
    log_fatal "Stage 2 idempotency assertion FAILED: XFS UUID changed on ${MOUNT_POINT} (Pass 1='${PASS1_XFS_UUID}', Pass 2='${PASS2_XFS_UUID:-missing}')."
fi

if [[ "$ENABLE_POSTGRES" == "true" ]]; then
    PASS2_PG_SYSID="$(_verify_get_pg_sysid)"
    if [[ -z "$PASS2_PG_SYSID" || "$PASS2_PG_SYSID" != "$PASS1_PG_SYSID" ]]; then
        log_fatal "Stage 2 idempotency assertion FAILED: PostgreSQL system_identifier changed (Pass 1='${PASS1_PG_SYSID}', Pass 2='${PASS2_PG_SYSID:-missing}')."
    fi
    log_ok "Stage 2 idempotency assertion passed: ${SKIP_MARKER_COUNT} [SKIP] marker(s), unchanged XFS UUID (${PASS2_XFS_UUID}), unchanged PG system_identifier (${PASS2_PG_SYSID})."
else
    log_skip "PostgreSQL disabled (ENABLE_POSTGRES=${ENABLE_POSTGRES}); skipped system_identifier comparison."
    log_ok "Stage 2 idempotency assertion passed: ${SKIP_MARKER_COUNT} [SKIP] marker(s), unchanged XFS UUID (${PASS2_XFS_UUID})."
fi

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
