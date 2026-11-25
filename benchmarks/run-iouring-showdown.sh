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
cold-cache isolation, multi-iteration repeatability, dynamic PMU probing,
/proc/diskstats snapshots, and full structured JSON artifact capture.

Options:
  --db <name>             Target PostgreSQL database (default: brakerrak)
  --table <name>          Torture table name (default: brakerrak_io_torture)
  --methods <csv>         Comma-separated io_method list (default: sync,worker,io_uring)
  --concurrencies <csv>   Comma-separated effective_io_concurrency values (default: 16,32,64)
  --sync-zero-baseline    Also run effective_io_concurrency=0 strict blocking baseline for sync
  --io-workers <N>        PostgreSQL 18 io_workers setting (default: scaled to hart count)
  --gather-workers <N>    max_parallel_workers_per_gather for Workload A (default: harts - 1)
  --iterations <N>        Number of full matrix iterations (default: 3)
  --randomize-order       Deterministically shuffle pass order per iteration
  --seed <int>            Integer PRNG seed for --randomize-order (default: UTC epoch if omitted)
  --cooldown-sec <int>    Cooldown sleep in seconds between passes (default: 0)
  --require-governor <g>  Require active CPU scaling governor (e.g., performance)
  --with-direct-io        Set debug_io_direct = 'data' for passes and restore on teardown
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

json_num_or_null() {
    local val="${1:-}"
    if [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$val"
    else
        printf 'null'
    fi
}

HARTS="$(detect_cpu_harts)"
DB_NAME="${DB_NAME:-brakerrak}"
TABLE_NAME="${TABLE_NAME:-brakerrak_io_torture}"
METHODS_CSV="${METHODS_CSV:-sync,worker,io_uring}"
CONCURRENCIES_CSV="${CONCURRENCIES_CSV:-16,32,64}"
SYNC_ZERO_BASELINE="${SYNC_ZERO_BASELINE:-false}"
IO_WORKERS="${IO_WORKERS:-$(default_io_workers_for_harts "$HARTS")}"
GATHER_WORKERS="${GATHER_WORKERS:-$(( HARTS > 1 ? HARTS - 1 : 0 ))}"
ITERATIONS="${ITERATIONS:-3}"
RANDOMIZE_ORDER="${RANDOMIZE_ORDER:-false}"
PRNG_SEED="${PRNG_SEED:-}"
COOLDOWN_SEC="${COOLDOWN_SEC:-0}"
REQUIRE_GOVERNOR="${REQUIRE_GOVERNOR:-}"
WITH_DIRECT_IO="${WITH_DIRECT_IO:-false}"
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
        --iterations)
            brak_require_arg "$1" "${2:-}"
            ITERATIONS="$2"
            shift 2
            ;;
        --iterations=*)
            ITERATIONS="${1#*=}"
            brak_require_arg "--iterations" "$ITERATIONS"
            shift
            ;;
        --randomize-order)
            RANDOMIZE_ORDER="true"
            shift
            ;;
        --no-randomize-order)
            RANDOMIZE_ORDER="false"
            shift
            ;;
        --seed)
            if [[ -z "${2:-}" ]]; then
                log_fatal "Option '--seed' requires an integer argument."
            fi
            PRNG_SEED="$2"
            shift 2
            ;;
        --seed=*)
            PRNG_SEED="${1#*=}"
            if [[ -z "$PRNG_SEED" ]]; then
                log_fatal "Option '--seed' requires an integer argument."
            fi
            shift
            ;;
        --cooldown-sec)
            brak_require_arg "$1" "${2:-}"
            COOLDOWN_SEC="$2"
            shift 2
            ;;
        --cooldown-sec=*)
            COOLDOWN_SEC="${1#*=}"
            brak_require_arg "--cooldown-sec" "$COOLDOWN_SEC"
            shift
            ;;
        --require-governor)
            brak_require_arg "$1" "${2:-}"
            REQUIRE_GOVERNOR="$2"
            shift 2
            ;;
        --require-governor=*)
            REQUIRE_GOVERNOR="${1#*=}"
            brak_require_arg "--require-governor" "$REQUIRE_GOVERNOR"
            shift
            ;;
        --with-direct-io)
            WITH_DIRECT_IO="true"
            shift
            ;;
        --no-with-direct-io)
            WITH_DIRECT_IO="false"
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
if [[ ! "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
    log_fatal "Invalid --iterations '${ITERATIONS}': must be a positive integer"
fi
if [[ ! "$COOLDOWN_SEC" =~ ^[0-9]+$ ]]; then
    log_fatal "Invalid --cooldown-sec '${COOLDOWN_SEC}': must be a non-negative integer"
fi
if [[ -n "$REQUIRE_GOVERNOR" && ! "$REQUIRE_GOVERNOR" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_fatal "Invalid --require-governor '${REQUIRE_GOVERNOR}': must match ^[a-zA-Z0-9_-]+$"
fi
for bool_var in SYNC_ZERO_BASELINE WARM_CACHE AUTO_ANALYZE WITH_DIRECT_IO RANDOMIZE_ORDER; do
    bool_val="${!bool_var}"
    if [[ ! "$bool_val" =~ ^(true|false)$ ]]; then
        log_fatal "Invalid ${bool_var}='${bool_val}': must be 'true' or 'false'"
    fi
done
if [[ -n "$PRNG_SEED" && ! "$PRNG_SEED" =~ ^-?[0-9]+$ ]]; then
    log_fatal "Invalid --seed '${PRNG_SEED}': must be an integer"
fi
if [[ "$RANDOMIZE_ORDER" == "true" && -z "$PRNG_SEED" ]]; then
    PRNG_SEED="$(date -u +%s)"
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

wait_for_postgres_ready() {
    local attempts="${1:-60}"
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
    return 1
}

wait_for_postgres() {
    if ! wait_for_postgres_ready 60; then
        log_fatal "PostgreSQL did not become ready within 30s after start/restart."
    fi
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
INIT_DEBUG_IO_DIRECT="$(run_psql "$DB_NAME" -tAc "SHOW debug_io_direct;" 2>/dev/null || echo "")"

AUTO_IO_METHOD="$(query_auto_guc "io_method")"
AUTO_IO_WORKERS="$(query_auto_guc "io_workers")"
AUTO_EIC="$(query_auto_guc "effective_io_concurrency")"
AUTO_TRACK_IO_TIMING="$(query_auto_guc "track_io_timing")"
AUTO_DEBUG_IO_DIRECT="$(query_auto_guc "debug_io_direct")"

AUTO_CONF_PATH="${PG_DATA_DIR}/postgresql.auto.conf"
AUTO_CONF_EXISTED="false"
AUTO_CONF_BACKUP=""
if [[ -f "$AUTO_CONF_PATH" ]]; then
    AUTO_CONF_EXISTED="true"
    if declare -F brak_mktemp >/dev/null 2>&1; then
        brak_mktemp -v AUTO_CONF_BACKUP "${TMPDIR:-/tmp}/brak-pg-auto-conf.XXXXXX"
    else
        AUTO_CONF_BACKUP="$(mktemp "${TMPDIR:-/tmp}/brak-pg-auto-conf.XXXXXX")"
    fi
    cp -p "$AUTO_CONF_PATH" "$AUTO_CONF_BACKUP"
fi

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

restore_auto_conf_from_backup() {
    if [[ "$AUTO_CONF_EXISTED" == "true" && -n "$AUTO_CONF_BACKUP" && -f "$AUTO_CONF_BACKUP" ]]; then
        local tmp_restore="${AUTO_CONF_PATH}.brakerrak.restore.$$"
        cp "$AUTO_CONF_BACKUP" "$tmp_restore"
        chown "${PG_USER}:${PG_USER}" "$tmp_restore" 2>/dev/null || chown "$PG_USER" "$tmp_restore" 2>/dev/null || true
        chmod 0600 "$tmp_restore"
        mv -f "$tmp_restore" "$AUTO_CONF_PATH"
    elif [[ "$AUTO_CONF_EXISTED" == "false" && -f "$AUTO_CONF_PATH" ]]; then
        rm -f "$AUTO_CONF_PATH"
    fi
}

restore_pg_gucs() {
    local orig_rc=$?
    if [[ "$GUC_MUTATED" != "true" || "$GUC_RESTORED" == "true" ]]; then
        if [[ -n "$AUTO_CONF_BACKUP" && -f "$AUTO_CONF_BACKUP" ]]; then
            rm -f "$AUTO_CONF_BACKUP" || true
        fi
        return "$orig_rc"
    fi
    GUC_RESTORED="true"
    set +e

    log_step "Restoring initial PostgreSQL GUCs in postgresql.auto.conf"
    if ! systemctl is-active --quiet "$PG_SERVICE"; then
        systemctl start "$PG_SERVICE" || true
    fi

    local restored_via_backup="false"
    if wait_for_postgres_ready 30; then
        restore_one_guc "io_method" "$AUTO_IO_METHOD"
        restore_one_guc "io_workers" "$AUTO_IO_WORKERS"
        restore_one_guc "effective_io_concurrency" "$AUTO_EIC"
        restore_one_guc "track_io_timing" "$AUTO_TRACK_IO_TIMING"
        if [[ "$WITH_DIRECT_IO" == "true" ]]; then
            restore_one_guc "debug_io_direct" "$AUTO_DEBUG_IO_DIRECT"
        fi
        systemctl restart "$PG_SERVICE" || true
        if ! wait_for_postgres_ready 30; then
            log_warn "PostgreSQL restart failed after ALTER SYSTEM restore; falling back to postgresql.auto.conf backup."
            systemctl stop "$PG_SERVICE" || true
            restore_auto_conf_from_backup
            systemctl start "$PG_SERVICE" || true
            wait_for_postgres_ready 30 || true
            restored_via_backup="true"
        fi
    else
        log_warn "PostgreSQL unreachable; restoring ${AUTO_CONF_PATH} directly from pre-run backup."
        systemctl stop "$PG_SERVICE" || true
        restore_auto_conf_from_backup
        systemctl start "$PG_SERVICE" || true
        wait_for_postgres_ready 30 || true
        restored_via_backup="true"
    fi

    if [[ -n "$AUTO_CONF_BACKUP" && -f "$AUTO_CONF_BACKUP" ]]; then
        rm -f "$AUTO_CONF_BACKUP" || true
    fi
    if [[ "$restored_via_backup" == "true" ]]; then
        log_ok "Restored PostgreSQL configuration from pre-run postgresql.auto.conf snapshot"
    else
        log_ok "Restored PostgreSQL GUCs (io_method=${INIT_IO_METHOD}, io_workers=${INIT_IO_WORKERS}, effective_io_concurrency=${INIT_EIC}, track_io_timing=${INIT_TRACK_IO_TIMING}, debug_io_direct=${INIT_DEBUG_IO_DIRECT:-off})"
    fi
    return "$orig_rc"
}

handle_signal() {
    local sig="$1"
    local code="$2"
    log_warn "Caught SIG${sig}; restoring PostgreSQL GUCs before exiting..."
    restore_pg_gucs || true
    exit "$code"
}

if declare -F brak_register_exit_hook >/dev/null 2>&1; then
    brak_register_exit_hook restore_pg_gucs
else
    trap 'restore_pg_gucs' EXIT
    trap 'handle_signal INT 130' INT
    trap 'handle_signal TERM 143' TERM
fi

# ==============================================================================
# System, Thermal, Storage & Governor Provenance Probes
# ==============================================================================
detect_scaling_governor() {
    local gov_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    if [[ -r "$gov_file" ]]; then
        local gov
        gov="$(tr -d '[:space:]' < "$gov_file" 2>/dev/null || true)"
        printf '%s' "${gov:-unavailable}"
    else
        printf 'unavailable'
    fi
}

detect_cpu_mhz() {
    local freq_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
    if [[ -r "$freq_file" ]]; then
        local khz
        khz="$(tr -d '[:space:]' < "$freq_file" 2>/dev/null || true)"
        if [[ "$khz" =~ ^[0-9]+$ ]]; then
            awk -v k="$khz" 'BEGIN { printf "%.2f", k / 1000.0 }'
            return 0
        fi
    fi
    if [[ -r /proc/cpuinfo ]]; then
        local mhz
        mhz="$(awk -F: '/^cpu MHz[[:space:]]*:/ { gsub(/[[:space:]]/, "", $2); if ($2 ~ /^[0-9]+(\.[0-9]+)?$/) { printf "%.2f", $2; exit } }' /proc/cpuinfo 2>/dev/null || true)"
        if [[ -n "$mhz" ]]; then
            printf '%s' "$mhz"
            return 0
        fi
    fi
    if command -v lscpu >/dev/null 2>&1; then
        local lscpu_mhz
        lscpu_mhz="$(lscpu 2>/dev/null | awk -F: '/CPU (max )?MHz:/ { gsub(/[^0-9.]/, "", $2); if ($2 != "") { printf "%.2f", $2; exit } }' || true)"
        if [[ -n "$lscpu_mhz" ]]; then
            printf '%s' "$lscpu_mhz"
            return 0
        fi
    fi
    printf 'null'
}

detect_soc_temp_c() {
    local tz ztype ztemp
    for tz in /sys/class/thermal/thermal_zone*; do
        [[ -d "$tz" ]] || continue
        if [[ -r "${tz}/type" && -r "${tz}/temp" ]]; then
            ztype="$(tr -d '[:space:]' < "${tz}/type" 2>/dev/null || true)"
            ztemp="$(tr -d '[:space:]' < "${tz}/temp" 2>/dev/null || true)"
            if [[ "$ztemp" =~ ^-?[0-9]+$ ]] && grep -qiE '(soc|cpu|package|core|k10temp|starfive|eswin|die)' <<< "$ztype"; then
                awk -v t="$ztemp" 'BEGIN { printf "%.2f", t / 1000.0 }'
                return 0
            fi
        fi
    done
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        ztemp="$(tr -d '[:space:]' < /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)"
        if [[ "$ztemp" =~ ^-?[0-9]+$ ]]; then
            awk -v t="$ztemp" 'BEGIN { printf "%.2f", t / 1000.0 }'
            return 0
        fi
    fi
    printf 'null'
}

detect_nvme_temp_c() {
    local hw hname htemp
    for hw in /sys/block/"${NVME_SHORT}"/device/hwmon/hwmon* /sys/block/"${NVME_SHORT}"/device/device/hwmon/hwmon*; do
        if [[ -r "${hw}/temp1_input" ]]; then
            htemp="$(tr -d '[:space:]' < "${hw}/temp1_input" 2>/dev/null || true)"
            if [[ "$htemp" =~ ^-?[0-9]+$ ]]; then
                awk -v t="$htemp" 'BEGIN { printf "%.2f", t / 1000.0 }'
                return 0
            fi
        fi
    done
    for hw in /sys/class/hwmon/hwmon*; do
        [[ -r "${hw}/name" && -r "${hw}/temp1_input" ]] || continue
        hname="$(tr -d '[:space:]' < "${hw}/name" 2>/dev/null || true)"
        if [[ "$hname" == "nvme" ]]; then
            htemp="$(tr -d '[:space:]' < "${hw}/temp1_input" 2>/dev/null || true)"
            if [[ "$htemp" =~ ^-?[0-9]+$ ]]; then
                awk -v t="$htemp" 'BEGIN { printf "%.2f", t / 1000.0 }'
                return 0
            fi
        fi
    done
    printf 'null'
}

detect_loadavg() {
    if [[ -r /proc/loadavg ]]; then
        awk '{ printf "%s %s %s", $1, $2, $3 }' /proc/loadavg 2>/dev/null || printf 'unavailable'
    else
        printf 'unavailable'
    fi
}

detect_nvme_logical_block_size() {
    local lbs_file="/sys/block/${NVME_SHORT}/queue/logical_block_size"
    if [[ -r "$lbs_file" ]]; then
        local lbs
        lbs="$(tr -d '[:space:]' < "$lbs_file" 2>/dev/null || true)"
        if [[ "$lbs" =~ ^[0-9]+$ ]]; then
            printf '%s' "$lbs"
            return 0
        fi
    fi
    printf 'null'
}

detect_pg_mount_field() {
    local field="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -o "$field" --target "$PG_DATA_DIR" 2>/dev/null | head -n1 || true
    fi
}

SCALING_GOVERNOR="$(detect_scaling_governor)"
if [[ -n "$REQUIRE_GOVERNOR" ]]; then
    if [[ "$SCALING_GOVERNOR" == "unavailable" || "$SCALING_GOVERNOR" == "unknown" ]]; then
        log_warn "CPU cpufreq scaling_governor is unavailable on this host; cannot verify --require-governor=${REQUIRE_GOVERNOR}."
    elif [[ "$SCALING_GOVERNOR" != "$REQUIRE_GOVERNOR" ]]; then
        log_fatal "Active CPU scaling_governor is '${SCALING_GOVERNOR}', expected '${REQUIRE_GOVERNOR}' (--require-governor)."
    else
        log_ok "CPU scaling_governor='${SCALING_GOVERNOR}' matches requirement."
    fi
elif [[ "$SCALING_GOVERNOR" != "unavailable" && "$SCALING_GOVERNOR" != "unknown" && "$SCALING_GOVERNOR" != "performance" ]]; then
    log_warn "Active CPU scaling_governor is '${SCALING_GOVERNOR}' (recommended: 'performance' for low-jitter benchmarking)."
fi

PRE_CPU_MHZ="$(detect_cpu_mhz)"
PRE_SOC_TEMP_C="$(detect_soc_temp_c)"
PRE_NVME_TEMP_C="$(detect_nvme_temp_c)"
PRE_LOADAVG="$(detect_loadavg)"
NVME_LOGICAL_BLOCK_SIZE="$(detect_nvme_logical_block_size)"
PG_DATA_FSTYPE="$(detect_pg_mount_field FSTYPE)"
PG_DATA_FSTYPE="${PG_DATA_FSTYPE:-unknown}"
XFS_MOUNT_OPTIONS="$(detect_pg_mount_field OPTIONS)"
XFS_MOUNT_OPTIONS="${XFS_MOUNT_OPTIONS:-unknown}"

PG_SHARED_BUFFERS="$(run_psql "$DB_NAME" -tAc "SHOW shared_buffers;" 2>/dev/null || echo "unknown")"
PG_SHARED_BUFFERS_BYTES="$(run_psql "$DB_NAME" -tAc "SELECT pg_size_bytes(current_setting('shared_buffers'));" 2>/dev/null || echo "")"
PG_HUGE_PAGES_STATUS="$(run_psql "$DB_NAME" -tAc "SHOW huge_pages_status;" 2>/dev/null || run_psql "$DB_NAME" -tAc "SHOW huge_pages;" 2>/dev/null || echo "unknown")"
PG_IO_COMBINE_LIMIT="$(run_psql "$DB_NAME" -tAc "SHOW io_combine_limit;" 2>/dev/null || echo "unknown")"
PG_IO_MAX_CONCURRENCY="$(run_psql "$DB_NAME" -tAc "SHOW io_max_concurrency;" 2>/dev/null || echo "unknown")"
TOTAL_REL_BYTES="$(run_psql "$DB_NAME" -tAc "SELECT pg_total_relation_size('\"${TABLE_NAME}\"'::regclass);" 2>/dev/null || echo "")"

PREWARM_FIT_SHARED_BUFFERS="null"
if [[ "$TOTAL_REL_BYTES" =~ ^[0-9]+$ && "$PG_SHARED_BUFFERS_BYTES" =~ ^[0-9]+$ ]]; then
    if (( TOTAL_REL_BYTES <= PG_SHARED_BUFFERS_BYTES )); then
        PREWARM_FIT_SHARED_BUFFERS="true"
    else
        PREWARM_FIT_SHARED_BUFFERS="false"
        if [[ "$WARM_CACHE" == "true" ]]; then
            log_warn "Relation '${TABLE_NAME}' (${TOTAL_REL_BYTES} B) exceeds shared_buffers (${PG_SHARED_BUFFERS_BYTES} B); warm-cache passes cannot fit entirely in shared_buffers."
        fi
    fi
fi

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
# Deterministic Iteration Plan Construction
# ==============================================================================
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

shuffle_lines_deterministic() {
    local seed="$1"
    local salt="$2"
    shift 2
    local items=("$@")
    local n="${#items[@]}"
    if (( n <= 1 )); then
        printf '%s\n' "${items[@]}"
        return 0
    fi
    local abs_seed="$seed"
    if (( abs_seed < 0 )); then
        abs_seed=$(( -abs_seed ))
    fi
    local state=$(( (abs_seed + salt * 2654435761 + 1013904223) & 0x7fffffff ))
    (( state == 0 )) && state=123456789
    local k
    for (( k=0; k<4; k++ )); do
        state=$(( (state * 1103515245 + 12345) & 0x7fffffff ))
    done
    local i j tmp
    for (( i=n-1; i>0; i-- )); do
        state=$(( (state * 1103515245 + 12345) & 0x7fffffff ))
        j=$(( (state >> 8) % (i + 1) ))
        tmp="${items[i]}"
        items[i]="${items[j]}"
        items[j]="$tmp"
    done
    printf '%s\n' "${items[@]}"
}

BASE_MATRIX_ITEMS=()
for METHOD in "${METHODS[@]}"; do
    build_method_concurrencies "$METHOD"
    for CONC in "${METHOD_CONCS[@]}"; do
        BASE_MATRIX_ITEMS+=("${METHOD}|${CONC}|seq_scan")
        BASE_MATRIX_ITEMS+=("${METHOD}|${CONC}|bitmap_heap_scan")
    done
done

ITERATION_ORDERS_JSON="{"
first_order_entry="true"
for (( iter=1; iter<=ITERATIONS; iter++ )); do
    iter_tag="$(printf 'iter_%02d' "$iter")"
    iter_items=()
    if [[ "$RANDOMIZE_ORDER" == "true" ]]; then
        while IFS= read -r shuffled_line; do
            [[ -n "$shuffled_line" ]] && iter_items+=("$shuffled_line")
        done < <(shuffle_lines_deterministic "$PRNG_SEED" "$iter" "${BASE_MATRIX_ITEMS[@]}")
    else
        iter_items=("${BASE_MATRIX_ITEMS[@]}")
    fi
    iter_slugs=()
    for entry in "${iter_items[@]}"; do
        IFS='|' read -r e_method e_conc e_wl <<< "$entry"
        iter_slugs+=("cold__${e_method}__eic${e_conc}__${e_wl}")
    done
    if [[ "$first_order_entry" == "true" ]]; then
        first_order_entry="false"
    else
        ITERATION_ORDERS_JSON+=","
    fi
    ITERATION_ORDERS_JSON+="\"${iter_tag}\":$(json_string_array "${iter_slugs[@]}")"

    if [[ "$WARM_CACHE" == "true" ]]; then
        warm_items=()
        if [[ "$RANDOMIZE_ORDER" == "true" ]]; then
            while IFS= read -r shuffled_line; do
                [[ -n "$shuffled_line" ]] && warm_items+=("$shuffled_line")
            done < <(shuffle_lines_deterministic "$PRNG_SEED" "$(( 1000 + iter ))" "${BASE_MATRIX_ITEMS[@]}")
        else
            warm_items=("${BASE_MATRIX_ITEMS[@]}")
        fi
        warm_slugs=()
        for entry in "${warm_items[@]}"; do
            IFS='|' read -r e_method e_conc e_wl <<< "$entry"
            warm_slugs+=("warm__${e_method}__eic${e_conc}__${e_wl}")
        done
        ITERATION_ORDERS_JSON+=",\"warm_${iter_tag}\":$(json_string_array "${warm_slugs[@]}")"
    fi
done
ITERATION_ORDERS_JSON+="}"

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
  "iterations": ${ITERATIONS},
  "randomize_order": ${RANDOMIZE_ORDER},
  "prng_seed": $(json_num_or_null "${PRNG_SEED}"),
  "cooldown_sec": ${COOLDOWN_SEC},
  "require_governor": "$(json_escape "$REQUIRE_GOVERNOR")",
  "with_direct_io": ${WITH_DIRECT_IO},
  "scaling_governor": "$(json_escape "$SCALING_GOVERNOR")",
  "cpu_mhz": $(json_num_or_null "$PRE_CPU_MHZ"),
  "soc_temp_c": $(json_num_or_null "$PRE_SOC_TEMP_C"),
  "nvme_temp_c": $(json_num_or_null "$PRE_NVME_TEMP_C"),
  "loadavg": "$(json_escape "$PRE_LOADAVG")",
  "shared_buffers": "$(json_escape "$PG_SHARED_BUFFERS")",
  "shared_buffers_bytes": $(json_num_or_null "$PG_SHARED_BUFFERS_BYTES"),
  "total_relation_bytes": $(json_num_or_null "$TOTAL_REL_BYTES"),
  "prewarm_fit_shared_buffers": ${PREWARM_FIT_SHARED_BUFFERS},
  "huge_pages_status": "$(json_escape "$PG_HUGE_PAGES_STATUS")",
  "io_combine_limit": "$(json_escape "$PG_IO_COMBINE_LIMIT")",
  "io_max_concurrency": "$(json_escape "$PG_IO_MAX_CONCURRENCY")",
  "nvme_logical_block_size": $(json_num_or_null "$NVME_LOGICAL_BLOCK_SIZE"),
  "pg_data_fstype": "$(json_escape "$PG_DATA_FSTYPE")",
  "xfs_mount_options": "$(json_escape "$XFS_MOUNT_OPTIONS")",
  "methods": $(json_string_array "${METHODS[@]}"),
  "concurrencies": $(json_int_array "${CONCURRENCIES[@]}"),
  "sync_zero_baseline": ${SYNC_ZERO_BASELINE},
  "warm_cache_enabled": ${WARM_CACHE},
  "iteration_orders": ${ITERATION_ORDERS_JSON},
  "perf_events": $(json_string_array ${PERF_PROBED_EVENTS[@]+"${PERF_PROBED_EVENTS[@]}"}),
  "initial_gucs": {
    "io_method": "$(json_escape "$INIT_IO_METHOD")",
    "io_workers": "$(json_escape "$INIT_IO_WORKERS")",
    "effective_io_concurrency": "$(json_escape "$INIT_EIC")",
    "track_io_timing": "$(json_escape "$INIT_TRACK_IO_TIMING")",
    "debug_io_direct": "$(json_escape "$INIT_DEBUG_IO_DIRECT")"
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
    if [[ "$WITH_DIRECT_IO" == "true" ]]; then
        run_psql postgres -q -c "ALTER SYSTEM SET debug_io_direct = 'data';"
    fi
}

assert_pg_gucs_active() {
    local expected_method="$1"
    local expected_conc="$2"
    local pending_method pending_workers active_method active_workers active_conc active_timing

    pending_method="$(run_psql "$DB_NAME" -tAc "SELECT pending_restart FROM pg_settings WHERE name = 'io_method';")"
    pending_workers="$(run_psql "$DB_NAME" -tAc "SELECT pending_restart FROM pg_settings WHERE name = 'io_workers';")"
    active_method="$(run_psql "$DB_NAME" -tAc "SHOW io_method;")"
    active_workers="$(run_psql "$DB_NAME" -tAc "SHOW io_workers;")"
    active_conc="$(run_psql "$DB_NAME" -tAc "SHOW effective_io_concurrency;")"
    active_timing="$(run_psql "$DB_NAME" -tAc "SHOW track_io_timing;")"

    if [[ "$pending_method" != "f" ]]; then
        log_fatal "PostgreSQL io_method still has pending_restart='${pending_method}' after restart."
    fi
    if [[ "$pending_workers" != "f" ]]; then
        log_fatal "PostgreSQL io_workers still has pending_restart='${pending_workers}' after restart."
    fi
    if [[ "$active_method" != "$expected_method" ]]; then
        log_fatal "Expected active io_method='${expected_method}', got '${active_method}'."
    fi
    if [[ "$active_workers" != "$IO_WORKERS" ]]; then
        log_fatal "Expected active io_workers='${IO_WORKERS}', got '${active_workers}'."
    fi
    if [[ "$active_conc" != "$expected_conc" ]]; then
        log_fatal "Expected effective_io_concurrency='${expected_conc}', got '${active_conc}'."
    fi
    if [[ "$active_timing" != "on" ]]; then
        log_fatal "Expected track_io_timing='on', got '${active_timing}'."
    fi

    if [[ "$WITH_DIRECT_IO" == "true" ]]; then
        local pending_direct active_direct
        pending_direct="$(run_psql "$DB_NAME" -tAc "SELECT pending_restart FROM pg_settings WHERE name = 'debug_io_direct';")"
        active_direct="$(run_psql "$DB_NAME" -tAc "SHOW debug_io_direct;")"
        if [[ "$pending_direct" != "f" ]]; then
            log_fatal "PostgreSQL debug_io_direct still has pending_restart='${pending_direct}' after restart."
        fi
        if [[ "$active_direct" != "data" ]]; then
            log_fatal "Expected active debug_io_direct='data', got '${active_direct}'."
        fi
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

PASS_EXECUTED_COUNT=0

execute_workload_pass() {
    local iteration="$1"
    local pass_order_idx="$2"
    local cache_mode="$3"
    local method="$4"
    local concurrency="$5"
    local workload="$6"
    local workload_label="$7"
    local session_sql="$8"
    local explain_sql="$9"

    if (( PASS_EXECUTED_COUNT > 0 && COOLDOWN_SEC > 0 )); then
        log_brak "Cooldown sleep ${COOLDOWN_SEC}s before next pass..."
        sleep "$COOLDOWN_SEC"
    fi

    local iter_tag
    iter_tag="$(printf 'iter_%02d' "$iteration")"
    local pass_slug="${cache_mode}__${method}__eic${concurrency}__${workload}"
    local pass_dir="${PASSES_DIR}/${iter_tag}/${pass_slug}"
    install -d -m 0750 "$pass_dir"

    local explain_file="${pass_dir}/explain.json"
    local pg_stat_io_file="${pass_dir}/pg_stat_io.json"
    local perf_file="${pass_dir}/perf_stat.json"
    local disk_before="${pass_dir}/diskstats_before.txt"
    local disk_after="${pass_dir}/diskstats_after.txt"
    local meta_file="${pass_dir}/pass_meta.json"

    local pass_io_direct
    pass_io_direct="$(run_psql "$DB_NAME" -tAc "SHOW debug_io_direct;" 2>/dev/null || echo "")"
    [[ -z "$pass_io_direct" ]] && pass_io_direct="off"

    log_brak "[${iter_tag}][${cache_mode}] io_method=${method} | eic=${concurrency} | io_direct=${pass_io_direct} | ${workload_label}"

    local pre_soc_temp pre_nvme_temp pre_cpu_mhz
    pre_soc_temp="$(detect_soc_temp_c)"
    pre_nvme_temp="$(detect_nvme_temp_c)"
    pre_cpu_mhz="$(detect_cpu_mhz)"

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
        wall_ms="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { d = (e - s) / 1000000.0; if (d < 0) d = 0; printf "%.3f", d }')"
    else
        wall_ms="0"
    fi

    local post_soc_temp post_nvme_temp post_cpu_mhz
    post_soc_temp="$(detect_soc_temp_c)"
    post_nvme_temp="$(detect_nvme_temp_c)"
    post_cpu_mhz="$(detect_cpu_mhz)"

    run_psql "$DB_NAME" -q -t -A -c "
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
        FROM (
            SELECT *
            FROM pg_stat_io
            WHERE reads > 0 OR hits > 0 OR writes > 0 OR extends > 0 OR evictions > 0
            ORDER BY reads DESC, hits DESC
        ) t;
    " > "$pg_stat_io_file"

    cat > "$meta_file" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "node_id": "$(json_escape "$NODE_HOST")",
  "iteration": ${iteration},
  "pass_order_index": ${pass_order_idx},
  "cache_mode": "$(json_escape "$cache_mode")",
  "io_method": "$(json_escape "$method")",
  "io_direct": "$(json_escape "$pass_io_direct")",
  "with_direct_io": ${WITH_DIRECT_IO},
  "effective_io_concurrency": ${concurrency},
  "io_workers": ${IO_WORKERS},
  "gather_workers": ${GATHER_WORKERS},
  "workload": "$(json_escape "$workload")",
  "workload_label": "$(json_escape "$workload_label")",
  "nvme_short": "$(json_escape "$NVME_SHORT")",
  "prewarm_fit_shared_buffers": ${PREWARM_FIT_SHARED_BUFFERS},
  "pre_soc_temp_c": $(json_num_or_null "$pre_soc_temp"),
  "post_soc_temp_c": $(json_num_or_null "$post_soc_temp"),
  "pre_nvme_temp_c": $(json_num_or_null "$pre_nvme_temp"),
  "post_nvme_temp_c": $(json_num_or_null "$post_nvme_temp"),
  "pre_cpu_mhz": $(json_num_or_null "$pre_cpu_mhz"),
  "post_cpu_mhz": $(json_num_or_null "$post_cpu_mhz"),
  "started_at_utc": "${started_utc}",
  "finished_at_utc": "${finished_utc}",
  "wall_duration_ms": ${wall_ms}
}
EOF

    PASS_EXECUTED_COUNT=$(( PASS_EXECUTED_COUNT + 1 ))
    log_ok "Captured ${iter_tag}/${pass_slug} (${wall_ms} ms wall)"
}

WORKLOAD_A_SESSION="SET max_parallel_workers_per_gather = ${GATHER_WORKERS};"
WORKLOAD_A_EXPLAIN="EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL, FORMAT JSON)
SELECT sensor_code, count(*), avg(reading)
FROM \"${TABLE_NAME}\"
GROUP BY sensor_code;"

WORKLOAD_B_SESSION="SET enable_seqscan = off; SET enable_indexscan = off; SET enable_indexonlyscan = off; SET max_parallel_workers_per_gather = 0;"
WORKLOAD_B_EXPLAIN="EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL, FORMAT JSON)
SELECT avg(reading), sum(id)
FROM \"${TABLE_NAME}\"
WHERE scatter_key BETWEEN 10000 AND 45000;"

echo "======================================================================"
echo " BrakerRak // PostgreSQL ${PG_SERVER_VERSION} Async I/O Ablation Showdown"
echo " Node    : ${NODE_HOST} | Silicon: ${DT_MODEL} (${HARTS} Harts)"
echo " Target  : ${DB_NAME}.${TABLE_NAME} | NVMe: ${NVME_DEV} (${NVME_SHORT})"
echo " Matrix  : methods=[${METHODS_CSV}] x eic=[${CONCURRENCIES_CSV}] | io_workers=${IO_WORKERS}"
echo " Rigor   : iterations=${ITERATIONS} | randomize=${RANDOMIZE_ORDER} (seed=${PRNG_SEED:-none}) | cooldown=${COOLDOWN_SEC}s | direct_io=${WITH_DIRECT_IO}"
echo " Output  : ${RUN_DIR}"
echo "======================================================================"

# ==============================================================================
# Phase 1: Cold-Cache Ablation Passes (Isolated Cold-Cache Reset Before EACH Workload)
# ==============================================================================
log_step "Phase 1: Cold-Cache Ablation Matrix (${ITERATIONS} iterations)"
for (( ITER=1; ITER<=ITERATIONS; ITER++ )); do
    log_step "Cold-Cache Iteration ${ITER}/${ITERATIONS}"
    COLD_ITER_ITEMS=()
    if [[ "$RANDOMIZE_ORDER" == "true" ]]; then
        while IFS= read -r shuffled_line; do
            [[ -n "$shuffled_line" ]] && COLD_ITER_ITEMS+=("$shuffled_line")
        done < <(shuffle_lines_deterministic "$PRNG_SEED" "$ITER" "${BASE_MATRIX_ITEMS[@]}")
    else
        COLD_ITER_ITEMS=("${BASE_MATRIX_ITEMS[@]}")
    fi

    PASS_IDX=0
    for ENTRY in "${COLD_ITER_ITEMS[@]}"; do
        IFS='|' read -r METHOD CONC WORKLOAD <<< "$ENTRY"
        log_step "Pass [${ITER}/${ITERATIONS} #${PASS_IDX}]: io_method=${METHOD} | eic=${CONC} | workload=${WORKLOAD} | io_workers=${IO_WORKERS}"
        configure_pg_gucs "$METHOD" "$CONC"
        cold_cache_isolate "$METHOD" "$CONC"

        if [[ "$WORKLOAD" == "seq_scan" ]]; then
            execute_workload_pass \
                "$ITER" "$PASS_IDX" "cold" "$METHOD" "$CONC" "seq_scan" \
                "Workload A: Parallel Sequential Scan (${GATHER_WORKERS} Gather Workers)" \
                "$WORKLOAD_A_SESSION" "$WORKLOAD_A_EXPLAIN"
        else
            execute_workload_pass \
                "$ITER" "$PASS_IDX" "cold" "$METHOD" "$CONC" "bitmap_heap_scan" \
                "Workload B: Scattered Bitmap Heap Scan (eic=${CONC})" \
                "$WORKLOAD_B_SESSION" "$WORKLOAD_B_EXPLAIN"
        fi
        PASS_IDX=$(( PASS_IDX + 1 ))
    done
done

# ==============================================================================
# Phase 2 (Optional): Isolated Warm-Cache Passes via pg_prewarm
# ==============================================================================
prewarm_torture_relation() {
    local sb_bytes rel_bytes
    sb_bytes="$(run_psql "$DB_NAME" -tAc "SELECT pg_size_bytes(current_setting('shared_buffers'));" 2>/dev/null || echo "")"
    rel_bytes="$(run_psql "$DB_NAME" -tAc "SELECT pg_total_relation_size('\"${TABLE_NAME}\"'::regclass);" 2>/dev/null || echo "")"
    if [[ "$rel_bytes" =~ ^[0-9]+$ && "$sb_bytes" =~ ^[0-9]+$ ]]; then
        if (( rel_bytes > sb_bytes )); then
            PREWARM_FIT_SHARED_BUFFERS="false"
            log_warn "Total relation+index size (${rel_bytes} B) exceeds shared_buffers (${sb_bytes} B); warm-cache pass will partially spill."
        else
            PREWARM_FIT_SHARED_BUFFERS="true"
        fi
    fi

    run_psql "$DB_NAME" -q -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm;"
    run_psql "$DB_NAME" -q -c "SELECT pg_prewarm('\"${TABLE_NAME}\"'::regclass, 'buffer');"

    local idx_list idx_name
    idx_list="$(run_psql "$DB_NAME" -tAc "
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename = '${TABLE_NAME}'
        ORDER BY indexname;
    " || true)"
    while IFS= read -r idx_name; do
        [[ -z "$idx_name" ]] && continue
        if [[ "$idx_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            run_psql "$DB_NAME" -q -c "SELECT pg_prewarm('\"${idx_name}\"'::regclass, 'buffer');"
        else
            log_warn "Skipping prewarm for index with unexpected name '${idx_name}'."
        fi
    done <<< "$idx_list"
}

warm_cache_isolate() {
    local expected_method="$1"
    local expected_conc="$2"

    # 1. Drop OS page cache before warm setup to clear any residual OS cache
    systemctl stop "$PG_SERVICE"
    sync && echo 3 > /proc/sys/vm/drop_caches
    systemctl start "$PG_SERVICE"
    wait_for_postgres
    assert_pg_gucs_active "$expected_method" "$expected_conc"

    # 2. Prewarm heap + all indexes strictly into PostgreSQL shared_buffers
    prewarm_torture_relation

    # 3. Drop OS page cache again so any shared_buffers miss cannot hit OS page cache
    sync && echo 3 > /proc/sys/vm/drop_caches
    reset_pg_stats
}

if [[ "$WARM_CACHE" == "true" ]]; then
    log_step "Phase 2: Isolated Warm-Cache Comparison Passes (pg_prewarm, ${ITERATIONS} iterations)"
    for (( ITER=1; ITER<=ITERATIONS; ITER++ )); do
        log_step "Warm-Cache Iteration ${ITER}/${ITERATIONS}"
        WARM_ITER_ITEMS=()
        if [[ "$RANDOMIZE_ORDER" == "true" ]]; then
            while IFS= read -r shuffled_line; do
                [[ -n "$shuffled_line" ]] && WARM_ITER_ITEMS+=("$shuffled_line")
            done < <(shuffle_lines_deterministic "$PRNG_SEED" "$(( 1000 + ITER ))" "${BASE_MATRIX_ITEMS[@]}")
        else
            WARM_ITER_ITEMS=("${BASE_MATRIX_ITEMS[@]}")
        fi

        PASS_IDX=0
        for ENTRY in "${WARM_ITER_ITEMS[@]}"; do
            IFS='|' read -r METHOD CONC WORKLOAD <<< "$ENTRY"
            configure_pg_gucs "$METHOD" "$CONC"
            warm_cache_isolate "$METHOD" "$CONC"

            if [[ "$WORKLOAD" == "seq_scan" ]]; then
                execute_workload_pass \
                    "$ITER" "$PASS_IDX" "warm" "$METHOD" "$CONC" "seq_scan" \
                    "Workload A (Warm): Parallel Sequential Scan (${GATHER_WORKERS} Gather Workers)" \
                    "$WORKLOAD_A_SESSION" "$WORKLOAD_A_EXPLAIN"
            else
                execute_workload_pass \
                    "$ITER" "$PASS_IDX" "warm" "$METHOD" "$CONC" "bitmap_heap_scan" \
                    "Workload B (Warm): Scattered Bitmap Heap Scan (eic=${CONC})" \
                    "$WORKLOAD_B_SESSION" "$WORKLOAD_B_EXPLAIN"
            fi
            PASS_IDX=$(( PASS_IDX + 1 ))
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
        if [[ -x "${BRAKERRAK_ROOT}/.venv/bin/python" ]]; then
            sudo -u "$REAL_USER" "${BRAKERRAK_ROOT}/.venv/bin/python" "$ANALYZER" "$RUN_DIR"
        elif command -v uv >/dev/null 2>&1 && [[ -f "${BRAKERRAK_ROOT}/pyproject.toml" ]] && [[ -d "${BRAKERRAK_ROOT}/.venv" || -n "${UV_PROJECT_ENVIRONMENT:-}" ]]; then
            sudo -u "$REAL_USER" uv run --project "$BRAKERRAK_ROOT" --no-sync "$ANALYZER" "$RUN_DIR"
        elif command -v python3 >/dev/null 2>&1 && sudo -u "$REAL_USER" python3 -c "import pyarrow" >/dev/null 2>&1; then
            sudo -u "$REAL_USER" python3 "$ANALYZER" "$RUN_DIR"
        else
            log_warn "No usable Python/pyarrow runtime found for --analyze. Remediate with: sudo uv sync --project \"${BRAKERRAK_ROOT}\" --frozen --no-dev && sudo chmod -R a+rX \"${BRAKERRAK_ROOT}/.venv\""
        fi
    fi
else
    log_brak "Aggregate telemetry with:"
    if [[ -x "${BRAKERRAK_ROOT}/.venv/bin/python" ]]; then
        printf "  %s %s %s\n" \
            "${BRAKERRAK_ROOT}/.venv/bin/python" "${SCRIPT_DIR}/analyze_showdown.py" "$RUN_DIR"
    elif [[ -d "${BRAKERRAK_ROOT}/.venv" || -n "${UV_PROJECT_ENVIRONMENT:-}" ]]; then
        printf "  uv run --project %s --no-sync %s %s\n" \
            "$BRAKERRAK_ROOT" "${SCRIPT_DIR}/analyze_showdown.py" "$RUN_DIR"
    else
        printf "  python3 %s %s  # or provision venv: sudo uv sync --project %s --frozen --no-dev && sudo chmod -R a+rX %s/.venv\n" \
            "${SCRIPT_DIR}/analyze_showdown.py" "$RUN_DIR" "$BRAKERRAK_ROOT" "$BRAKERRAK_ROOT"
    fi
fi
