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
    validate_plan_shape,
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


def test_multi_iteration_quantiles_eic_and_direct_io_grouping(tmp_path: Path) -> None:
    run_dir = tmp_path / "showdown-multi-iter"
    passes_root = run_dir / "passes"
    passes_root.mkdir(parents=True)
    (run_dir / "metadata.json").write_text(
        json.dumps(
            {
                "schema_version": SCHEMA_VERSION,
                "run_id": "showdown-multi-iter",
                "node_id": "brakerbench-multi-test",
                "pillar": CTD_PILLAR,
                "component": CTD_COMPONENT,
                "captured_at_utc": "2026-11-24T01:00:00Z",
                "architecture": "riscv64",
                "kernel_release": "6.12.0-riscv64",
                "device_tree_model": "SiFive HiFive Premier P550",
                "cpu_harts_count": 4,
                "pg_server_version": "18.6",
                "db_name": "brakerrak",
                "table_name": "brakerrak_io_torture",
                "nvme_device": "/dev/nvme0n1",
                "nvme_short": "nvme0n1",
            }
        ),
        encoding="utf-8",
    )

    # Create 3 iterations using iter_01/<pass_dir> layout for io_uring eic=16 and eic=32,
    # plus io_direct="data" on eic=32, and sync baseline across 3 iterations.
    sync_execs = [300.0, 310.0, 320.0]
    uring_16_execs = [100.0, 200.0, 300.0]
    uring_32_execs = [80.0, 90.0, 100.0]

    for idx, (s_ms, u16_ms, u32_ms) in enumerate(
        zip(sync_execs, uring_16_execs, uring_32_execs, strict=True), start=1
    ):
        iter_dir = passes_root / f"iter_{idx:02d}"
        _write_pass_fixture(
            iter_dir,
            cache_mode="cold",
            io_method="sync",
            eic=16,
            workload="bitmap_heap_scan",
            exec_ms=s_ms,
            plan_ms=0.5,
            shared_read_blocks=16384,
            io_read_ms=200.0,
            cycles=1_000_000,
            instructions=1_000_000,
            ctx_switches=100,
            sectors_read_delta=262_144,
        )
        _write_pass_fixture(
            iter_dir,
            cache_mode="cold",
            io_method="io_uring",
            eic=16,
            workload="bitmap_heap_scan",
            exec_ms=u16_ms,
            plan_ms=0.5,
            shared_read_blocks=16384,
            io_read_ms=100.0,
            cycles=1_000_000,
            instructions=1_000_000,
            ctx_switches=50,
            sectors_read_delta=262_144,
        )
        _write_pass_fixture(
            iter_dir,
            cache_mode="cold",
            io_method="io_uring",
            eic=32,
            workload="bitmap_heap_scan",
            exec_ms=u32_ms,
            plan_ms=0.5,
            shared_read_blocks=16384,
            io_read_ms=80.0,
            cycles=1_000_000,
            instructions=1_000_000,
            ctx_switches=40,
            sectors_read_delta=262_144,
        )

    # Also verify <pass_dir>_iter01 flat suffixed layout + distinct io_direct grouping
    direct_pdir = _write_pass_fixture(
        passes_root,
        cache_mode="cold",
        io_method="io_uring",
        eic=32,
        workload="bitmap_heap_scan",
        exec_ms=75.0,
        plan_ms=0.5,
        shared_read_blocks=16384,
        io_read_ms=60.0,
        cycles=1_000_000,
        instructions=1_000_000,
        ctx_switches=30,
        sectors_read_delta=262_144,
    )
    suffixed_dir = passes_root / f"{direct_pdir.name}_iter04"
    direct_pdir.rename(suffixed_dir)
    pmeta = json.loads((suffixed_dir / "pass_meta.json").read_text(encoding="utf-8"))
    # Verify fallback to "data" when io_direct is omitted/empty while with_direct_io=True
    pmeta["with_direct_io"] = True
    pmeta["iteration"] = 4
    (suffixed_dir / "pass_meta.json").write_text(json.dumps(pmeta), encoding="utf-8")

    artifacts = analyze_showdown_run(run_dir, out_dir=tmp_path / "out")
    assert artifacts.table.num_rows == 10

    summaries = compute_method_summaries(artifacts.table)
    summary_by_key = {
        (s.cache_mode, s.workload, s.io_method, s.effective_io_concurrency, s.io_direct): s
        for s in summaries
    }
    assert len(summary_by_key) == 4

    u16 = summary_by_key[("cold", "bitmap_heap_scan", "io_uring", 16, "off")]
    assert u16.n == 3
    assert u16.min_ms == pytest.approx(100.0)
    assert u16.p50_ms == pytest.approx(200.0)
    assert u16.p95_ms == pytest.approx(290.0)
    assert u16.p99_ms == pytest.approx(298.0)
    assert u16.mean_ms == pytest.approx(200.0)
    assert u16.stddev_ms == pytest.approx(100.0)
    assert u16.max_ms == pytest.approx(300.0)

    u32_off = summary_by_key[("cold", "bitmap_heap_scan", "io_uring", 32, "off")]
    assert u32_off.n == 3
    assert u32_off.p50_ms == pytest.approx(90.0)
    assert u32_off.stddev_ms == pytest.approx(10.0)

    u32_direct = summary_by_key[("cold", "bitmap_heap_scan", "io_uring", 32, "data")]
    assert u32_direct.n == 1
    assert u32_direct.stddev_ms == pytest.approx(0.0)
    assert u32_direct.mean_ms == pytest.approx(75.0)
    assert "Direct I/O" in artifacts.markdown


def test_wall_throughput_pg_io_throughput_and_warm_hits(tmp_path: Path) -> None:
    run_dir = tmp_path / "showdown-tput"
    iter_dir = run_dir / "passes" / "iter_01"
    iter_dir.mkdir(parents=True)
    (run_dir / "metadata.json").write_text(
        json.dumps({"run_id": "showdown-tput", "node_id": "test-node"}),
        encoding="utf-8",
    )

    pdir = _write_pass_fixture(
        iter_dir,
        cache_mode="cold",
        io_method="io_uring",
        eic=32,
        workload="seq_scan",
        exec_ms=4000.0,
        plan_ms=1.0,
        shared_read_blocks=131072,  # 1024 MiB (131072 * 8192 bytes)
        io_read_ms=2000.0,  # 2.0s -> pg_io_read_mib_s = 512.0 MiB/s
        cycles=1_000_000,
        instructions=1_200_000,
        ctx_switches=100,
        sectors_read_delta=2_097_152,  # 1024 MiB
    )
    # Set wall_duration_ms = 5000.0 (different from execution_time_ms = 4000.0)
    pmeta = json.loads((pdir / "pass_meta.json").read_text(encoding="utf-8"))
    pmeta["wall_duration_ms"] = 5000.0
    (pdir / "pass_meta.json").write_text(json.dumps(pmeta), encoding="utf-8")

    # Warm-cache pass with reads=0 and hits=50000 in pg_stat_io.json
    warm_pdir = _write_pass_fixture(
        iter_dir,
        cache_mode="warm",
        io_method="io_uring",
        eic=32,
        workload="seq_scan",
        exec_ms=250.0,
        plan_ms=0.5,
        shared_read_blocks=0,
        io_read_ms=0.0,
        cycles=500_000,
        instructions=750_000,
        ctx_switches=20,
        sectors_read_delta=0,
    )
    (warm_pdir / "pg_stat_io.json").write_text(
        json.dumps(
            [
                {
                    "backend_type": "client backend",
                    "object": "relation",
                    "context": "normal",
                    "reads": 0,
                    "hits": 50000,
                    "writes": 0,
                    "op_bytes": 8192,
                }
            ]
        ),
        encoding="utf-8",
    )

    artifacts = analyze_showdown_run(run_dir, out_dir=tmp_path / "out")
    by_cm = {r["cache_mode"]: r for r in artifacts.table.to_pylist()}

    cold_row = by_cm["cold"]
    # 1024 MiB / 5.0 s (wall_duration_ms) = 204.8 MiB/s (NOT 1024 / 4.0 = 256.0)
    assert cold_row["wall_duration_ms"] == pytest.approx(5000.0)
    assert cold_row["nvme_read_mib_s"] == pytest.approx(204.8)
    # 131072 * 8192 B / 1048576 / 2.0 s = 512.0 MiB/s
    assert cold_row["pg_io_read_mib_s"] == pytest.approx(512.0)

    warm_row = by_cm["warm"]
    assert warm_row["pg_stat_io_reads"] == 0
    assert warm_row["pg_stat_io_hits"] == 50000
    assert warm_row["pg_io_read_mib_s"] is None


def test_perf_pmu_multiplexing_and_plan_shape_validation(tmp_path: Path) -> None:
    # 1. PMU multiplexing detection via pcnt-running < 100.0
    perf_clean = tmp_path / "perf_clean.json"
    perf_clean.write_text(
        "\n".join(
            [
                json.dumps({"event": "cycles", "counter-value": "1000000", "pcnt-running": 100.0}),
                json.dumps(
                    {
                        "event": "LLC-load-misses",
                        "counter-value": "<not supported>",
                        "pcnt-running": 0.0,
                    }
                ),
            ]
        ),
        encoding="utf-8",
    )
    m_clean = parse_perf_stat_json(perf_clean)
    assert m_clean.pmu_multiplexed is False
    assert m_clean.min_pcnt_running == pytest.approx(100.0)

    perf_mux = tmp_path / "perf_mux.json"
    perf_mux.write_text(
        "\n".join(
            [
                json.dumps({"event": "cycles", "counter-value": "1000000", "pcnt-running": 100.0}),
                json.dumps({"metric-value": "1.37", "metric-unit": "insn per cycle"}),
                json.dumps(
                    {
                        "event": "dTLB-load-misses",
                        "counter-value": "45000",
                        "pcnt-running": 62.5,
                    }
                ),
            ]
        ),
        encoding="utf-8",
    )
    m_mux = parse_perf_stat_json(perf_mux)
    assert m_mux.pmu_multiplexed is True
    assert m_mux.min_pcnt_running == pytest.approx(62.5)
    assert m_mux.ipc == pytest.approx(1.37)

    # 2. Plan-shape validation across Parallel Seq Scan, Seq Scan, Bitmap Heap Scan, and mismatch
    run_dir = tmp_path / "showdown-plan-mux"
    iter_dir = run_dir / "passes" / "iter_01"
    iter_dir.mkdir(parents=True)
    (run_dir / "metadata.json").write_text(
        json.dumps({"run_id": "showdown-plan-mux", "node_id": "test-node"}),
        encoding="utf-8",
    )

    p_parallel_seq = _write_pass_fixture(
        iter_dir,
        cache_mode="cold",
        io_method="io_uring",
        eic=32,
        workload="seq_scan",
        exec_ms=1000.0,
        plan_ms=0.5,
        shared_read_blocks=1000,
        io_read_ms=500.0,
        cycles=1_000_000,
        instructions=1_000_000,
        ctx_switches=50,
        sectors_read_delta=1000,
    )
    (p_parallel_seq / "explain.json").write_text(
        json.dumps(
            [
                {
                    "Plan": {
                        "Node Type": "Finalize Aggregate",
                        "Plans": [
                            {
                                "Node Type": "Gather",
                                "Plans": [
                                    {
                                        "Node Type": "Partial Aggregate",
                                        "Plans": [{"Node Type": "Parallel Seq Scan"}],
                                    }
                                ],
                            }
                        ],
                    },
                    "Execution Time": 1000.0,
                    "Planning Time": 0.5,
                }
            ]
        ),
        encoding="utf-8",
    )
    (p_parallel_seq / "perf_stat.json").write_text(
        perf_mux.read_text(encoding="utf-8"),
        encoding="utf-8",
    )

    p_bad_bmp = _write_pass_fixture(
        iter_dir,
        cache_mode="cold",
        io_method="io_uring",
        eic=16,
        workload="bitmap_heap_scan",
        exec_ms=500.0,
        plan_ms=0.5,
        shared_read_blocks=500,
        io_read_ms=200.0,
        cycles=500_000,
        instructions=500_000,
        ctx_switches=20,
        sectors_read_delta=500,
    )
    (p_bad_bmp / "explain.json").write_text(
        json.dumps(
            [
                {
                    "Plan": {
                        "Node Type": "Aggregate",
                        "Plans": [{"Node Type": "Index Only Scan"}],
                    },
                    "Execution Time": 500.0,
                    "Planning Time": 0.5,
                }
            ]
        ),
        encoding="utf-8",
    )

    ex_seq = parse_explain_json(p_parallel_seq / "explain.json")
    assert validate_plan_shape("seq_scan", ex_seq) is True
    assert validate_plan_shape("bitmap_heap_scan", ex_seq) is False

    ex_bad_bmp = parse_explain_json(p_bad_bmp / "explain.json")
    assert validate_plan_shape("bitmap_heap_scan", ex_bad_bmp) is False

    artifacts = analyze_showdown_run(run_dir, out_dir=tmp_path / "out")
    by_wl = {r["workload"]: r for r in artifacts.table.to_pylist()}
    assert by_wl["seq_scan"]["plan_shape_valid"] is True
    assert by_wl["seq_scan"]["perf_pmu_multiplexed"] is True
    assert by_wl["seq_scan"]["perf_min_pcnt_running"] == pytest.approx(62.5)
    assert by_wl["bitmap_heap_scan"]["plan_shape_valid"] is False
    assert "PMU Multiplexing Warning" in artifacts.markdown
    assert "Plan Shape Warning" in artifacts.markdown
