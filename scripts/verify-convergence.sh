#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared End-to-End Convergence & Idempotency Verification Harness
# Path: brakerrak/scripts/verify-convergence.sh
#
# Usage:
#   sudo brakerrak verify [--role databroker|databench|babbagebox|babbagebench|visionbox|visionbench|devbench|snitchbench|lilsnitch] [--hostname <name>] [--force-rebuild-pg] [--no-apt-update] [--noprogbar]
#   sudo ./scripts/verify-convergence.sh [--out-dir ~/.brakerrak/snapshots] [--noprogbar]
#   brakerrak verify --target p4 --role devbench --tune iot --stage-dir /Volumes/RVDK_P4_SD
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
  --target <slug>          Override silicon target for ORT snapshots and forge passes
  --media <nvme|sd>        Override target storage media (default: nvme on riscv64, sd on riscv32)
  --stage-dir <dir>        Host-assisted SD staging root (validates staged config digest idempotency)
  --mount-point <path>     Override NVMe/SD mountpoint (forwarded to forge passes)
  --out-dir <dir>          Directory for Day-0 & Day-1 ORT snapshots (default: ~/.brakerrak/snapshots)
  --telemetry-json <path>  Host-proxied telemetry JSON forwarded to ORT Stage 0 / Stage 3
  --serial-port <dev>      USB-Serial-JTAG device forwarded to ORT Stage 0 / Stage 3
  -h, --help               Show this help message and exit

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

_HAS_STAGE_DIR="false"
for _arg in "$@"; do
    case "$_arg" in
        --stage-dir|--stage-dir=*) _HAS_STAGE_DIR="true"; break ;;
    esac
done

if [[ $EUID -ne 0 && "$_HAS_STAGE_DIR" != "true" ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        _sudo_preserve_env="BRAKERRAK_NODE_ENV,BRAKERRAK_RUNTIME_DIR,BRAKERRAK_NO_PROGBAR,BRAKERRAK_TARGET,BRAKERRAK_ENGINE_DIR,BRAKERRAK_REPO_URL,BRAKERRAK_BRANCH,BRAKERRAK_BASE_URL,RVDK_BIN,RVDK_ENV_FILE,RVDK_BASE_URL,RVDK_NO_PROGBAR,NO_PROGBAR,APT_UPDATED,TS_AUTHKEY,RVDK_INSTALL_SHA256,BRAKERRAK_INSTALL_SHA256,TERM,COLORTERM,LINES,COLUMNS,LANG,LC_ALL"
        exec sudo --preserve-env="$_sudo_preserve_env" bash "${BASH_SOURCE[0]}" "$@"
    else
        log_fatal "Run as root or via 'sudo brakerrak verify'."
    fi
fi

brak_resolve_user
brak_resolve_node_env --migrate

SNAP_DIR="${REAL_HOME}/.brakerrak/snapshots"
CLI_TARGET="${BRAKERRAK_TARGET:-}"
CLI_MEDIA=""
CLI_STAGE_DIR=""
CLI_MOUNT_POINT=""
CLI_ENABLE_PG=""
CLI_TELEMETRY_JSON=""
CLI_SERIAL_PORT=""
PASS1_ARGS=()
PASS2_ARGS=()
ORT_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            brak_require_arg "$1" "${2:-}"
            CLI_TARGET="$2"
            PASS1_ARGS+=("--target" "$2")
            PASS2_ARGS+=("--target" "$2")
            ORT_ARGS+=("--target" "$2")
            shift 2
            ;;
        --target=*)
            _tval="${1#*=}"
            brak_require_arg "--target" "$_tval"
            CLI_TARGET="$_tval"
            PASS1_ARGS+=("--target" "$_tval")
            PASS2_ARGS+=("--target" "$_tval")
            ORT_ARGS+=("--target" "$_tval")
            shift
            ;;
        --media)
            brak_require_arg "$1" "${2:-}"
            CLI_MEDIA="$(tr '[:upper:]' '[:lower:]' <<< "$2")"
            PASS1_ARGS+=("--media" "$CLI_MEDIA")
            PASS2_ARGS+=("--media" "$CLI_MEDIA")
            shift 2
            ;;
        --media=*)
            _mval="${1#*=}"
            brak_require_arg "--media" "$_mval"
            CLI_MEDIA="$(tr '[:upper:]' '[:lower:]' <<< "$_mval")"
            PASS1_ARGS+=("--media" "$CLI_MEDIA")
            PASS2_ARGS+=("--media" "$CLI_MEDIA")
            shift
            ;;
        --stage-dir)
            brak_require_arg "$1" "${2:-}"
            CLI_STAGE_DIR="${2%/}"
            [[ -n "$CLI_STAGE_DIR" ]] || log_fatal "Refusing '/' as --stage-dir."
            PASS1_ARGS+=("--stage-dir" "$CLI_STAGE_DIR")
            PASS2_ARGS+=("--stage-dir" "$CLI_STAGE_DIR")
            shift 2
            ;;
        --stage-dir=*)
            _sval="${1#*=}"
            brak_require_arg "--stage-dir" "$_sval"
            CLI_STAGE_DIR="${_sval%/}"
            [[ -n "$CLI_STAGE_DIR" ]] || log_fatal "Refusing '/' as --stage-dir."
            PASS1_ARGS+=("--stage-dir" "$CLI_STAGE_DIR")
            PASS2_ARGS+=("--stage-dir" "$CLI_STAGE_DIR")
            shift
            ;;
        --telemetry-json)
            brak_require_arg "$1" "${2:-}"
            CLI_TELEMETRY_JSON="$2"
            ORT_ARGS+=("--telemetry-json" "$2")
            shift 2
            ;;
        --telemetry-json=*)
            _tj="${1#*=}"
            brak_require_arg "--telemetry-json" "$_tj"
            CLI_TELEMETRY_JSON="$_tj"
            ORT_ARGS+=("--telemetry-json" "$_tj")
            shift
            ;;
        --serial-port)
            brak_require_arg "$1" "${2:-}"
            CLI_SERIAL_PORT="$2"
            ORT_ARGS+=("--serial-port" "$2")
            shift 2
            ;;
        --serial-port=*)
            _sp="${1#*=}"
            brak_require_arg "--serial-port" "$_sp"
            CLI_SERIAL_PORT="$_sp"
            ORT_ARGS+=("--serial-port" "$_sp")
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

if [[ -n "$CLI_STAGE_DIR" ]]; then
    NODE_ENV="${CLI_STAGE_DIR}/config/node.env"
    export BRAKERRAK_NODE_ENV="$NODE_ENV"
    if [[ -z "$CLI_TELEMETRY_JSON" && -r "${CLI_STAGE_DIR}/telemetry/ort.json" ]]; then
        CLI_TELEMETRY_JSON="${CLI_STAGE_DIR}/telemetry/ort.json"
        ORT_ARGS+=("--telemetry-json" "$CLI_TELEMETRY_JSON")
    fi
fi

_verify_refresh_node_vars() {
    MOUNT_POINT="/mnt/nvme_pgdata"
    ENABLE_POSTGRES="true"
    STORAGE_MEDIA="nvme"
    TARGET_ARCH="riscv64"
    NODE_ROLE=""
    TARGET_BOARD=""
    if brak_resolve_silicon "${CLI_TARGET:-}" >/dev/null 2>&1; then
        :
    fi
    if [[ -r "$NODE_ENV" ]]; then
        brak_load_kv_env "$NODE_ENV" MOUNT_POINT ENABLE_POSTGRES STORAGE_MEDIA TARGET_ARCH NODE_ROLE || log_fatal "Failed to parse node config: ${NODE_ENV}"
    fi
    if [[ -n "$CLI_MOUNT_POINT" ]]; then
        MOUNT_POINT="$CLI_MOUNT_POINT"
    fi
    if [[ -n "$CLI_ENABLE_PG" ]]; then
        ENABLE_POSTGRES="$CLI_ENABLE_PG"
    fi
    if [[ -n "$CLI_MEDIA" ]]; then
        STORAGE_MEDIA="$CLI_MEDIA"
    fi
    if [[ "${TARGET_BOARD:-}" == "espressif-esp32p4" ]]; then
        TARGET_ARCH="riscv32"
        STORAGE_MEDIA="sd"
        ENABLE_POSTGRES="false"
    fi
    IS_SD_TARGET="false"
    if [[ "$STORAGE_MEDIA" == "sd" || "$TARGET_ARCH" == "riscv32" || "${TARGET_BOARD:-}" == "espressif-esp32p4" || "$NODE_ROLE" == "snitchbench" || "$NODE_ROLE" == "lilsnitch" || -n "$CLI_STAGE_DIR" ]]; then
        IS_SD_TARGET="true"
    fi
}

_verify_refresh_node_vars

if [[ $EUID -eq 0 ]]; then
    install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$SNAP_DIR"
else
    mkdir -p "$SNAP_DIR"
    chmod 0750 "$SNAP_DIR" 2>/dev/null || true
fi

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

_verify_get_sd_mount_info() {
    local mp="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o SOURCE,FSTYPE,UUID "$mp" 2>/dev/null | head -n1 || true
    fi
}

_verify_staged_config_digest() {
    local hash_input=""
    local cfg_dir=""
    if [[ -n "$CLI_STAGE_DIR" && -d "${CLI_STAGE_DIR}/config" ]]; then
        cfg_dir="${CLI_STAGE_DIR}/config"
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$NODE_ENV" "$cfg_dir" <<'PY'
import hashlib, pathlib, sys
node_env = pathlib.Path(sys.argv[1])
cfg_dir = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
h = hashlib.sha256()
files = []
if cfg_dir and cfg_dir.is_dir():
    files = sorted(p for p in cfg_dir.rglob("*") if p.is_file())
elif node_env.is_file():
    files = [node_env]
for p in files:
    rel = p.relative_to(cfg_dir) if cfg_dir else p.name
    h.update(str(rel).encode("utf-8"))
    h.update(b"\0")
    h.update(p.read_bytes())
    h.update(b"\0")
print(h.hexdigest() if files else "")
PY
        return 0
    fi
    if [[ -n "$cfg_dir" ]]; then
        local f
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            hash_input+="${f}:"
            if command -v sha256sum >/dev/null 2>&1; then
                hash_input+="$(sha256sum "$f" | awk '{print $1}')"$'\n'
            elif command -v shasum >/dev/null 2>&1; then
                hash_input+="$(shasum -a 256 "$f" | awk '{print $1}')"$'\n'
            fi
        done < <(find "$cfg_dir" -type f | LC_ALL=C sort)
    elif [[ -f "$NODE_ENV" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$NODE_ENV" | awk '{print $1}'
            return 0
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$NODE_ENV" | awk '{print $1}'
            return 0
        fi
    fi
    if [[ -n "$hash_input" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
            printf '%s' "$hash_input" | sha256sum | awk '{print $1}'
        elif command -v shasum >/dev/null 2>&1; then
            printf '%s' "$hash_input" | shasum -a 256 | awk '{print $1}'
        fi
    fi
}

_verify_should_skip_host_ort() {
    if [[ "$IS_SD_TARGET" == "true" && -z "$CLI_TELEMETRY_JSON" && -z "$CLI_SERIAL_PORT" ]]; then
        if [[ "$(uname -m)" != riscv32* ]]; then
            return 0
        fi
    fi
    return 1
}

_verify_run_ort_stage() {
    local stage="$1"
    local -a cmd_args=(${ORT_ARGS[@]+"${ORT_ARGS[@]}"} --stage "$stage" --out-dir "$SNAP_DIR")
    if [[ -n "$CLI_STAGE_DIR" && -r "$NODE_ENV" ]]; then
        cmd_args+=(--config "$NODE_ENV")
    fi
    set +e
    bash "${SCRIPT_DIR}/ort-snapshot.sh" "${cmd_args[@]}"
    local rc=$?
    set -e
    if [[ $EUID -eq 0 ]]; then
        chown -R "${REAL_USER}:${REAL_GRP}" "$SNAP_DIR"
    fi
    if (( rc != 0 )); then
        log_fatal "ORT stage '${stage}' failed with exit code ${rc}."
    fi
    _verify_assert_ort_status "$stage" "$SNAP_DIR"
}

echo ">>> [STAGE 0] Checking Day-0 Pre-Forge Clean-Room ORT Snapshot..."
if _verify_should_skip_host_ort; then
    log_skip "Stage 0 (day0-pre-forge): host $(uname -m) staging SD target (${TARGET_BOARD:-espressif-esp32p4}) without --telemetry-json/--serial-port; skipped live host ORT probe"
elif [[ "$IS_SD_TARGET" != "true" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null && compgen -G "${SNAP_DIR}/*day0-pre-forge*.json" >/dev/null 2>&1; then
    log_skip "Resuming interrupted build; preserving existing Clean-Room Day-0 snapshot in ${SNAP_DIR}"
    _verify_assert_ort_status "day0-pre-forge" "$SNAP_DIR"
else
    _verify_run_ort_stage "day0-pre-forge"
fi

echo ""
echo ">>> [STAGE 1] Executing Convergence Pass 1..."
bash "${BRAKERRAK_ROOT}/forge.sh" ${PASS1_ARGS[@]+"${PASS1_ARGS[@]}"}

_verify_refresh_node_vars

PASS1_XFS_UUID=""
PASS1_CONFIG_DIGEST=""
PASS1_SD_MOUNT_INFO=""
if [[ "$IS_SD_TARGET" == "true" ]]; then
    log_skip "SD media target (${TARGET_BOARD:-espressif-esp32p4}, media=${STORAGE_MEDIA}); skipped XFS/NVMe UUID assertion"
    PASS1_CONFIG_DIGEST="$(_verify_staged_config_digest)"
    if [[ -z "$PASS1_CONFIG_DIGEST" ]]; then
        log_fatal "Stage 1 assertion FAILED: unable to resolve staged config digest for ${NODE_ENV}."
    fi
    if [[ -z "$CLI_STAGE_DIR" ]] && command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        PASS1_SD_MOUNT_INFO="$(_verify_get_sd_mount_info "$MOUNT_POINT")"
    fi
else
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        PASS1_XFS_UUID="$(_verify_get_xfs_uuid "$MOUNT_POINT")"
    fi
    if [[ -z "$PASS1_XFS_UUID" ]]; then
        log_fatal "Stage 1 assertion FAILED: unable to resolve XFS filesystem UUID on ${MOUNT_POINT}."
    fi
fi

PASS1_PG_SYSID=""
if [[ "$IS_SD_TARGET" != "true" && "$ENABLE_POSTGRES" == "true" ]]; then
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

if [[ "$IS_SD_TARGET" == "true" ]]; then
    PASS2_CONFIG_DIGEST="$(_verify_staged_config_digest)"
    if [[ -z "$PASS2_CONFIG_DIGEST" || "$PASS2_CONFIG_DIGEST" != "$PASS1_CONFIG_DIGEST" ]]; then
        log_fatal "Stage 2 idempotency assertion FAILED: staged config digest changed (Pass 1='${PASS1_CONFIG_DIGEST}', Pass 2='${PASS2_CONFIG_DIGEST:-missing}')."
    fi
    if [[ -n "$PASS1_SD_MOUNT_INFO" ]]; then
        PASS2_SD_MOUNT_INFO="$(_verify_get_sd_mount_info "$MOUNT_POINT")"
        if [[ "$PASS2_SD_MOUNT_INFO" != "$PASS1_SD_MOUNT_INFO" ]]; then
            log_fatal "Stage 2 idempotency assertion FAILED: SD mountpoint changed on ${MOUNT_POINT} (Pass 1='${PASS1_SD_MOUNT_INFO}', Pass 2='${PASS2_SD_MOUNT_INFO:-missing}')."
        fi
    fi
    log_ok "Stage 2 idempotency assertion passed (SD/riscv32): ${SKIP_MARKER_COUNT} [SKIP] marker(s), unchanged staged config digest (${PASS2_CONFIG_DIGEST:0:16}...)."
else
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
fi

echo ""
echo ">>> [STAGE 3] Capturing Day-1 Post-Forge CTD Provenance Snapshot..."
if _verify_should_skip_host_ort; then
    log_skip "Stage 3 (day1-post-forge): host $(uname -m) staging SD target (${TARGET_BOARD:-espressif-esp32p4}) without --telemetry-json/--serial-port; skipped live host ORT probe"
else
    _verify_run_ort_stage "day1-post-forge"
fi

echo ""
echo ">>> [PASS] Full BrakerRak Convergence & Idempotency Lifecycle Verified!"
