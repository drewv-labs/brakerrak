#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Agnostic PG18 Async I/O & PMU Showdown
# ==============================================================================
set -Eeuo pipefail

TABLE_NAME="${TABLE_NAME:-brakerrak_io_torture}"
HARTS="$(nproc)"
GATHER_WORKERS=$(( HARTS > 1 ? HARTS - 1 : 0 ))
PERF_EVENTS="cycles,instructions,context-switches,L1-dcache-load-misses,dTLB-load-misses"

for METHOD in sync worker io_uring; do
    echo "=================================================================="
    echo ">>> [$(hostname)] PostgreSQL 18 Showdown: io_method = ${METHOD} (${HARTS} Harts)"
    echo "=================================================================="

    sudo -u postgres psql -q -c "ALTER SYSTEM SET io_method = '${METHOD}';"
    sudo -u postgres psql -q -c "ALTER SYSTEM SET effective_io_concurrency = 200;"
    sudo systemctl restart postgresql

    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2

    sudo -u postgres psql -t -A -c "SHOW io_method;"
    sudo -u postgres psql -q -c "SELECT pg_stat_reset_shared('io');"

    echo "--- [Workload A] Cold-Cache Parallel Sequential Scan (${GATHER_WORKERS} Gather Workers) ---"
    sudo perf stat -a -e "$PERF_EVENTS" \
        sudo -u postgres psql -c "
        SET max_parallel_workers_per_gather = ${GATHER_WORKERS};
        EXPLAIN (ANALYZE, BUFFERS, TIMING)
        SELECT sensor_code, count(*), avg(reading)
        FROM ${TABLE_NAME}
        GROUP BY sensor_code;
        " 2>&1 | grep -E "Execution Time|Buffers: shared|I/O Timings|cycles|instructions|context-switches|dcache|dTLB|time elapsed"

    sudo systemctl restart postgresql
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2

    echo "--- [Workload B] Cold-Cache Scattered Bitmap Heap Scan (200-Way Prefetch) ---"
    sudo perf stat -a -e "$PERF_EVENTS" \
        sudo -u postgres psql -c "
        SET enable_seqscan = off;
        SET max_parallel_workers_per_gather = 0;
        EXPLAIN (ANALYZE, BUFFERS, TIMING)
        SELECT avg(reading), sum(id)
        FROM ${TABLE_NAME}
        WHERE scatter_key BETWEEN 10000 AND 45000;
        " 2>&1 | grep -E "Execution Time|Buffers: shared|I/O Timings|cycles|instructions|context-switches|dcache|dTLB|time elapsed"

    echo "--- [pg_stat_io Summary: ${METHOD}] ---"
    sudo -u postgres psql -c "
        SELECT backend_type, context, reads, ROUND(read_time::numeric, 2) AS read_ms
        FROM pg_stat_io
        WHERE reads > 0 AND object = 'relation'
        ORDER BY reads DESC;
    "
    echo ""
done
