#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak PG18 Async I/O & PMU Cold-Cache Ablation Harness
# Path: brakerrak/benchmarks/run-iouring-showdown.sh
#
# Usage:
#   sudo ./benchmarks/run-iouring-showdown.sh [options]
#   sudo brakerrak bench showdown [--concurrencies 16,32,64] [--sync-zero-baseline] \
#       [--io-workers 3] [--warm-cache] [--analyze]
# ==============================================================================

if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

SCRIPT_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)"
BRAKERRAK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -r "${BRAKERRAK_ROOT}/scripts/lib-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${BRAKERRAK_ROOT}/scripts/lib-common.sh"
elif [[ -r "/usr/local/share/brakerrak/engine/scripts/lib-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "/usr/local/share/brakerrak/engine/scripts/lib-common.sh"
else
    _BRAK_LOG_TAG="BRAKERRAK"
    brak_log_init()  { _BRAK_LOG_TAG="${1:-BRAKERRAK}"; }
    log_brak()       { printf "\033[1;35m[%s]\033[0m %s\n" "${_BRAK_LOG_TAG}" "$1"; }
    log_step()       { printf "\n\033[1;36m=== [%s] %s ===\033[0m\n" "$(date +%H:%M:%S)" "$1"; }
    log_ok()         { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
    log_skip()       { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
    log_warn()       { printf "\033[1;33m[WARN]\033[0m %s\n" "$1" >&2; }
    log_fatal()      { printf "\033[1;31m[%s:FATAL]\033[0m %s\n" "${_BRAK_LOG_TAG}" "$1" >&2; exit 1; }
    brak_sanitize_locale() { :; }
    brak_require_arg() {
        local flag="${1:-}"
        local val="${2:-}"
        if [[ -z "$val" || "$val" == -* ]]; then
            log_fatal "Option '${flag}' requires an argument."
        fi
    }
    brak_resolve_user() {
        if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
            REAL_USER="$(id -un 2>/dev/null || echo "${USER:-root}")"
        else
            REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
        fi
        REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
        REAL_HOME=""
        if command -v getent >/dev/null 2>&1; then
            REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
        elif command -v dscl >/dev/null 2>&1; then
            REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
        fi
        if [[ -z "$REAL_HOME" ]]; then
            if [[ "$REAL_USER" == "root" ]]; then
                REAL_HOME="/root"
            elif [[ -d "/Users/${REAL_USER}" ]]; then
                REAL_HOME="/Users/${REAL_USER}"
            elif [[ -d "/home/${REAL_USER}" ]]; then
                REAL_HOME="/home/${REAL_USER}"
            else
                REAL_HOME="/root"
            fi
        fi
        export REAL_USER REAL_GRP REAL_HOME
    }
    brak_resolve_node_env() {
        if [[ -n "${BRAKERRAK_NODE_ENV:-}" ]]; then
            NODE_ENV="$BRAKERRAK_NODE_ENV"
        elif [[ -r "/etc/brakerrak/node.env" ]]; then
            NODE_ENV="/etc/brakerrak/node.env"
        else
            NODE_ENV="${REAL_HOME}/.brakerrak/node.env"
        fi
        export NODE_ENV
    }
    brak_load_kv_env() {
        local env_file="${1:-}"
        [[ -n "$env_file" && -r "$env_file" ]] || return 1
        local line key val
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            key="${line%%=*}"
            val="${line#*=}"
            key="${key%"${key##*[![:space:]]}"}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            val="${val#\"}"
            val="${val%\"}"
            val="${val#\'}"
            val="${val%\'}"
            case "$key" in
                NVME_DEV) [[ -z "${NVME_DEV:-}" ]] && NVME_DEV="$val" ;;
                NODE_ROLE) [[ -z "${NODE_ROLE:-}" ]] && NODE_ROLE="$val" ;;
                TARGET_HOSTNAME) [[ -z "${TARGET_HOSTNAME:-}" ]] && TARGET_HOSTNAME="$val" ;;
            esac
        done < "$env_file"
    }
fi

brak_log_init "BRAKERRAK:SHOWDOWN"
brak_sanitize_locale
brak_resolve_user
brak_resolve_node_env

# Load node topology metadata safely as data (no shell execution)
if [[ -r "${NODE_ENV:-}" ]]; then
    brak_load_kv_env "$NODE_ENV" --preserve-existing NVME_DEV NODE_ROLE TARGET_HOSTNAME || true
fi

detect_cpu_harts() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
    elif [[ -r /proc/cpuinfo ]]; then
        grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
    else
        echo 1
    fi
}

default_io_workers_for_harts() {
    local harts="$1"
    local workers
    if (( harts >= 4 )); then
        workers=$(( (harts * 3) / 4 ))
    elif (( harts > 1 )); then
        workers=$(( harts - 1 ))
    else
        workers=1
    fi
    (( workers < 1 )) && workers=1
    (( workers > 64 )) && workers=64
    printf '%s\n' "$workers"
}

usage() {
    cat <<'EOF'
Usage: sudo run-iouring-showdown.sh [options]

Executes the BrakerRak PostgreSQL 18 3-way Async I/O ablation matrix
(sync, worker, io_uring) x effective_io_concurrency with strict per-workload
cold-cache isolation, dynamic PMU probing, /proc/diskstats snapshots, and
full structured JSON artifact capture.

Options:
  --db <name>             Target PostgreSQL database (default: brakerrak)
  --table <name>          Torture table name (default: brakerrak_io_torture)
  --methods <csv>         Comma-separated io_method list (default: sync,worker,io_uring)
  --concurrencies <csv>   Comma-separated effective_io_concurrency values (default: 16,32,64)
  --sync-zero-baseline    Also run effective_io_concurrency=0 strict blocking baseline for sync
  --io-workers <N>        PostgreSQL 18 io_workers setting (default: scaled to hart count)
  --gather-workers <N>    max_parallel_workers_per_gather for Workload A (default: harts - 1)
  --nvme-dev <path>       Block device for /proc/diskstats (default: node.env NVME_DEV or auto)
  --snap-dir <dir>        Snapshot root dir (default: ~/.brakerrak/snapshots)
  --run-id <id>           Custom run identifier (default: showdown-<host>-<utc_ts>)
  --pg-user <user>        PostgreSQL superuser role (default: postgres)
  --pg-service <unit>     PostgreSQL systemd unit name (default: postgresql)
  --warm-cache            Run an isolated pg_prewarm warm-cache phase after cold-cache passes
  --analyze               Run analyze_showdown.py automatically upon completion
  -h, --help              Show this help message and exit
EOF
}

validate_pg_ident() {
    local label="$1"
    local ident="$2"
    if [[ ! "$ident" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_fatal "Invalid ${label} '${ident}': must match ^[a-zA-Z_][a-zA-Z0-9_]*$"
    fi
    if (( ${#ident} > 63 )); then
        log_fatal "Invalid ${label} '${ident}': exceeds PostgreSQL 63-byte identifier limit"
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

json_string_array() {
    local out="["
    local first="true"
    local item
    for item in "$@"; do
        if [[ "$first" == "true" ]]; then
            first="false"
        else
            out+=", "
        fi
        out+="\"$(json_escape "$item")\""
    done
    out+="]"
    printf '%s' "$out"
}

json_int_array() {
    local out="["
    local first="true"
    local item
    for item in "$@"; do
        if [[ "$first" == "true" ]]; then
            first="false"
        else
            out+=", "
        fi
        out+="${item}"
    done
    out+="]"
    printf '%s' "$out"
}

HARTS="$(detect_cpu_harts)"
DB_NAME="${DB_NAME:-brakerrak}"
TABLE_NAME="${TABLE_NAME:-brakerrak_io_torture}"
METHODS_CSV="${METHODS_CSV:-sync,worker,io_uring}"
CONCURRENCIES_CSV="${CONCURRENCIES_CSV:-16,32,64}"
SYNC_ZERO_BASELINE="${SYNC_ZERO_BASELINE:-false}"
IO_WORKERS="${IO_WORKERS:-$(default_io_workers_for_harts "$HARTS")}"
GATHER_WORKERS="${GATHER_WORKERS:-$(( HARTS > 1 ? HARTS - 1 : 0 ))}"
NVME_DEV="${NVME_DEV:-}"
SNAP_DIR="${SNAP_DIR:-${REAL_HOME}/.brakerrak/snapshots}"
RUN_ID="${RUN_ID:-}"
PG_USER="${PG_USER:-postgres}"
PG_SERVICE="${PG_SERVICE:-postgresql}"
WARM_CACHE="${WARM_CACHE:-false}"
AUTO_ANALYZE="${AUTO_ANALYZE:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --db)
            brak_require_arg "$1" "${2:-}"
            DB_NAME="$2"
            shift 2
            ;;
        --db=*)
            DB_NAME="${1#*=}"
            brak_require_arg "--db" "$DB_NAME"
            shift
            ;;
        --table)
            brak_require_arg "$1" "${2:-}"
            TABLE_NAME="$2"
            shift 2
            ;;
        --table=*)
            TABLE_NAME="${1#*=}"
            brak_require_arg "--table" "$TABLE_NAME"
            shift
            ;;
        --methods)
            brak_require_arg "$1" "${2:-}"
            METHODS_CSV="$2"
            shift 2
            ;;
        --methods=*)
            METHODS_CSV="${1#*=}"
            brak_require_arg "--methods" "$METHODS_CSV"
            shift
            ;;
        --concurrencies)
            brak_require_arg "$1" "${2:-}"
            CONCURRENCIES_CSV="$2"
            shift 2
            ;;
        --concurrencies=*)
            CONCURRENCIES_CSV="${1#*=}"
            brak_require_arg "--concurrencies" "$CONCURRENCIES_CSV"
            shift
            ;;
        --sync-zero-baseline)
            SYNC_ZERO_BASELINE="true"
            shift
            ;;
        --no-sync-zero-baseline)
            SYNC_ZERO_BASELINE="false"
            shift
            ;;
        --io-workers)
            brak_require_arg "$1" "${2:-}"
            IO_WORKERS="$2"
            shift 2
            ;;
        --io-workers=*)
            IO_WORKERS="${1#*=}"
            brak_require_arg "--io-workers" "$IO_WORKERS"
            shift
            ;;
        --gather-workers)
            brak_require_arg "$1" "${2:-}"
            GATHER_WORKERS="$2"
            shift 2
            ;;
        --gather-workers=*)
            GATHER_WORKERS="${1#*=}"
            brak_require_arg "--gather-workers" "$GATHER_WORKERS"
            shift
            ;;
        --nvme-dev)
            brak_require_arg "$1" "${2:-}"
            NVME_DEV="$2"
            shift 2
            ;;
        --nvme-dev=*)
            NVME_DEV="${1#*=}"
            brak_require_arg "--nvme-dev" "$NVME_DEV"
            shift
            ;;
        --snap-dir)
            brak_require_arg "$1" "${2:-}"
            SNAP_DIR="$2"
            shift 2
            ;;
        --snap-dir=*)
            SNAP_DIR="${1#*=}"
            brak_require_arg "--snap-dir" "$SNAP_DIR"
            shift
            ;;
        --run-id)
            brak_require_arg "$1" "${2:-}"
            RUN_ID="$2"
            shift 2
            ;;
        --run-id=*)
            RUN_ID="${1#*=}"
            brak_require_arg "--run-id" "$RUN_ID"
            shift
            ;;
        --pg-user)
            brak_require_arg "$1" "${2:-}"
            PG_USER="$2"
            shift 2
            ;;
        --pg-user=*)
            PG_USER="${1#*=}"
            brak_require_arg "--pg-user" "$PG_USER"
            shift
            ;;
        --pg-service)
            brak_require_arg "$1" "${2:-}"
            PG_SERVICE="$2"
            shift 2
            ;;
        --pg-service=*)
            PG_SERVICE="${1#*=}"
            brak_require_arg "--pg-service" "$PG_SERVICE"
            shift
            ;;
        --warm-cache)
            WARM_CACHE="true"
            shift
            ;;
        --analyze)
            AUTO_ANALYZE="true"
            shift
            ;;
        *)
            log_fatal "Unknown argument: $1 (run with --help for usage)"
            ;;
    esac
done

validate_pg_ident "DB_NAME" "$DB_NAME"
validate_pg_ident "TABLE_NAME" "$TABLE_NAME"
validate_pg_ident "PG_USER" "$PG_USER"

if [[ ! "$PG_SERVICE" =~ ^[a-zA-Z0-9@._-]+$ ]]; then
    log_fatal "Invalid PG_SERVICE '${PG_SERVICE}'"
fi
if [[ ! "$IO_WORKERS" =~ ^[1-9][0-9]*$ ]] || (( IO_WORKERS > 64 )); then
    log_fatal "Invalid --io-workers '${IO_WORKERS}': must be an integer between 1 and 64"
fi
if [[ ! "$GATHER_WORKERS" =~ ^[0-9]+$ ]]; then
    log_fatal "Invalid --gather-workers '${GATHER_WORKERS}': must be a non-negative integer"
fi

IFS=',' read -r -a METHODS <<< "$METHODS_CSV"
if (( ${#METHODS[@]} == 0 )); then
    log_fatal "--methods must specify at least one io_method (sync, worker, io_uring)"
fi
for m in "${METHODS[@]}"; do
    case "$m" in
        sync|worker|io_uring) ;;
        *) log_fatal "Invalid io_method '${m}': expected sync, worker, or io_uring" ;;
    esac
done

IFS=',' read -r -a CONCURRENCIES <<< "$CONCURRENCIES_CSV"
if (( ${#CONCURRENCIES[@]} == 0 )); then
    log_fatal "--concurrencies must specify at least one non-negative integer"
fi
for c in "${CONCURRENCIES[@]}"; do
    if [[ ! "$c" =~ ^[0-9]+$ ]]; then
        log_fatal "Invalid effective_io_concurrency '${c}': must be a non-negative integer"
    fi
done

NODE_HOST="$(hostname -s 2>/dev/null || hostname)"
if [[ -z "$RUN_ID" ]]; then
    RUN_ID="showdown-${NODE_HOST}-$(date -u +%Y%m%dT%H%M%SZ)"
fi
if [[ ! "$RUN_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    log_fatal "Invalid --run-id '${RUN_ID}': must match ^[a-zA-Z0-9._-]+$"
fi

# Require root privileges upfront for systemctl restart, drop_caches, and perf stat -a
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_fatal "run-iouring-showdown.sh requires root privileges (needed for systemctl, /proc/sys/vm/drop_caches, and perf stat -a). Re-run with sudo."
fi

for req_bin in systemctl psql sudo; do
    if ! command -v "$req_bin" >/dev/null 2>&1; then
        log_fatal "Required command '${req_bin}' not found in PATH."
    fi
done

run_psql() {
    local target_db="$1"
    shift
    sudo -u "$PG_USER" psql -X -U "$PG_USER" -d "$target_db" -v ON_ERROR_STOP=1 "$@"
}

wait_for_postgres() {
    local attempts=60
    local i
    for (( i=1; i<=attempts; i++ )); do
        if command -v pg_isready >/dev/null 2>&1; then
            if sudo -u "$PG_USER" pg_isready -q 2>/dev/null; then
                return 0
            fi
        else
            if run_psql postgres -tAc "SELECT 1;" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 0.5
    done
    log_fatal "PostgreSQL did not become ready within 30s after start/restart."
}

if ! systemctl is-active --quiet "$PG_SERVICE"; then
    log_fatal "PostgreSQL service '${PG_SERVICE}' is not active. Start PostgreSQL before running showdown."
fi
wait_for_postgres

# Verify database and seeded torture table exist before touching any PostgreSQL GUCs
if ! run_psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" | grep -qx '1'; then
    log_fatal "Database '${DB_NAME}' does not exist. Run benchmarks/seed-io-torture.sh first."
fi
if ! run_psql "$DB_NAME" -tAc "SELECT to_regclass('\"${TABLE_NAME}\"') IS NOT NULL;" | grep -qx 't'; then
    log_fatal "Table '${DB_NAME}.${TABLE_NAME}' does not exist. Run benchmarks/seed-io-torture.sh first."
fi

PG_SERVER_VERSION="$(run_psql "$DB_NAME" -tAc "SHOW server_version;")"
PG_DATA_DIR="$(run_psql "$DB_NAME" -tAc "SHOW data_directory;")"

# Resolve target NVMe/block device for /proc/diskstats snapshots
if [[ -z "$NVME_DEV" ]]; then
    PG_MOUNT_SRC="$(findmnt -rn -o SOURCE --target "$PG_DATA_DIR" 2>/dev/null || true)"
    if [[ -n "$PG_MOUNT_SRC" && -b "$PG_MOUNT_SRC" ]] && command -v lsblk >/dev/null 2>&1; then
        PK_DEV="$(lsblk -ndo PKNAME "$PG_MOUNT_SRC" 2>/dev/null | head -n1 || true)"
        if [[ -n "$PK_DEV" && -b "/dev/${PK_DEV}" ]]; then
            NVME_DEV="/dev/${PK_DEV}"
        else
            NVME_DEV="$PG_MOUNT_SRC"
        fi
    fi
fi
NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
NVME_SHORT="$(basename "$NVME_DEV")"
if [[ -r /proc/diskstats ]] && ! awk -v dev="$NVME_SHORT" '$3 == dev { found=1; exit } END { exit !found }' /proc/diskstats; then
    log_warn "Device '${NVME_SHORT}' not found in /proc/diskstats; diskstats snapshots may be empty."
fi

# ==============================================================================
# Record Initial PostgreSQL GUCs & Install Guaranteed Restoration Trap
# ==============================================================================
query_auto_guc() {
    local guc_name="$1"
    run_psql "$DB_NAME" -tAc "
        SELECT setting
        FROM pg_file_settings
        WHERE name = '${guc_name}'
          AND sourcefile LIKE '%postgresql.auto.conf'
          AND applied = true
        ORDER BY seqno DESC
        LIMIT 1;
    " 2>/dev/null || true
}

INIT_IO_METHOD="$(run_psql "$DB_NAME" -tAc "SHOW io_method;")"
INIT_IO_WORKERS="$(run_psql "$DB_NAME" -tAc "SHOW io_workers;")"
INIT_EIC="$(run_psql "$DB_NAME" -tAc "SHOW effective_io_concurrency;")"
INIT_TRACK_IO_TIMING="$(run_psql "$DB_NAME" -tAc "SHOW track_io_timing;")"

AUTO_IO_METHOD="$(query_auto_guc "io_method")"
AUTO_IO_WORKERS="$(query_auto_guc "io_workers")"
AUTO_EIC="$(query_auto_guc "effective_io_concurrency")"
AUTO_TRACK_IO_TIMING="$(query_auto_guc "track_io_timing")"

GUC_MUTATED="false"
GUC_RESTORED="false"

restore_one_guc() {
    local guc_name="$1"
    local auto_val="$2"
    if [[ -n "$auto_val" ]]; then
        local escaped_val="${auto_val//\'/\'\'}"
        run_psql postgres -q -c "ALTER SYSTEM SET ${guc_name} = '${escaped_val}';" || true
    else
        run_psql postgres -q -c "ALTER SYSTEM RESET ${guc_name};" || true
    fi
}

restore_pg_gucs() {
    local orig_rc=$?
    if [[ "$GUC_MUTATED" != "true" || "$GUC_RESTORED" == "true" ]]; then
        return "$orig_rc"
    fi
    GUC_RESTORED="true"
    set +e

    log_step "Restoring initial PostgreSQL GUCs in postgresql.auto.conf"
    if ! systemctl is-active --quiet "$PG_SERVICE"; then
        systemctl start "$PG_SERVICE" || true
    fi
    wait_for_postgres || true

    restore_one_guc "io_method" "$AUTO_IO_METHOD"
    restore_one_guc "io_workers" "$AUTO_IO_WORKERS"
    restore_one_guc "effective_io_concurrency" "$AUTO_EIC"
    restore_one_guc "track_io_timing" "$AUTO_TRACK_IO_TIMING"

    systemctl restart "$PG_SERVICE" || true
    wait_for_postgres || true
    log_ok "Restored PostgreSQL GUCs (io_method=${INIT_IO_METHOD}, io_workers=${INIT_IO_WORKERS}, effective_io_concurrency=${INIT_EIC}, track_io_timing=${INIT_TRACK_IO_TIMING})"
    return "$orig_rc"
}

handle_signal() {
    local sig="$1"
    local code="$2"
    log_warn "Caught SIG${sig}; restoring PostgreSQL GUCs before exiting..."
    restore_pg_gucs || true
    exit "$code"
}

trap 'restore_pg_gucs' EXIT
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

# ==============================================================================
# Dynamic Hardware/Software PMU Event Probing via `perf list`
# ==============================================================================
PERF_AVAILABLE="false"
PERF_PROBED_EVENTS=()
PERF_EVENTS_CSV=""

probe_perf_events() {
    if ! command -v perf >/dev/null 2>&1; then
        log_warn "perf binary not found; PMU counters will be omitted from pass artifacts."
        return 0
    fi

    local perf_list_out
    perf_list_out="$(perf list --no-desc 2>/dev/null || perf list 2>/dev/null || true)"
    if [[ -z "$perf_list_out" ]]; then
        log_warn "perf list returned empty output; PMU counters will be omitted."
        return 0
    fi

    local candidates=(
        "cycles"
        "instructions"
        "context-switches"
        "cpu-migrations"
        "L1-dcache-load-misses"
        "LLC-load-misses"
        "dTLB-load-misses"
    )
    local ev
    for ev in "${candidates[@]}"; do
        if grep -qiE "(^|[[:space:],])${ev}([[:space:],]|$)" <<< "$perf_list_out"; then
            if perf stat -a -j -e "$ev" -- true >/dev/null 2>&1; then
                PERF_PROBED_EVENTS+=("$ev")
            else
                log_warn "PMU event '${ev}' listed but rejected by kernel perf_event_open; omitting."
            fi
        else
            log_warn "PMU event '${ev}' unavailable in perf list on this kernel; omitting."
        fi
    done

    if (( ${#PERF_PROBED_EVENTS[@]} > 0 )); then
        PERF_EVENTS_CSV="$(IFS=','; printf '%s' "${PERF_PROBED_EVENTS[*]}")"
        if perf stat -a -j -e "$PERF_EVENTS_CSV" -- true >/dev/null 2>&1; then
            PERF_AVAILABLE="true"
            log_ok "Probed PMU events: ${PERF_EVENTS_CSV}"
        else
            log_warn "Combined perf stat -a -j probe failed; falling back to no-PMU execution."
            PERF_PROBED_EVENTS=()
            PERF_EVENTS_CSV=""
        fi
    else
        log_warn "No supported perf stat -a -j PMU events available; running without perf."
    fi
}

probe_perf_events

# ==============================================================================
# Prepare Artifact Output Directory & Run Metadata
# ==============================================================================
BENCH_ROOT="${SNAP_DIR}/benchmarks"
RUN_DIR="${BENCH_ROOT}/${RUN_ID}"
PASSES_DIR="${RUN_DIR}/passes"
install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$SNAP_DIR" "$BENCH_ROOT" "$RUN_DIR" "$PASSES_DIR"

DT_MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || uname -m)"
CAPTURED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CAPTURED_EPOCH="$(date -u +%s)"

cat > "${RUN_DIR}/metadata.json" <<EOF
{
  "schema_version": "drewv-ctd-benchmark/v1.0",
  "run_id": "$(json_escape "$RUN_ID")",
  "node_id": "$(json_escape "$NODE_HOST")",
  "pillar": "runner",
  "component": "benchmark:pg18-iouring-showdown",
  "captured_at_utc": "${CAPTURED_UTC}",
  "captured_at_epoch": ${CAPTURED_EPOCH},
  "architecture": "$(json_escape "$(uname -m)")",
  "kernel_release": "$(json_escape "$(uname -r)")",
  "device_tree_model": "$(json_escape "$DT_MODEL")",
  "cpu_harts_count": ${HARTS},
  "pg_server_version": "$(json_escape "$PG_SERVER_VERSION")",
  "db_name": "$(json_escape "$DB_NAME")",
  "table_name": "$(json_escape "$TABLE_NAME")",
  "nvme_device": "$(json_escape "$NVME_DEV")",
  "nvme_short": "$(json_escape "$NVME_SHORT")",
  "io_workers": ${IO_WORKERS},
  "gather_workers": ${GATHER_WORKERS},
  "methods": $(json_string_array "${METHODS[@]}"),
  "concurrencies": $(json_int_array "${CONCURRENCIES[@]}"),
  "sync_zero_baseline": ${SYNC_ZERO_BASELINE},
  "warm_cache_enabled": ${WARM_CACHE},
  "perf_events": $(json_string_array ${PERF_PROBED_EVENTS[@]+"${PERF_PROBED_EVENTS[@]}"}),
  "initial_gucs": {
    "io_method": "$(json_escape "$INIT_IO_METHOD")",
    "io_workers": "$(json_escape "$INIT_IO_WORKERS")",
    "effective_io_concurrency": "$(json_escape "$INIT_EIC")",
    "track_io_timing": "$(json_escape "$INIT_TRACK_IO_TIMING")"
  }
}
EOF

# ==============================================================================
# Core Protocol Helpers (GUC Configuration, Cold-Cache Isolation, Artifact Capture)
# ==============================================================================
configure_pg_gucs() {
    local method="$1"
    local concurrency="$2"
    GUC_MUTATED="true"
    run_psql postgres -q -c "ALTER SYSTEM SET io_method = '${method}';"
    run_psql postgres -q -c "ALTER SYSTEM SET io_workers = ${IO_WORKERS};"
    run_psql postgres -q -c "ALTER SYSTEM SET effective_io_concurrency = ${concurrency};"
    run_psql postgres -q -c "ALTER SYSTEM SET track_io_timing = on;"
}

assert_pg_gucs_active() {
    local expected_method="$1"
    local expected_conc="$2"
    local pending active_method active_conc active_timing

    pending="$(run_psql "$DB_NAME" -tAc "SELECT pending_restart FROM pg_settings WHERE name = 'io_method';")"
    active_method="$(run_psql "$DB_NAME" -tAc "SHOW io_method;")"
    active_conc="$(run_psql "$DB_NAME" -tAc "SHOW effective_io_concurrency;")"
    active_timing="$(run_psql "$DB_NAME" -tAc "SHOW track_io_timing;")"

    if [[ "$pending" != "f" ]]; then
        log_fatal "PostgreSQL io_method still has pending_restart='${pending}' after restart."
    fi
    if [[ "$active_method" != "$expected_method" ]]; then
        log_fatal "Expected active io_method='${expected_method}', got '${active_method}'."
    fi
    if [[ "$active_conc" != "$expected_conc" ]]; then
        log_fatal "Expected effective_io_concurrency='${expected_conc}', got '${active_conc}'."
    fi
    if [[ "$active_timing" != "on" ]]; then
        log_fatal "Expected track_io_timing='on', got '${active_timing}'."
    fi
}

reset_pg_stats() {
    run_psql "$DB_NAME" -q -c "SELECT pg_stat_reset(); SELECT pg_stat_reset_shared('io');"
}

# Mandatory 5-step Cold-Cache Isolation Protocol executed before EACH individual workload
cold_cache_isolate() {
    local expected_method="$1"
    local expected_conc="$2"

    # 1. Stop PostgreSQL cleanly to release shared buffers
    systemctl stop "$PG_SERVICE"
    # 2. Flush dirty pages and drop Linux kernel page, dentry, and inode caches
    sync && echo 3 > /proc/sys/vm/drop_caches
    # 3. Start PostgreSQL and wait until accepting connections
    systemctl start "$PG_SERVICE"
    wait_for_postgres
    # 4. Assert postmaster GUC state took effect cleanly with no pending restart
    assert_pg_gucs_active "$expected_method" "$expected_conc"
    # 5. Reset database and shared I/O statistics before firing the single workload
    reset_pg_stats
}

capture_diskstats() {
    local out_file="$1"
    if [[ -r /proc/diskstats ]]; then
        awk -v dev="$NVME_SHORT" '$3 == dev { print; exit }' /proc/diskstats > "$out_file" || true
    else
        : > "$out_file"
    fi
}

execute_workload_pass() {
    local cache_mode="$1"
    local method="$2"
    local concurrency="$3"
    local workload="$4"
    local workload_label="$5"
    local session_sql="$6"
    local explain_sql="$7"

    local pass_slug="${cache_mode}__${method}__eic${concurrency}__${workload}"
    local pass_dir="${PASSES_DIR}/${pass_slug}"
    install -d -m 0750 "$pass_dir"

    local explain_file="${pass_dir}/explain.json"
    local pg_stat_io_file="${pass_dir}/pg_stat_io.json"
    local perf_file="${pass_dir}/perf_stat.json"
    local disk_before="${pass_dir}/diskstats_before.txt"
    local disk_after="${pass_dir}/diskstats_after.txt"
    local meta_file="${pass_dir}/pass_meta.json"

    log_brak "[${cache_mode}] io_method=${method} | eic=${concurrency} | ${workload_label}"

    local started_utc finished_utc start_ns end_ns wall_ms
    started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    start_ns="$(date +%s%N 2>/dev/null || echo $(( $(date +%s) * 1000000000 )))"

    capture_diskstats "$disk_before"

    if [[ "$PERF_AVAILABLE" == "true" ]]; then
        perf stat -a -j -o "$perf_file" -e "$PERF_EVENTS_CSV" -- \
            sudo -u "$PG_USER" psql -X -U "$PG_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -t -A \
            -c "$session_sql" \
            -c "$explain_sql" \
            > "$explain_file"
    else
        : > "$perf_file"
        run_psql "$DB_NAME" -q -t -A \
            -c "$session_sql" \
            -c "$explain_sql" \
            > "$explain_file"
    fi

    capture_diskstats "$disk_after"

    end_ns="$(date +%s%N 2>/dev/null || echo $(( $(date +%s) * 1000000000 )))"
    finished_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$start_ns" =~ ^[0-9]+$ && "$end_ns" =~ ^[0-9]+$ ]]; then
        wall_ms=$(( (end_ns - start_ns) / 1000000 ))
    else
        wall_ms=0
    fi

    run_psql "$DB_NAME" -q -t -A -c "
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
        FROM (
            SELECT *
            FROM pg_stat_io
            WHERE reads > 0
            ORDER BY reads DESC
        ) t;
    " > "$pg_stat_io_file"

    cat > "$meta_file" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "node_id": "$(json_escape "$NODE_HOST")",
  "cache_mode": "$(json_escape "$cache_mode")",
  "io_method": "$(json_escape "$method")",
  "effective_io_concurrency": ${concurrency},
  "io_workers": ${IO_WORKERS},
  "gather_workers": ${GATHER_WORKERS},
  "workload": "$(json_escape "$workload")",
  "workload_label": "$(json_escape "$workload_label")",
  "nvme_short": "$(json_escape "$NVME_SHORT")",
  "started_at_utc": "${started_utc}",
  "finished_at_utc": "${finished_utc}",
  "wall_duration_ms": ${wall_ms}
}
EOF

    log_ok "Captured ${pass_slug} (${wall_ms} ms wall)"
}

WORKLOAD_A_SESSION="SET max_parallel_workers_per_gather = ${GATHER_WORKERS};"
WORKLOAD_A_EXPLAIN="EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL, FORMAT JSON)
SELECT sensor_code, count(*), avg(reading)
FROM \"${TABLE_NAME}\"
GROUP BY sensor_code;"

WORKLOAD_B_SESSION="SET enable_seqscan = off; SET max_parallel_workers_per_gather = 0;"
WORKLOAD_B_EXPLAIN="EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL, FORMAT JSON)
SELECT avg(reading), sum(id)
FROM \"${TABLE_NAME}\"
WHERE scatter_key BETWEEN 10000 AND 45000;"

METHOD_CONCS=()
build_method_concurrencies() {
    local method="$1"
    METHOD_CONCS=()
    local has_zero="false"
    local c
    for c in "${CONCURRENCIES[@]}"; do
        [[ "$c" == "0" ]] && has_zero="true"
    done
    if [[ "$method" == "sync" && "$SYNC_ZERO_BASELINE" == "true" && "$has_zero" != "true" ]]; then
        METHOD_CONCS+=("0")
    fi
    for c in "${CONCURRENCIES[@]}"; do
        METHOD_CONCS+=("$c")
    done
}

echo "======================================================================"
echo " BrakerRak // PostgreSQL ${PG_SERVER_VERSION} Async I/O Ablation Showdown"
echo " Node    : ${NODE_HOST} | Silicon: ${DT_MODEL} (${HARTS} Harts)"
echo " Target  : ${DB_NAME}.${TABLE_NAME} | NVMe: ${NVME_DEV} (${NVME_SHORT})"
echo " Matrix  : methods=[${METHODS_CSV}] x eic=[${CONCURRENCIES_CSV}] | io_workers=${IO_WORKERS}"
echo " Output  : ${RUN_DIR}"
echo "======================================================================"

# ==============================================================================
# Phase 1: Cold-Cache Ablation Passes (Isolated Cold-Cache Reset Before EACH Workload)
# ==============================================================================
log_step "Phase 1: Cold-Cache Ablation Matrix"
for METHOD in "${METHODS[@]}"; do
    build_method_concurrencies "$METHOD"
    for CONC in "${METHOD_CONCS[@]}"; do
        log_step "Pass Configuration: io_method=${METHOD} | effective_io_concurrency=${CONC} | io_workers=${IO_WORKERS}"
        configure_pg_gucs "$METHOD" "$CONC"

        # Mandatory Cold-Cache Isolation BEFORE Workload A
        cold_cache_isolate "$METHOD" "$CONC"
        execute_workload_pass \
            "cold" "$METHOD" "$CONC" "seq_scan" \
            "Workload A: Parallel Sequential Scan (${GATHER_WORKERS} Gather Workers)" \
            "$WORKLOAD_A_SESSION" "$WORKLOAD_A_EXPLAIN"

        # Mandatory Cold-Cache Isolation BEFORE Workload B (strictly separate from Workload A)
        cold_cache_isolate "$METHOD" "$CONC"
        execute_workload_pass \
            "cold" "$METHOD" "$CONC" "bitmap_heap_scan" \
            "Workload B: Scattered Bitmap Heap Scan (eic=${CONC})" \
            "$WORKLOAD_B_SESSION" "$WORKLOAD_B_EXPLAIN"
    done
done

# ==============================================================================
# Phase 2 (Optional): Isolated Warm-Cache Passes via pg_prewarm
# ==============================================================================
prewarm_torture_relation() {
    run_psql "$DB_NAME" -q -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm;"
    run_psql "$DB_NAME" -q -c "SELECT pg_prewarm('\"${TABLE_NAME}\"'::regclass, 'buffer');"
    local idx_name
    idx_name="$(run_psql "$DB_NAME" -tAc "
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename = '${TABLE_NAME}'
        ORDER BY indexname
        LIMIT 1;
    " || true)"
    if [[ -n "$idx_name" && "$idx_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        run_psql "$DB_NAME" -q -c "SELECT pg_prewarm('\"${idx_name}\"'::regclass, 'buffer');"
    fi
}

if [[ "$WARM_CACHE" == "true" ]]; then
    log_step "Phase 2: Isolated Warm-Cache Comparison Passes (pg_prewarm)"
    for METHOD in "${METHODS[@]}"; do
        build_method_concurrencies "$METHOD"
        for CONC in "${METHOD_CONCS[@]}"; do
            configure_pg_gucs "$METHOD" "$CONC"
            systemctl restart "$PG_SERVICE"
            wait_for_postgres
            assert_pg_gucs_active "$METHOD" "$CONC"

            prewarm_torture_relation
            reset_pg_stats
            execute_workload_pass \
                "warm" "$METHOD" "$CONC" "seq_scan" \
                "Workload A (Warm): Parallel Sequential Scan (${GATHER_WORKERS} Gather Workers)" \
                "$WORKLOAD_A_SESSION" "$WORKLOAD_A_EXPLAIN"

            prewarm_torture_relation
            reset_pg_stats
            execute_workload_pass \
                "warm" "$METHOD" "$CONC" "bitmap_heap_scan" \
                "Workload B (Warm): Scattered Bitmap Heap Scan (eic=${CONC})" \
                "$WORKLOAD_B_SESSION" "$WORKLOAD_B_EXPLAIN"
        done
    done
fi

# Restore hand-off ownership for unprivileged PyArrow analysis
chown -R "${REAL_USER}:${REAL_GRP}" "$RUN_DIR"

# Restore initial PostgreSQL GUCs explicitly before optional analysis
restore_pg_gucs

log_ok "Showdown capture complete -> ${RUN_DIR}"
if [[ "$AUTO_ANALYZE" == "true" ]]; then
    ANALYZER="${SCRIPT_DIR}/analyze_showdown.py"
    if [[ -f "$ANALYZER" ]]; then
        if command -v uv >/dev/null 2>&1 && [[ -f "${BRAKERRAK_ROOT}/pyproject.toml" ]]; then
            sudo -u "$REAL_USER" uv run --project "$BRAKERRAK_ROOT" "$ANALYZER" "$RUN_DIR"
        else
            sudo -u "$REAL_USER" python3 "$ANALYZER" "$RUN_DIR"
        fi
    fi
else
    log_brak "Aggregate telemetry with:"
    printf "  uv run --project %s %s %s\n" \
        "$BRAKERRAK_ROOT" "${SCRIPT_DIR}/analyze_showdown.py" "$RUN_DIR"
fi
