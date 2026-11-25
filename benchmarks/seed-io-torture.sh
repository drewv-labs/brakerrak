#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Deterministic I/O Torture Dataset Generator
# Path: brakerrak/benchmarks/seed-io-torture.sh
#
# Usage:
#   ./benchmarks/seed-io-torture.sh [options]
#   sudo brakerrak bench seed [--db brakerrak] [--table brakerrak_io_torture] \
#       [--rows 50000000] [--workers 4] [--unlogged]
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
fi

brak_log_init "BRAKERRAK:SEED"
brak_sanitize_locale

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

usage() {
    cat <<'EOF'
Usage: seed-io-torture.sh [options]

Deterministically seeds the BrakerRak PostgreSQL 18 I/O torture dataset across
parallel workers using hash-derived tuple distributions (bit-identical across
4-hart and 8-hart RISC-V targets regardless of --workers).

Options:
  --db <name>          Target PostgreSQL database (default: brakerrak; created if absent)
  --table <name>       Target table name (default: brakerrak_io_torture)
  --rows <N>           Total rows to generate (default: 50000000)
  --workers <N>        Parallel seed workers (default: detected CPU harts)
  --pg-user <user>     PostgreSQL superuser role (default: postgres)
  --unlogged           Create an UNLOGGED table (opt-in for fast dev smoke tests)
  --logged             Create a standard LOGGED table (default)
  -h, --help           Show this help message and exit

Environment overrides:
  DB_NAME, TABLE_NAME, TOTAL_ROWS, WORKERS, PG_USER, UNLOGGED
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

validate_pos_int() {
    local label="$1"
    local val="$2"
    if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
        log_fatal "Invalid ${label} '${val}': must be a positive integer"
    fi
}

DB_NAME="${DB_NAME:-brakerrak}"
TABLE_NAME="${TABLE_NAME:-brakerrak_io_torture}"
TOTAL_ROWS="${TOTAL_ROWS:-50000000}"
WORKERS="${WORKERS:-$(detect_cpu_harts)}"
PG_USER="${PG_USER:-postgres}"
UNLOGGED="${UNLOGGED:-false}"

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
        --rows)
            brak_require_arg "$1" "${2:-}"
            TOTAL_ROWS="$2"
            shift 2
            ;;
        --rows=*)
            TOTAL_ROWS="${1#*=}"
            brak_require_arg "--rows" "$TOTAL_ROWS"
            shift
            ;;
        --workers)
            brak_require_arg "$1" "${2:-}"
            WORKERS="$2"
            shift 2
            ;;
        --workers=*)
            WORKERS="${1#*=}"
            brak_require_arg "--workers" "$WORKERS"
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
        --unlogged)
            UNLOGGED="true"
            shift
            ;;
        --logged)
            UNLOGGED="false"
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
validate_pos_int "TOTAL_ROWS" "$TOTAL_ROWS"
validate_pos_int "WORKERS" "$WORKERS"

case "$UNLOGGED" in
    true|false) ;;
    *) log_fatal "Invalid UNLOGGED='${UNLOGGED}': must be 'true' or 'false'" ;;
esac

if ! command -v psql >/dev/null 2>&1; then
    log_fatal "psql client not found in PATH."
fi

run_psql() {
    local target_db="$1"
    shift
    if [[ "$(id -un)" == "$PG_USER" ]]; then
        psql -X -U "$PG_USER" -d "$target_db" -v ON_ERROR_STOP=1 "$@"
    else
        sudo -u "$PG_USER" psql -X -U "$PG_USER" -d "$target_db" -v ON_ERROR_STOP=1 "$@"
    fi
}

PIDS=()
cleanup_workers() {
    local pid
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}
trap 'cleanup_workers; exit 130' INT
trap 'cleanup_workers; exit 143' TERM

EFFECTIVE_WORKERS="$WORKERS"
if (( EFFECTIVE_WORKERS > TOTAL_ROWS )); then
    EFFECTIVE_WORKERS="$TOTAL_ROWS"
fi

DT_MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || uname -m)"
ROWS_PER_WORKER=$(( TOTAL_ROWS / EFFECTIVE_WORKERS ))
MAINT_WORKERS=$(( EFFECTIVE_WORKERS > 1 ? EFFECTIVE_WORKERS - 1 : 1 ))

TABLE_MODE="LOGGED"
TABLE_DDL_PREFIX=""
if [[ "$UNLOGGED" == "true" ]]; then
    TABLE_MODE="UNLOGGED"
    TABLE_DDL_PREFIX="UNLOGGED "
fi

INDEX_NAME="idx_${TABLE_NAME}_scatter"
INDEX_NAME="${INDEX_NAME:0:63}"

echo "======================================================================"
echo " BrakerRak // Deterministic Seed '${DB_NAME}.${TABLE_NAME}' on $(hostname)"
echo " Silicon : ${DT_MODEL}"
echo " Profile : ${TOTAL_ROWS} rows | ${EFFECTIVE_WORKERS} parallel workers | ${TABLE_MODE}"
echo "======================================================================"

# 1. Create target database idempotently (never polluting the 'postgres' maintenance DB)
log_step "1. Ensuring database '${DB_NAME}' exists"
if run_psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" | grep -qx '1'; then
    log_skip "Database '${DB_NAME}' already exists"
else
    run_psql postgres -q -c "CREATE DATABASE \"${DB_NAME}\";"
    log_ok "Created database '${DB_NAME}'"
fi

# 2. Recreate target table in its own committed transaction
log_step "2. Creating ${TABLE_MODE} table '${DB_NAME}.${TABLE_NAME}'"
run_psql "$DB_NAME" -q -c "
DROP TABLE IF EXISTS \"${TABLE_NAME}\";
CREATE ${TABLE_DDL_PREFIX}TABLE \"${TABLE_NAME}\" (
    id          bigint,
    sensor_code int,
    scatter_key int,
    reading     double precision,
    payload     text
);
"
log_ok "Initialized ${TABLE_MODE} table '${TABLE_NAME}'"

# 3. Fan out N deterministic workers with strict PID tracking
log_step "3. Seeding ${TOTAL_ROWS} deterministic rows across ${EFFECTIVE_WORKERS} workers"
START_TS="$(date +%s)"
for (( worker=0; worker<EFFECTIVE_WORKERS; worker++ )); do
    start_id=$(( worker * ROWS_PER_WORKER + 1 ))
    if (( worker == EFFECTIVE_WORKERS - 1 )); then
        end_id="$TOTAL_ROWS"
    else
        end_id=$(( (worker + 1) * ROWS_PER_WORKER ))
    fi

    run_psql "$DB_NAME" -q -c "
    INSERT INTO \"${TABLE_NAME}\" (id, sensor_code, scatter_key, reading, payload)
    SELECT
        i,
        (i % 1000)::int,
        ((('x' || substr(md5(i::text), 1, 8))::bit(32)::bigint & 2147483647) % 1000000)::int,
        ((('x' || substr(md5((i || ':r')::text), 1, 8))::bit(32)::bigint & 2147483647)::double precision / 21474836.47),
        repeat(md5(i::text), 5)
    FROM generate_series(${start_id}, ${end_id}) AS s(i);
    " &
    PIDS+=("$!")
done

WORKER_FAIL=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        WORKER_FAIL=1
    fi
done
PIDS=()
if [[ "$WORKER_FAIL" -ne 0 ]]; then
    log_fatal "One or more parallel seed workers exited with an error."
fi

INSERT_SEC=$(( $(date +%s) - START_TS ))
log_ok "Inserted ${TOTAL_ROWS} deterministic rows across ${EFFECTIVE_WORKERS} workers in ${INSERT_SEC}s"

# 4. Build B-Tree scatter index using parallel maintenance workers
log_step "4. Building B-Tree index '${INDEX_NAME}' (${MAINT_WORKERS} maintenance workers)"
INDEX_TS="$(date +%s)"
run_psql "$DB_NAME" -q -c "
SET max_parallel_maintenance_workers = ${MAINT_WORKERS};
CREATE INDEX \"${INDEX_NAME}\" ON \"${TABLE_NAME}\" (scatter_key);
"
log_ok "Built '${INDEX_NAME}' in $(( $(date +%s) - INDEX_TS ))s"

# 5. Run VACUUM (FREEZE, ANALYZE) and CHECKPOINT in standalone commands (outside transaction block)
log_step "5. Running VACUUM (FREEZE, ANALYZE) and CHECKPOINT on '${TABLE_NAME}'"
run_psql "$DB_NAME" -q -c "VACUUM (FREEZE, ANALYZE) \"${TABLE_NAME}\";"
run_psql "$DB_NAME" -q -c "CHECKPOINT;"
log_ok "VACUUM (FREEZE, ANALYZE) and CHECKPOINT complete"

# 6. Verify final heap and index footprint
log_step "6. Verifying table footprint"
run_psql "$DB_NAME" -v node_host="$(hostname)" -c "
SELECT
    :'node_host' AS node,
    '${DB_NAME}' AS db_name,
    '${TABLE_NAME}' AS table_name,
    '${TABLE_MODE}' AS table_mode,
    ${EFFECTIVE_WORKERS} AS workers,
    count(*) AS row_count,
    pg_size_pretty(pg_relation_size('\"${TABLE_NAME}\"')) AS heap_size,
    pg_size_pretty(pg_indexes_size('\"${TABLE_NAME}\"')) AS index_size,
    pg_size_pretty(pg_total_relation_size('\"${TABLE_NAME}\"')) AS total_size
FROM \"${TABLE_NAME}\";
"
