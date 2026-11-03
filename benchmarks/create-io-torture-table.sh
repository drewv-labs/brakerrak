#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Agnostic I/O Torture Dataset Generator
# Usage: ./seed-io-torture.sh [--rows 50000000] [--workers $(nproc)] [--table brakerrak_io_torture]
# ==============================================================================
set -Eeuo pipefail

TOTAL_ROWS="${TOTAL_ROWS:-50000000}"
WORKERS="${WORKERS:-$(nproc)}"
TABLE_NAME="${TABLE_NAME:-brakerrak_io_torture}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rows)    TOTAL_ROWS="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --table)   TABLE_NAME="$2"; shift 2 ;;
        *) echo "[FATAL] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

DT_MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || uname -m)"
ROWS_PER_WORKER=$(( TOTAL_ROWS / WORKERS ))
MAINT_WORKERS=$(( WORKERS > 1 ? WORKERS - 1 : 1 ))

echo "======================================================================"
echo " BrakerRak // Seeding '${TABLE_NAME}' on $(hostname)"
echo " Silicon : ${DT_MODEL}"
echo " Profile : ${TOTAL_ROWS} rows across ${WORKERS} parallel hart workers"
echo "======================================================================"

# 1. Create the unlogged table in its own committed transaction
sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "
DROP TABLE IF EXISTS ${TABLE_NAME};
CREATE UNLOGGED TABLE ${TABLE_NAME} (
    id          bigint,
    sensor_code int,
    scatter_key int,
    reading     double precision,
    payload     text
);
"

# 2. Fan out N concurrent workers (1 per hart) with strict PID error tracking
START_TS="$(date +%s)"
PIDS=()
for (( worker=0; worker<WORKERS; worker++ )); do
    start_id=$(( worker * ROWS_PER_WORKER + 1 ))
    if (( worker == WORKERS - 1 )); then
        end_id="$TOTAL_ROWS"
    else
        end_id=$(( (worker + 1) * ROWS_PER_WORKER ))
    fi

    sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "
    INSERT INTO ${TABLE_NAME}
    SELECT
        i,
        (i % 1000),
        (random() * 1000000)::int,
        random() * 100.0,
        repeat(md5(i::text), 5)
    FROM generate_series(${start_id}, ${end_id}) AS s(i);
    " &
    PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
    wait "$pid"
done
INSERT_SEC=$(( $(date +%s) - START_TS ))
echo "[+] Inserted ${TOTAL_ROWS} rows across ${WORKERS} harts in ${INSERT_SEC}s"

# 3. Build B-Tree index using parallel maintenance workers
INDEX_TS="$(date +%s)"
sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "
SET max_parallel_maintenance_workers = ${MAINT_WORKERS};
CREATE INDEX idx_torture_scatter ON ${TABLE_NAME} (scatter_key);
"
echo "[+] Built idx_torture_scatter in $(( $(date +%s) - INDEX_TS ))s"

# 4. Run VACUUM ANALYZE in its own standalone command (outside transaction block)
sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "VACUUM ANALYZE ${TABLE_NAME};"

# 5. Verify final heap and index footprint
sudo -u postgres psql -c "
SELECT
    '$(hostname)' AS node,
    ${WORKERS} AS harts,
    pg_size_pretty(pg_relation_size('${TABLE_NAME}')) AS heap_size,
    pg_size_pretty(pg_indexes_size('${TABLE_NAME}')) AS index_size,
    pg_size_pretty(pg_total_relation_size('${TABLE_NAME}')) AS total_size;
"
