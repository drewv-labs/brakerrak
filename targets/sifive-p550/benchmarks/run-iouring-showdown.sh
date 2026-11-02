#!/usr/bin/env bash
set -euo pipefail

for METHOD in sync worker io_uring; do
    echo "=================================================================="
    echo ">>> TESTING PostgreSQL 18.6 WITH: io_method = $METHOD"
    echo "=================================================================="

    # 1. Switch io_method and restart PostgreSQL to wipe 8GB shared_buffers
    sudo -u postgres psql -q -c "ALTER SYSTEM SET io_method = '$METHOD';"
    sudo -u postgres psql -q -c "ALTER SYSTEM SET effective_io_concurrency = 200;"
    sudo systemctl restart postgresql@18-main

    # 2. Flush Linux kernel page cache so 100% of reads hit physical 4Kn NVMe
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2

    # 3. Verify active io_method and reset pg_stat_io counters
    sudo -u postgres psql -t -A -c "SHOW io_method;"
    sudo -u postgres psql -q -c "SELECT pg_stat_reset_shared('io');"

    # 4. WORKLOAD A: Cold-Cache Full Table Aggregation (Sequential Read Stream)
    echo "--- [Workload A] Cold-Cache 50M Row Parallel Scan & Aggregation ---"
    sudo perf stat -a -e cycles,instructions,context-switches,L1-dcache-load-misses,dTLB-load-misses \
        sudo -u postgres psql -c "
        SET max_parallel_workers_per_gather = 3;
        EXPLAIN (ANALYZE, BUFFERS, TIMING)
        SELECT sensor_code, count(*), avg(reading)
        FROM p550_io_torture
        GROUP BY sensor_code;
        " 2>&1 | grep -E "Execution Time|Buffers: shared|I/O Timings|cycles|instructions|context-switches|dcache|dTLB|time elapsed"

    # 5. Flush caches again before Workload B
    sudo systemctl restart postgresql@18-main
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    sleep 2

    # 6. WORKLOAD B: Cold-Cache Scattered Bitmap Heap Scan (200-way Async Prefetch)
    echo "--- [Workload B] Cold-Cache Scattered Bitmap Heap Scan ---"
    sudo perf stat -a -e cycles,instructions,context-switches,L1-dcache-load-misses,dTLB-load-misses \
        sudo -u postgres psql -c "
        SET enable_seqscan = off;
        SET max_parallel_workers_per_gather = 0;
        EXPLAIN (ANALYZE, BUFFERS, TIMING)
        SELECT avg(reading), sum(id)
        FROM p550_io_torture
        WHERE scatter_key BETWEEN 10000 AND 45000;
        " 2>&1 | grep -E "Execution Time|Buffers: shared|I/O Timings|cycles|instructions|context-switches|dcache|dTLB|time elapsed"

    # 7. Dump pg_stat_io summary for this mode
    echo "--- [pg_stat_io Summary for $METHOD] ---"
    sudo -u postgres psql -c "
        SELECT backend_type, context, reads, ROUND(read_time::numeric, 2) AS read_ms
        FROM pg_stat_io
        WHERE reads > 0 AND object = 'relation'
        ORDER BY reads DESC;
    "
    echo ""
done
