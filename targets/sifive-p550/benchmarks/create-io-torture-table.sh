#!/bin/bash

# 1. Create the table in its own committed transaction
sudo -u postgres psql -c "
DROP TABLE IF EXISTS p550_io_torture;
CREATE UNLOGGED TABLE p550_io_torture (
    id          bigint,
    sensor_code int,
    scatter_key int,
    reading     double precision,
    payload     text
);
"

# 2. Fan out 4 concurrent workers (12.5M rows per P550 core = 50M rows total)
for worker in 0 1 2 3; do
    start_id=$(( worker * 12500000 + 1 ))
    end_id=$(( (worker + 1) * 12500000 ))
    sudo -u postgres psql -c "
    INSERT INTO p550_io_torture
    SELECT
        i,
        (i % 1000),
        (random() * 1000000)::int,
        random() * 100.0,
        repeat(md5(i::text), 5)
    FROM generate_series($start_id, $end_id) AS s(i);
    " &
done
wait

# 3. Build the B-Tree index in its own transaction
sudo -u postgres psql -c "CREATE INDEX idx_torture_scatter ON p550_io_torture (scatter_key);"

# 4. Run VACUUM ANALYZE in its own standalone command (no transaction block)
sudo -u postgres psql -c "VACUUM ANALYZE p550_io_torture;"

# 5. Verify final heap and index footprint
sudo -u postgres psql -c "
SELECT
    pg_size_pretty(pg_relation_size('p550_io_torture')) AS heap_size,
    pg_size_pretty(pg_indexes_size('p550_io_torture')) AS index_size,
    pg_size_pretty(pg_total_relation_size('p550_io_torture')) AS total_size;
"
