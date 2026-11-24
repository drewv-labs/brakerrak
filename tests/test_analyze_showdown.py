"""Unit tests for benchmarks/analyze_showdown.py PyArrow CTD aggregator."""

from __future__ import annotations

import json
from pathlib import Path

import pyarrow.ipc as ipc
import pyarrow.parquet as pq
import pytest

from benchmarks.analyze_showdown import (
    CTD_COMPONENT,
    CTD_PILLAR,
    SCHEMA_VERSION,
    SHOWDOWN_SCHEMA,
    CTDShowdownRecord,
    analyze_showdown_run,
    compute_method_summaries,
    load_showdown_passes,
    main,
    parse_diskstats_delta,
    parse_explain_json,
    parse_perf_stat_json,
    parse_pg_stat_io_json,
)


def _write_pass_fixture(
    passes_root: Path,
    *,
    cache_mode: str,
    io_method: str,
    eic: int,
    workload: str,
    exec_ms: float,
    plan_ms: float,
    shared_read_blocks: int,
    io_read_ms: float,
    cycles: int | None,
    instructions: int | None,
    ctx_switches: int | None,
    sectors_read_delta: int,
    io_worker_reads: int = 0,
    legacy_io_key: bool = False,
) -> Path:
    pdir = passes_root / f"{cache_mode}__{io_method}__eic{eic}__{workload}"
    pdir.mkdir(parents=True, exist_ok=True)

    (pdir / "pass_meta.json").write_text(
        json.dumps(
            {
                "run_id": "showdown-20261124T000000Z",
                "node_id": "brakerbench-p550-test",
                "cache_mode": cache_mode,
                "io_method": io_method,
                "effective_io_concurrency": eic,
                "io_workers": 4,
                "gather_workers": 2,
                "workload": workload,
                "nvme_short": "nvme0n1",
                "started_at_utc": "2026-11-24T00:00:00Z",
                "finished_at_utc": "2026-11-24T00:00:05Z",
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    io_key = "I/O Read Time" if legacy_io_key else "Shared I/O Read Time"
    explain_doc = [
        {
            "Plan": {
                "Node Type": "Aggregate",
                "Actual Total Time": exec_ms,
                "Shared Hit Blocks": 128,
                "Shared Read Blocks": shared_read_blocks,
                "Shared Dirtied Blocks": 4,
                "Shared Written Blocks": 0,
                io_key: io_read_ms,
                "Shared I/O Write Time": 0.25,
                "WAL Records": 12,
                "WAL FPI": 1,
                "WAL Bytes": 4096,
                "Plans": [
                    {
                        "Node Type": "Bitmap Heap Scan"
                        if workload == "bitmap_heap_scan"
                        else "Seq Scan",
                        "Shared Read Blocks": shared_read_blocks,
                        io_key: io_read_ms,
                    }
                ],
            },
            "Planning Time": plan_ms,
            "Execution Time": exec_ms,
        }
    ]
    # Include a leading psql command tag on one pass to verify resilient parsing.
    prefix = "SET\n" if (io_method == "io_uring" and workload == "seq_scan") else ""
    (pdir / "explain.json").write_text(prefix + json.dumps(explain_doc), encoding="utf-8")

    pg_stat_rows: list[dict[str, object]] = [
        {
            "backend_type": "client backend",
            "object": "relation",
            "context": "normal",
            "reads": shared_read_blocks - io_worker_reads,
            "op_bytes": 8192,
            "read_time": round(io_read_ms * 0.8, 3),
            "hits": 128,
            "writes": 0,
            "write_time": 0.0,
        }
    ]
    if io_worker_reads > 0:
        pg_stat_rows.append(
            {
                "backend_type": "io worker",
                "object": "relation",
                "context": "normal",
                "reads": io_worker_reads,
                "op_bytes": 8192,
                "read_time": round(io_read_ms * 0.2, 3),
                "hits": 0,
                "writes": 0,
                "write_time": 0.0,
            }
        )
    (pdir / "pg_stat_io.json").write_text(
        json.dumps({"rows": pg_stat_rows}),
        encoding="utf-8",
    )

    perf_lines: list[str] = []
    if cycles is not None:
        perf_lines.append(
            json.dumps({"counter-value": f"{cycles:.6f}", "event": "cpu-cycles:u"})
        )
    if instructions is not None:
        perf_lines.append(
            json.dumps(
                {
                    "counter-value": str(instructions),
                    "event": "instructions",
                    "metric-value": "0.99",
                    "metric-unit": "insn per cycle",
                }
            )
        )
    if ctx_switches is not None:
        perf_lines.append(
            json.dumps({"counter-value": str(ctx_switches), "event": "context-switches"})
        )
    perf_lines.append(json.dumps({"counter-value": "14", "event": "cpu-migrations"}))
    perf_lines.append(
        json.dumps({"counter-value": "<not supported>", "event": "LLC-load-misses"})
    )
    perf_lines.append(
        json.dumps({"counter-value": "250000", "event": "L1-dcache-load-misses"})
    )
    (pdir / "perf_stat.json").write_text("\n".join(perf_lines) + "\n", encoding="utf-8")

    before_line = "259 0 nvme0n1 1000 0 20000 500 200 0 4000 100 0 400 450 0 0 0 0\n"
    after_line = (
        f"259 0 nvme0n1 {1000 + 2500} 0 {20000 + sectors_read_delta} {500 + 1800} "
        f"{200 + 10} 0 {4000 + 80} {100 + 15} 0 {400 + 1600} {450 + 2100} 0 0 0 0\n"
    )
    (pdir / "diskstats_before.txt").write_text(before_line, encoding="utf-8")
    (pdir / "diskstats_after.txt").write_text(after_line, encoding="utf-8")
    return pdir


def _build_synthetic_run(tmp_path: Path) -> Path:
    run_dir = tmp_path / "showdown-20261124T000000Z"
    passes_root = run_dir / "passes"
    passes_root.mkdir(parents=True)

    (run_dir / "metadata.json").write_text(
        json.dumps(
            {
                "schema_version": SCHEMA_VERSION,
                "run_id": "showdown-20261124T000000Z",
                "node_id": "brakerbench-p550-test",
                "pillar": CTD_PILLAR,
                "component": CTD_COMPONENT,
                "captured_at_utc": "2026-11-24T00:00:00Z",
                "architecture": "riscv64",
                "kernel_release": "6.12.0-riscv64",
                "device_tree_model": "SiFive HiFive Premier P550",
                "cpu_harts_count": 4,
                "pg_server_version": "18.6",
                "db_name": "brakerrak",
                "table_name": "brakerrak_io_torture",
                "nvme_device": "/dev/nvme0n1",
                "nvme_short": "nvme0n1",
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    # 3-way io_method x concurrencies across two cold workloads + isolated warm pass
    _write_pass_fixture(
        passes_root,
        cache_mode="cold",
        io_method="sync",
        eic=0,
        workload="seq_scan",
        exec_ms=4000.0,
        plan_ms=1.2,
        shared_read_blocks=131072,
        io_read_ms=3200.5,
        cycles=5_000_000_000,
        instructions=4_000_000_000,
        ctx_switches=4200,
        sectors_read_delta=2_097_152,  # 1024 MiB -> 256.0 MiB/s at 4000ms
        legacy_io_key=True,
    )
    _write_pass_fixture(
        passes_root,
        cache_mode="cold",
        io_method="worker",
        eic=32,
        workload="seq_scan",
        exec_ms=2500.0,
        plan_ms=1.1,
        shared_read_blocks=131072,
        io_read_ms=1800.0,
        cycles=4_500_000_000,
        instructions=4_500_000_000,
        ctx_switches=9800,
        sectors_read_delta=2_097_152,
        io_worker_reads=90000,
    )
    _write_pass_fixture(
        passes_root,
        cache_mode="cold",
        io_method="io_uring",
        eic=32,
        workload="seq_scan",
        exec_ms=2000.0,
        plan_ms=1.0,
        shared_read_blocks=131072,
        io_read_ms=1350.0,
        cycles=4_000_000_000,
        instructions=5_000_000_000,
        ctx_switches=1800,
        sectors_read_delta=2_097_152,  # 1024 MiB -> 512.0 MiB/s at 2000ms
    )
    _write_pass_fixture(
        passes_root,
        cache_mode="cold",
        io_method="sync",
        eic=16,
        workload="bitmap_heap_scan",
        exec_ms=3000.0,
        plan_ms=0.9,
        shared_read_blocks=65536,
        io_read_ms=2400.0,
        cycles=3_000_000_000,
        instructions=2_700_000_000,
        ctx_switches=3100,
        sectors_read_delta=1_048_576,
    )
    _write_pass_fixture(
        passes_root,
        cache_mode="cold",
        io_method="io_uring",
        eic=16,
        workload="bitmap_heap_scan",
        exec_ms=1500.0,
        plan_ms=0.8,
        shared_read_blocks=65536,
        io_read_ms=900.0,
        cycles=2_500_000_000,
        instructions=3_000_000_000,
        ctx_switches=1200,
        sectors_read_delta=1_048_576,
    )
    _write_pass_fixture(
        passes_root,
        cache_mode="warm",
        io_method="io_uring",
        eic=32,
        workload="seq_scan",
        exec_ms=420.0,
        plan_ms=0.6,
        shared_read_blocks=0,
        io_read_ms=0.0,
        cycles=800_000_000,
        instructions=1_200_000_000,
        ctx_switches=150,
        sectors_read_delta=0,
    )
    return run_dir


def test_individual_parsers_handle_edge_cases(tmp_path: Path) -> None:
    # EXPLAIN with child-only buffers (parent omits Shared Read Blocks)
    ex_path = tmp_path / "explain_nested.json"
    ex_path.write_text(
        json.dumps(
            [
                {
                    "Plan": {
                        "Node Type": "Gather",
                        "Plans": [
                            {
                                "Node Type": "Seq Scan",
                                "Shared Read Blocks": 100,
                                "I/O Read Time": 10.5,
                            },
                            {
                                "Node Type": "Seq Scan",
                                "Shared Read Blocks": 250,
                                "I/O Read Time": 19.5,
                            },
                        ],
                    },
                    "Planning Time": 0.4,
                    "Execution Time": 42.0,
                }
            ]
        ),
        encoding="utf-8",
    )
    ex = parse_explain_json(ex_path)
    assert ex.shared_read_blocks == 350
    assert ex.io_read_time_ms == pytest.approx(30.0)
    assert ex.execution_time_ms == pytest.approx(42.0)

    # pg_stat_io plain array with explicit read_bytes and io worker separation
    io_path = tmp_path / "pg_stat_io.json"
    io_path.write_text(
        json.dumps(
            [
                {
                    "backend_type": "client backend",
                    "reads": 10,
                    "read_bytes": 81920,
                    "read_time": 5.5,
                },
                {"backend_type": "io worker", "reads": 25, "op_bytes": 8192, "read_time": 12.25},
            ]
        ),
        encoding="utf-8",
    )
    io_metrics = parse_pg_stat_io_json(io_path)
    assert io_metrics.reads == 35
    assert io_metrics.read_bytes == 81920 + 25 * 8192
    assert io_metrics.io_worker_reads == 25
    assert io_metrics.read_time_ms == pytest.approx(17.75)

    # perf stat JSON array + <not supported> + PMU prefix normalization
    perf_path = tmp_path / "perf_array.json"
    perf_path.write_text(
        json.dumps(
            [
                {"event": "cpu_core/cycles/", "counter-value": "2000000"},
                {"event": "instructions:k", "counter-value": "3000000"},
                {"event": "cs", "counter-value": "512"},
                {"event": "migrations", "counter-value": "7"},
                {"event": "dTLB-load-misses", "counter-value": "<not supported>"},
            ]
        ),
        encoding="utf-8",
    )
    perf = parse_perf_stat_json(perf_path)
    assert perf.cycles == 2_000_000
    assert perf.instructions == 3_000_000
    assert perf.ipc == pytest.approx(1.5)
    assert perf.context_switches == 512
    assert perf.cpu_migrations == 7
    assert perf.dtlb_load_misses is None

    # diskstats delta calculation
    before = tmp_path / "before.txt"
    after = tmp_path / "after.txt"
    before.write_text("259 0 nvme0n1 10 0 100 20 5 0 40 8 0 15 18\n", encoding="utf-8")
    after.write_text("259 0 nvme0n1 60 0 900 120 7 0 56 12 0 95 118\n", encoding="utf-8")
    delta = parse_diskstats_delta(before, after, device="nvme0n1")
    assert delta.device == "nvme0n1"
    assert delta.reads_completed == 50
    assert delta.sectors_read == 800
    assert delta.read_bytes == 800 * 512
    assert delta.read_time_ms == 100
    assert delta.writes_completed == 2
    assert delta.write_bytes == 16 * 512
    assert delta.io_time_ms == 80
    assert delta.weighted_io_time_ms == 100


def test_showdown_pyarrow_ingestion_markdown_and_roundtrip(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    run_dir = _build_synthetic_run(tmp_path)
    out_dir = tmp_path / "exported"

    meta, rows = load_showdown_passes(run_dir)
    assert meta.node_id == "brakerbench-p550-test"
    assert len(rows) == 6
    assert all(isinstance(row, CTDShowdownRecord) for row in rows)

    artifacts = analyze_showdown_run(run_dir, out_dir=out_dir)

    assert artifacts.table.num_rows == 6
    assert artifacts.table.schema.names == SHOWDOWN_SCHEMA.names
    assert len(artifacts.provenance_sha256) == 64

    # Validate vectorized PyArrow computed columns (throughput and speedup vs sync)
    by_key = {
        (r["cache_mode"], r["workload"], r["io_method"], r["effective_io_concurrency"]): r
        for r in artifacts.table.to_pylist()
    }
    seq_sync = by_key[("cold", "seq_scan", "sync", 0)]
    seq_worker = by_key[("cold", "seq_scan", "worker", 32)]
    seq_uring = by_key[("cold", "seq_scan", "io_uring", 32)]
    bmp_uring = by_key[("cold", "bitmap_heap_scan", "io_uring", 16)]

    assert seq_sync["nvme_read_mib_s"] == pytest.approx(256.0)
    assert seq_sync["speedup_vs_sync"] == pytest.approx(1.0)
    assert seq_worker["pg_stat_io_io_worker_reads"] == 90000
    assert seq_worker["speedup_vs_sync"] == pytest.approx(1.6)
    assert seq_uring["nvme_read_mib_s"] == pytest.approx(512.0)
    assert seq_uring["speedup_vs_sync"] == pytest.approx(2.0)
    assert seq_uring["perf_ipc"] == pytest.approx(1.25)
    assert seq_uring["perf_llc_load_misses"] is None
    assert bmp_uring["speedup_vs_sync"] == pytest.approx(2.0)

    # Validate method quantile summaries
    summaries = compute_method_summaries(artifacts.table)
    assert any(
        s.cache_mode == "cold" and s.workload == "seq_scan" and s.io_method == "io_uring"
        and s.p50_ms == pytest.approx(2000.0)
        for s in summaries
    )

    # Validate Markdown table rendering
    md = artifacts.markdown
    assert "## BrakerRak PG18 Async I/O Showdown" in md
    assert "### Per-Pass Ablation Matrix" in md
    assert "### Latency Summary by `io_method`" in md
    assert "| cold | seq_scan | `io_uring` | 32 | 2000.00 |" in md
    assert "| 2.00x |" in md

    # Validate Zstd Parquet round-trip and CTD schema metadata
    assert artifacts.parquet_path.is_file()
    pf = pq.ParquetFile(artifacts.parquet_path)
    assert pf.metadata.row_group(0).column(0).compression == "ZSTD"
    pq_table = pq.read_table(artifacts.parquet_path)
    assert pq_table.equals(artifacts.table)
    pq_meta = pq_table.schema.metadata or {}
    assert pq_meta[b"ctd.schema_version"] == SCHEMA_VERSION.encode("utf-8")
    assert pq_meta[b"ctd.pillar"] == CTD_PILLAR.encode("utf-8")
    assert pq_meta[b"ctd.component"] == CTD_COMPONENT.encode("utf-8")
    assert pq_meta[b"ctd.run_id"] == b"showdown-20261124T000000Z"
    assert pq_meta[b"ctd.node_id"] == b"brakerbench-p550-test"
    assert pq_meta[b"ctd.sha256_provenance_digest"] == artifacts.provenance_sha256.encode("utf-8")

    # Validate Arrow IPC file round-trip
    assert artifacts.arrow_path.is_file()
    with ipc.open_file(artifacts.arrow_path) as reader:
        ipc_table = reader.read_all()
    assert ipc_table.equals(artifacts.table)
    assert ipc_table.schema.metadata == pq_table.schema.metadata

    # Validate CLI entrypoint end-to-end
    cli_out = tmp_path / "cli_out"
    rc = main([str(run_dir), "--out-dir", str(cli_out), "--stem", "custom-stem"])
    assert rc == 0
    captured = capsys.readouterr()
    assert "### Per-Pass Ablation Matrix" in captured.out
    assert (cli_out / "custom-stem.parquet").is_file()
    assert (cli_out / "custom-stem.arrow").is_file()
