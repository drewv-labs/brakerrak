#!/usr/bin/env python3
"""DREW-V Labs // BrakerRak PostgreSQL 18 io_uring Showdown PyArrow CTD Aggregator.

Parses raw per-pass artifacts produced by ``benchmarks/run-iouring-showdown.sh``:
  - ``explain.json``       : PostgreSQL ``EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL, FORMAT JSON)``
  - ``pg_stat_io.json``    : Per-workload ``pg_stat_io`` snapshot (``WHERE reads > 0``)
  - ``perf_stat.json``     : ``perf stat -a -j`` hardware/software PMU counters
  - ``diskstats_before.txt`` / ``diskstats_after.txt``: Linux ``/proc/diskstats`` NVMe snapshots

Emits:
  - Concise Markdown ablation summary to stdout
  - CTD-aligned Zstd-compressed Parquet (``<out_dir>/<stem>.parquet``)
  - CTD-aligned Arrow IPC File (``<out_dir>/<stem>.arrow``)

Strictly uses ``pyarrow`` (``pyarrow.Table``, ``pyarrow.compute``, ``pyarrow.parquet``,
``pyarrow.ipc``) and the Python 3.12+ standard library.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.ipc as ipc
import pyarrow.parquet as pq

SCHEMA_VERSION = "drewv-ctd-benchmark/v1.0"
CTD_PILLAR = "runner"
CTD_COMPONENT = "benchmark:pg18-iouring-showdown"
CTD_STATUS_COMPLETE = "runner-end"
SECTOR_SIZE_BYTES = 512
DEFAULT_PG_BLOCK_BYTES = 8192

METHOD_SORT_ORDER: Mapping[str, int] = {
    "sync": 0,
    "worker": 1,
    "io_uring": 2,
}

ITER_DIR_RE = re.compile(r"^iter[_-]?(?P<iter>\d+)$")

PASS_DIR_RE = re.compile(
    r"^(?P<cache_mode>cold|warm)__"
    r"(?P<io_method>sync|worker|io_uring)__"
    r"eic(?P<eic>\d+)__"
    r"(?P<workload>[a-zA-Z0-9_-]+?)"
    r"(?:_+iter[_-]?(?P<iter>\d+))?$"
)

SHOWDOWN_SCHEMA: pa.Schema = pa.schema(
    [
        # CarrierPigeons CTD envelope alignment
        pa.field("schema_version", pa.string(), nullable=False),
        pa.field("run_id", pa.string(), nullable=False),
        pa.field("node_id", pa.string(), nullable=False),
        pa.field("pillar", pa.string(), nullable=False),
        pa.field("component", pa.string(), nullable=False),
        pa.field("status", pa.string(), nullable=False),
        pa.field("event_timestamp", pa.timestamp("us", tz="UTC"), nullable=False),
        # Silicon & host provenance
        pa.field("architecture", pa.string(), nullable=False),
        pa.field("kernel_release", pa.string(), nullable=False),
        pa.field("device_tree_model", pa.string(), nullable=False),
        pa.field("cpu_harts_count", pa.int32(), nullable=False),
        pa.field("pg_server_version", pa.string(), nullable=False),
        pa.field("db_name", pa.string(), nullable=False),
        pa.field("table_name", pa.string(), nullable=False),
        pa.field("nvme_device", pa.string(), nullable=False),
        # Ablation dimensions
        pa.field("cache_mode", pa.string(), nullable=False),
        pa.field("io_method", pa.string(), nullable=False),
        pa.field("effective_io_concurrency", pa.int32(), nullable=False),
        pa.field("io_workers", pa.int32(), nullable=False),
        pa.field("gather_workers", pa.int32(), nullable=False),
        pa.field("workload", pa.string(), nullable=False),
        # EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL, FORMAT JSON) metrics
        pa.field("top_node_type", pa.string(), nullable=False),
        pa.field("execution_time_ms", pa.float64(), nullable=False),
        pa.field("planning_time_ms", pa.float64(), nullable=False),
        pa.field("shared_hit_blocks", pa.int64(), nullable=False),
        pa.field("shared_read_blocks", pa.int64(), nullable=False),
        pa.field("shared_dirtied_blocks", pa.int64(), nullable=False),
        pa.field("shared_written_blocks", pa.int64(), nullable=False),
        pa.field("io_read_time_ms", pa.float64(), nullable=False),
        pa.field("io_write_time_ms", pa.float64(), nullable=False),
        pa.field("wal_records", pa.int64(), nullable=False),
        pa.field("wal_fpi", pa.int64(), nullable=False),
        pa.field("wal_bytes", pa.int64(), nullable=False),
        # pg_stat_io aggregates
        pa.field("pg_stat_io_reads", pa.int64(), nullable=False),
        pa.field("pg_stat_io_read_bytes", pa.int64(), nullable=False),
        pa.field("pg_stat_io_read_time_ms", pa.float64(), nullable=False),
        pa.field("pg_stat_io_hits", pa.int64(), nullable=False),
        pa.field("pg_stat_io_writes", pa.int64(), nullable=False),
        pa.field("pg_stat_io_write_bytes", pa.int64(), nullable=False),
        pa.field("pg_stat_io_write_time_ms", pa.float64(), nullable=False),
        pa.field("pg_stat_io_io_worker_reads", pa.int64(), nullable=False),
        # perf stat -j PMU counters
        pa.field("perf_cycles", pa.int64(), nullable=True),
        pa.field("perf_instructions", pa.int64(), nullable=True),
        pa.field("perf_ipc", pa.float64(), nullable=True),
        pa.field("perf_context_switches", pa.int64(), nullable=True),
        pa.field("perf_cpu_migrations", pa.int64(), nullable=True),
        pa.field("perf_l1_dcache_load_misses", pa.int64(), nullable=True),
        pa.field("perf_llc_load_misses", pa.int64(), nullable=True),
        pa.field("perf_dtlb_load_misses", pa.int64(), nullable=True),
        # /proc/diskstats NVMe deltas
        pa.field("disk_reads_completed", pa.int64(), nullable=True),
        pa.field("disk_sectors_read", pa.int64(), nullable=True),
        pa.field("disk_read_bytes", pa.int64(), nullable=True),
        pa.field("disk_read_time_ms", pa.int64(), nullable=True),
        pa.field("disk_writes_completed", pa.int64(), nullable=True),
        pa.field("disk_sectors_written", pa.int64(), nullable=True),
        pa.field("disk_write_bytes", pa.int64(), nullable=True),
        pa.field("disk_write_time_ms", pa.int64(), nullable=True),
        pa.field("disk_io_time_ms", pa.int64(), nullable=True),
        pa.field("disk_weighted_io_time_ms", pa.int64(), nullable=True),
        # Vectorized pyarrow.compute derived columns
        pa.field("nvme_read_mib_s", pa.float64(), nullable=True),
        pa.field("speedup_vs_sync", pa.float64(), nullable=True),
        # Rigor, iteration, direct-I/O, plan-shape, and PMU multiplexing extensions
        pa.field("iteration", pa.int32(), nullable=False),
        pa.field("io_direct", pa.string(), nullable=False),
        pa.field("wall_duration_ms", pa.float64(), nullable=True),
        pa.field("pg_io_read_mib_s", pa.float64(), nullable=True),
        pa.field("plan_shape_valid", pa.bool_(), nullable=False),
        pa.field("perf_pmu_multiplexed", pa.bool_(), nullable=False),
        pa.field("perf_min_pcnt_running", pa.float64(), nullable=True),
    ]
)


@dataclass(frozen=True, slots=True)
class ExplainMetrics:
    """Structured metrics extracted from PostgreSQL EXPLAIN FORMAT JSON."""

    execution_time_ms: float
    planning_time_ms: float
    shared_hit_blocks: int
    shared_read_blocks: int
    shared_dirtied_blocks: int
    shared_written_blocks: int
    io_read_time_ms: float
    io_write_time_ms: float
    wal_records: int
    wal_fpi: int
    wal_bytes: int
    top_node_type: str
    plan_node_types: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class PgStatIOMetrics:
    """Aggregated counters from a per-workload pg_stat_io snapshot."""

    reads: int
    read_bytes: int
    read_time_ms: float
    hits: int
    writes: int
    write_bytes: int
    write_time_ms: float
    io_worker_reads: int


@dataclass(frozen=True, slots=True)
class PerfMetrics:
    """Hardware and software PMU counters parsed from perf stat -j output."""

    cycles: int | None
    instructions: int | None
    ipc: float | None
    context_switches: int | None
    cpu_migrations: int | None
    l1_dcache_load_misses: int | None
    llc_load_misses: int | None
    dtlb_load_misses: int | None
    pmu_multiplexed: bool = False
    min_pcnt_running: float | None = None


@dataclass(frozen=True, slots=True)
class DiskStatsDelta:
    """Per-pass block device I/O counter deltas from /proc/diskstats."""

    device: str | None
    reads_completed: int | None
    sectors_read: int | None
    read_bytes: int | None
    read_time_ms: int | None
    writes_completed: int | None
    sectors_written: int | None
    write_bytes: int | None
    write_time_ms: int | None
    io_time_ms: int | None
    weighted_io_time_ms: int | None


@dataclass(frozen=True, slots=True)
class RunMetadata:
    """Run-level CTD provenance metadata captured by run-iouring-showdown.sh."""

    schema_version: str
    run_id: str
    node_id: str
    pillar: str
    component: str
    captured_at_utc: str
    architecture: str
    kernel_release: str
    device_tree_model: str
    cpu_harts_count: int
    pg_server_version: str
    db_name: str
    table_name: str
    nvme_device: str
    nvme_short: str


@runtime_checkable
class CTDShowdownRecord(Protocol):
    """Structural contract for a CarrierPigeons-aligned benchmark telemetry row."""

    @property
    def schema_version(self) -> str: ...
    @property
    def run_id(self) -> str: ...
    @property
    def node_id(self) -> str: ...
    @property
    def pillar(self) -> str: ...
    @property
    def component(self) -> str: ...
    @property
    def status(self) -> str: ...
    @property
    def event_timestamp(self) -> datetime.datetime: ...
    @property
    def cache_mode(self) -> str: ...
    @property
    def io_method(self) -> str: ...
    @property
    def effective_io_concurrency(self) -> int: ...
    @property
    def workload(self) -> str: ...
    @property
    def execution_time_ms(self) -> float: ...


class ExplainParser(Protocol):
    """Protocol for parsing PostgreSQL EXPLAIN JSON files."""

    def parse(self, path: Path) -> ExplainMetrics: ...


class PgStatIOParser(Protocol):
    """Protocol for parsing pg_stat_io JSON snapshot files."""

    def parse(self, path: Path) -> PgStatIOMetrics: ...


class PerfStatParser(Protocol):
    """Protocol for parsing perf stat -j NDJSON/JSON files."""

    def parse(self, path: Path) -> PerfMetrics: ...


class DiskStatsParser(Protocol):
    """Protocol for computing /proc/diskstats deltas across a pass."""

    def parse(
        self,
        before_path: Path,
        after_path: Path,
        device: str | None = None,
    ) -> DiskStatsDelta: ...


class ArtifactSink(Protocol):
    """Protocol for persisting an Arrow showdown table to disk."""

    def write(self, table: pa.Table, out_dir: Path, stem: str) -> Path: ...


@dataclass(frozen=True, slots=True)
class ShowdownPassRow:
    """Single aggregated (cache_mode, io_method, concurrency, workload, iteration) pass."""

    schema_version: str
    run_id: str
    node_id: str
    pillar: str
    component: str
    status: str
    event_timestamp: datetime.datetime
    architecture: str
    kernel_release: str
    device_tree_model: str
    cpu_harts_count: int
    pg_server_version: str
    db_name: str
    table_name: str
    nvme_device: str
    cache_mode: str
    io_method: str
    effective_io_concurrency: int
    io_workers: int
    gather_workers: int
    workload: str
    explain: ExplainMetrics
    pg_stat_io: PgStatIOMetrics
    perf: PerfMetrics
    diskstats: DiskStatsDelta
    iteration: int = 1
    io_direct: str = "off"
    wall_duration_ms: float | None = None
    plan_shape_valid: bool = True

    @property
    def execution_time_ms(self) -> float:
        return self.explain.execution_time_ms


@dataclass(frozen=True, slots=True)
class MethodLatencySummary:
    """Aggregated pyarrow.compute latency summary for a method/EIC/direct-IO group."""

    cache_mode: str
    workload: str
    io_method: str
    effective_io_concurrency: int
    io_direct: str
    n: int
    min_ms: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    mean_ms: float
    stddev_ms: float
    max_ms: float

    @property
    def pass_count(self) -> int:
        return self.n


@dataclass(frozen=True, slots=True)
class ShowdownArtifacts:
    """Complete output bundle produced by analyze_showdown_run."""

    table: pa.Table
    parquet_path: Path
    arrow_path: Path
    markdown: str
    provenance_sha256: str


def _parse_iso_utc(raw: str | None) -> datetime.datetime:
    if not raw:
        return datetime.datetime.now(datetime.UTC)
    normalized = raw.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(normalized)
    except ValueError:
        return datetime.datetime.now(datetime.UTC)
    if dt.tzinfo is None:
        return dt.replace(tzinfo=datetime.UTC)
    return dt.astimezone(datetime.UTC)


def _as_int(value: Any, default: int = 0) -> int:
    if value is None or isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(round(value))
    if isinstance(value, str):
        cleaned = value.strip().replace(",", "")
        if not cleaned:
            return default
        try:
            return int(round(float(cleaned)))
        except ValueError:
            return default
    return default


def _as_float(value: Any, default: float = 0.0) -> float:
    if value is None or isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        cleaned = value.strip().replace(",", "")
        if not cleaned:
            return default
        try:
            return float(cleaned)
        except ValueError:
            return default
    return default


def _extract_plan_numeric(
    plan_node: Mapping[str, Any],
    candidate_keys: Sequence[str],
) -> float:
    """Extract a cumulative EXPLAIN Plan metric without double-counting child nodes."""
    for key in candidate_keys:
        if key in plan_node and plan_node[key] is not None:
            return _as_float(plan_node[key], 0.0)
    children = plan_node.get("Plans")
    if isinstance(children, list):
        total = 0.0
        for child in children:
            if isinstance(child, Mapping):
                total += _extract_plan_numeric(child, candidate_keys)
        return total
    return 0.0


def _collect_plan_node_types(plan_node: Mapping[str, Any]) -> tuple[str, ...]:
    """Recursively collect all PostgreSQL plan Node Type names in a plan tree."""
    node_types: list[str] = []
    raw_type = plan_node.get("Node Type")
    if isinstance(raw_type, str) and raw_type.strip():
        node_types.append(raw_type.strip())
    children = plan_node.get("Plans")
    if isinstance(children, list):
        for child in children:
            if isinstance(child, Mapping):
                node_types.extend(_collect_plan_node_types(child))
    return tuple(node_types)


def validate_plan_shape(workload: str, explain: ExplainMetrics) -> bool:
    """Assert that EXPLAIN plan nodes match the expected scan shape for a workload."""
    nodes = set(explain.plan_node_types)
    if explain.top_node_type:
        nodes.add(explain.top_node_type)
    wl_norm = workload.strip().lower()
    if wl_norm == "seq_scan" or wl_norm.startswith("seq_scan"):
        return "Parallel Seq Scan" in nodes or "Seq Scan" in nodes
    if wl_norm == "bitmap_heap_scan" or wl_norm.startswith("bitmap_heap_scan"):
        return "Bitmap Heap Scan" in nodes
    return explain.top_node_type != "Unknown"


def parse_explain_json(path: Path) -> ExplainMetrics:
    """Parse PostgreSQL EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL, FORMAT JSON) output."""
    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        raise ValueError(f"Empty EXPLAIN JSON artifact: {path}")

    # Strip any stray non-JSON command tags (e.g. 'SET') before the JSON payload
    start_idx = min(
        (idx for idx in (raw.find("["), raw.find("{")) if idx != -1),
        default=-1,
    )
    if start_idx == -1:
        raise ValueError(f"No JSON payload found in EXPLAIN artifact: {path}")
    payload: Any = json.loads(raw[start_idx:])

    if isinstance(payload, list):
        if not payload or not isinstance(payload[0], Mapping):
            raise ValueError(f"Unexpected EXPLAIN JSON array structure: {path}")
        doc: Mapping[str, Any] = payload[0]
    elif isinstance(payload, Mapping):
        doc = payload
    else:
        raise ValueError(f"Unexpected EXPLAIN JSON root type in {path}")

    plan_obj = doc.get("Plan")
    plan: Mapping[str, Any] = plan_obj if isinstance(plan_obj, Mapping) else {}

    execution_time_ms = _as_float(doc.get("Execution Time"), 0.0)
    if execution_time_ms == 0.0 and "Actual Total Time" in plan:
        execution_time_ms = _as_float(plan.get("Actual Total Time"), 0.0)

    planning_time_ms = _as_float(doc.get("Planning Time"), 0.0)

    shared_hit = int(round(_extract_plan_numeric(plan, ("Shared Hit Blocks",))))
    shared_read = int(round(_extract_plan_numeric(plan, ("Shared Read Blocks",))))
    shared_dirtied = int(round(_extract_plan_numeric(plan, ("Shared Dirtied Blocks",))))
    shared_written = int(round(_extract_plan_numeric(plan, ("Shared Written Blocks",))))

    # PostgreSQL 17/18 emits "Shared I/O Read Time"; PG <=16 and legacy fixtures use "I/O Read Time"
    io_read_time_ms = _extract_plan_numeric(
        plan,
        ("Shared I/O Read Time", "I/O Read Time"),
    )
    io_write_time_ms = _extract_plan_numeric(
        plan,
        ("Shared I/O Write Time", "I/O Write Time"),
    )

    wal_records = int(round(_extract_plan_numeric(plan, ("WAL Records",))))
    wal_fpi = int(round(_extract_plan_numeric(plan, ("WAL FPI",))))
    wal_bytes = int(round(_extract_plan_numeric(plan, ("WAL Bytes",))))
    top_node_type = str(plan.get("Node Type", "Unknown"))
    plan_node_types = _collect_plan_node_types(plan)

    return ExplainMetrics(
        execution_time_ms=execution_time_ms,
        planning_time_ms=planning_time_ms,
        shared_hit_blocks=shared_hit,
        shared_read_blocks=shared_read,
        shared_dirtied_blocks=shared_dirtied,
        shared_written_blocks=shared_written,
        io_read_time_ms=io_read_time_ms,
        io_write_time_ms=io_write_time_ms,
        wal_records=wal_records,
        wal_fpi=wal_fpi,
        wal_bytes=wal_bytes,
        top_node_type=top_node_type,
        plan_node_types=plan_node_types,
    )


def parse_pg_stat_io_json(path: Path) -> PgStatIOMetrics:
    """Parse a per-workload pg_stat_io JSON snapshot."""
    if not path.is_file():
        return PgStatIOMetrics(0, 0, 0.0, 0, 0, 0, 0.0, 0)
    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        return PgStatIOMetrics(0, 0, 0.0, 0, 0, 0, 0.0, 0)

    parsed: Any = json.loads(raw)
    if isinstance(parsed, Mapping) and isinstance(parsed.get("rows"), list):
        rows: list[Any] = parsed["rows"]
    elif isinstance(parsed, list):
        rows = parsed
    else:
        return PgStatIOMetrics(0, 0, 0.0, 0, 0, 0, 0.0, 0)

    reads = 0
    read_bytes = 0
    read_time_ms = 0.0
    hits = 0
    writes = 0
    write_bytes = 0
    write_time_ms = 0.0
    io_worker_reads = 0

    for item in rows:
        if not isinstance(item, Mapping):
            continue
        row_reads = _as_int(item.get("reads"), 0)
        row_writes = _as_int(item.get("writes"), 0)
        op_bytes = _as_int(item.get("op_bytes"), DEFAULT_PG_BLOCK_BYTES)

        reads += row_reads
        if item.get("read_bytes") is not None:
            read_bytes += _as_int(item.get("read_bytes"), 0)
        else:
            read_bytes += row_reads * op_bytes
        read_time_ms += _as_float(item.get("read_time"), 0.0)
        hits += _as_int(item.get("hits"), 0)

        writes += row_writes
        if item.get("write_bytes") is not None:
            write_bytes += _as_int(item.get("write_bytes"), 0)
        else:
            write_bytes += row_writes * op_bytes
        write_time_ms += _as_float(item.get("write_time"), 0.0)

        backend = str(item.get("backend_type", "")).strip().lower()
        if backend == "io worker":
            io_worker_reads += row_reads

    return PgStatIOMetrics(
        reads=reads,
        read_bytes=read_bytes,
        read_time_ms=round(read_time_ms, 6),
        hits=hits,
        writes=writes,
        write_bytes=write_bytes,
        write_time_ms=round(write_time_ms, 6),
        io_worker_reads=io_worker_reads,
    )


def _canonical_perf_event(raw_event: str) -> str:
    ev = raw_event.strip()
    if "/" in ev and ev.endswith("/"):
        # e.g., cpu_core/cycles/ -> cycles
        parts = ev.strip("/").split("/")
        if len(parts) >= 2:
            ev = parts[1]
    ev = ev.split(":", 1)[0].strip().lower()
    aliases: Mapping[str, str] = {
        "cpu-cycles": "cycles",
        "cs": "context-switches",
        "migrations": "cpu-migrations",
    }
    return aliases.get(ev, ev)


def _parse_perf_counter(raw_val: Any) -> int | None:
    if raw_val is None or isinstance(raw_val, bool):
        return None
    if isinstance(raw_val, int):
        return raw_val
    if isinstance(raw_val, float):
        return int(round(raw_val))
    if isinstance(raw_val, str):
        cleaned = raw_val.strip()
        if not cleaned or cleaned.startswith("<"):
            return None
        cleaned = cleaned.replace(",", "")
        try:
            return int(round(float(cleaned)))
        except ValueError:
            return None
    return None


def parse_perf_stat_json(path: Path) -> PerfMetrics:
    """Parse perf stat -j NDJSON (or JSON array) into structured PMU counters."""
    if not path.is_file():
        return PerfMetrics(None, None, None, None, None, None, None, None)

    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        return PerfMetrics(None, None, None, None, None, None, None, None)

    records: list[Mapping[str, Any]] = []
    if raw.startswith("["):
        loaded: Any = json.loads(raw)
        if isinstance(loaded, list):
            records = [item for item in loaded if isinstance(item, Mapping)]
    else:
        for line in raw.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            try:
                obj: Any = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, Mapping):
                records.append(obj)

    counters: dict[str, int] = {}
    reported_ipc: float | None = None
    pcnt_running_values: list[float] = []

    for rec in records:
        metric_unit = str(rec.get("metric-unit", "")).strip().lower()
        if "insn per cycle" in metric_unit and rec.get("metric-value") is not None:
            parsed_ipc = _as_float(rec.get("metric-value"), -1.0)
            if parsed_ipc >= 0.0:
                reported_ipc = round(parsed_ipc, 6)

        event_raw = rec.get("event")
        if not isinstance(event_raw, str) or not event_raw.strip():
            continue
        event_name = _canonical_perf_event(event_raw)
        raw_counter = rec.get("counter-value")
        val = _parse_perf_counter(raw_counter)
        if val is not None:
            counters[event_name] = counters.get(event_name, 0) + val

        is_not_supported = (
            isinstance(raw_counter, str)
            and raw_counter.strip().lower().startswith("<not supported")
        )
        raw_pcnt = rec.get("pcnt-running")
        if not is_not_supported and raw_pcnt is not None and not isinstance(raw_pcnt, bool):
            pcnt_val = _as_float(raw_pcnt, -1.0)
            if 0.0 <= pcnt_val <= 100.0:
                pcnt_running_values.append(pcnt_val)

    cycles = counters.get("cycles")
    instructions = counters.get("instructions")
    ipc_val: float | None
    if cycles is not None and cycles > 0 and instructions is not None:
        ipc_val = round(instructions / cycles, 6)
    else:
        ipc_val = reported_ipc

    min_pcnt_running: float | None = (
        round(min(pcnt_running_values), 2) if pcnt_running_values else None
    )
    pmu_multiplexed = min_pcnt_running is not None and min_pcnt_running < 100.0

    return PerfMetrics(
        cycles=cycles,
        instructions=instructions,
        ipc=ipc_val,
        context_switches=counters.get("context-switches"),
        cpu_migrations=counters.get("cpu-migrations"),
        l1_dcache_load_misses=counters.get("l1-dcache-load-misses"),
        llc_load_misses=counters.get("llc-load-misses"),
        dtlb_load_misses=counters.get("dtlb-load-misses"),
        pmu_multiplexed=pmu_multiplexed,
        min_pcnt_running=min_pcnt_running,
    )


def _parse_diskstats_line(path: Path, device: str | None = None) -> tuple[str, list[int]] | None:
    if not path.is_file():
        return None
    lines = [ln.strip() for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
    if not lines:
        return None

    target_line: list[str] | None = None
    for line in lines:
        parts = line.split()
        if len(parts) < 14:
            continue
        if device is None or parts[2] == device:
            target_line = parts
            break

    if target_line is None:
        return None

    try:
        numeric = [int(tok) for tok in target_line[3:14]]
    except ValueError:
        return None
    return (target_line[2], numeric)


def _counter_delta(before: int, after: int) -> int | None:
    delta = after - before
    return delta if delta >= 0 else None


def parse_diskstats_delta(
    before_path: Path,
    after_path: Path,
    device: str | None = None,
) -> DiskStatsDelta:
    """Compute per-pass block I/O deltas from before/after /proc/diskstats snapshots."""
    before_parsed = _parse_diskstats_line(before_path, device=device)
    after_parsed = _parse_diskstats_line(after_path, device=device)
    if before_parsed is None or after_parsed is None:
        return DiskStatsDelta(
            device=device,
            reads_completed=None,
            sectors_read=None,
            read_bytes=None,
            read_time_ms=None,
            writes_completed=None,
            sectors_written=None,
            write_bytes=None,
            write_time_ms=None,
            io_time_ms=None,
            weighted_io_time_ms=None,
        )

    dev_name, b = before_parsed
    _, a = after_parsed

    # /proc/diskstats fields after device name (index 3..13 -> 0..10 in sliced list):
    # 0: reads_completed, 1: reads_merged, 2: sectors_read, 3: read_time_ms,
    # 4: writes_completed, 5: writes_merged, 6: sectors_written, 7: write_time_ms,
    # 8: ios_in_progress, 9: io_time_ms, 10: weighted_io_time_ms
    reads_completed = _counter_delta(b[0], a[0])
    sectors_read = _counter_delta(b[2], a[2])
    read_bytes = sectors_read * SECTOR_SIZE_BYTES if sectors_read is not None else None
    read_time_ms = _counter_delta(b[3], a[3])

    writes_completed = _counter_delta(b[4], a[4])
    sectors_written = _counter_delta(b[6], a[6])
    write_bytes = sectors_written * SECTOR_SIZE_BYTES if sectors_written is not None else None
    write_time_ms = _counter_delta(b[7], a[7])

    io_time_ms = _counter_delta(b[9], a[9])
    weighted_io_time_ms = _counter_delta(b[10], a[10])

    return DiskStatsDelta(
        device=dev_name,
        reads_completed=reads_completed,
        sectors_read=sectors_read,
        read_bytes=read_bytes,
        read_time_ms=read_time_ms,
        writes_completed=writes_completed,
        sectors_written=sectors_written,
        write_bytes=write_bytes,
        write_time_ms=write_time_ms,
        io_time_ms=io_time_ms,
        weighted_io_time_ms=weighted_io_time_ms,
    )


class DefaultExplainParser:
    """Default EXPLAIN JSON parser implementing ExplainParser."""

    def parse(self, path: Path) -> ExplainMetrics:
        return parse_explain_json(path)


class DefaultPgStatIOParser:
    """Default pg_stat_io JSON parser implementing PgStatIOParser."""

    def parse(self, path: Path) -> PgStatIOMetrics:
        return parse_pg_stat_io_json(path)


class DefaultPerfStatParser:
    """Default perf stat -j parser implementing PerfStatParser."""

    def parse(self, path: Path) -> PerfMetrics:
        return parse_perf_stat_json(path)


class DefaultDiskStatsParser:
    """Default /proc/diskstats delta parser implementing DiskStatsParser."""

    def parse(
        self,
        before_path: Path,
        after_path: Path,
        device: str | None = None,
    ) -> DiskStatsDelta:
        return parse_diskstats_delta(before_path, after_path, device=device)


class ParquetZstdSink:
    """Atomic Zstd-compressed Parquet writer implementing ArtifactSink."""

    def write(self, table: pa.Table, out_dir: Path, stem: str) -> Path:
        out_dir.mkdir(parents=True, exist_ok=True)
        target = out_dir / f"{stem}.parquet"
        fd, tmp_name = tempfile.mkstemp(prefix=f".{stem}.", suffix=".parquet.tmp", dir=out_dir)
        os.close(fd)
        tmp_path = Path(tmp_name)
        try:
            pq.write_table(table, tmp_path, compression="zstd")
            os.replace(tmp_path, target)
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise
        return target


class ArrowIPCSink:
    """Atomic Arrow IPC file format (.arrow) writer implementing ArtifactSink."""

    def write(self, table: pa.Table, out_dir: Path, stem: str) -> Path:
        out_dir.mkdir(parents=True, exist_ok=True)
        target = out_dir / f"{stem}.arrow"
        fd, tmp_name = tempfile.mkstemp(prefix=f".{stem}.", suffix=".arrow.tmp", dir=out_dir)
        os.close(fd)
        tmp_path = Path(tmp_name)
        try:
            with pa.OSFile(str(tmp_path), "wb") as sink:
                with ipc.new_file(sink, table.schema) as writer:
                    writer.write_table(table)
            os.replace(tmp_path, target)
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise
        return target


def load_run_metadata(run_dir: Path) -> RunMetadata:
    """Load run-level metadata.json with safe defaults if fields are absent."""
    meta_path = run_dir / "metadata.json"
    raw: Mapping[str, Any] = {}
    if meta_path.is_file():
        loaded: Any = json.loads(meta_path.read_text(encoding="utf-8"))
        if isinstance(loaded, Mapping):
            raw = loaded

    nvme_device = str(raw.get("nvme_device", "/dev/nvme0n1"))
    nvme_short = str(raw.get("nvme_short") or Path(nvme_device).name)

    return RunMetadata(
        schema_version=str(raw.get("schema_version", SCHEMA_VERSION)),
        run_id=str(raw.get("run_id") or run_dir.name),
        node_id=str(raw.get("node_id", "unknown-node")),
        pillar=str(raw.get("pillar", CTD_PILLAR)),
        component=str(raw.get("component", CTD_COMPONENT)),
        captured_at_utc=str(
            raw.get("captured_at_utc") or datetime.datetime.now(datetime.UTC).isoformat()
        ),
        architecture=str(raw.get("architecture", "unknown")),
        kernel_release=str(raw.get("kernel_release", "unknown")),
        device_tree_model=str(raw.get("device_tree_model", "unknown")),
        cpu_harts_count=_as_int(raw.get("cpu_harts_count"), 0),
        pg_server_version=str(raw.get("pg_server_version", "unknown")),
        db_name=str(raw.get("db_name", "brakerrak")),
        table_name=str(raw.get("table_name", "brakerrak_io_torture")),
        nvme_device=nvme_device,
        nvme_short=nvme_short,
    )


def load_showdown_passes(
    run_dir: Path,
    *,
    explain_parser: ExplainParser | None = None,
    pg_stat_io_parser: PgStatIOParser | None = None,
    perf_parser: PerfStatParser | None = None,
    diskstats_parser: DiskStatsParser | None = None,
) -> tuple[RunMetadata, list[ShowdownPassRow]]:
    """Discover and parse all per-pass artifact directories under ``run_dir``."""
    if not run_dir.is_dir():
        raise FileNotFoundError(f"Benchmark run directory does not exist: {run_dir}")

    meta = load_run_metadata(run_dir)
    ex_p = explain_parser or DefaultExplainParser()
    io_p = pg_stat_io_parser or DefaultPgStatIOParser()
    pf_p = perf_parser or DefaultPerfStatParser()
    ds_p = diskstats_parser or DefaultDiskStatsParser()

    passes_root = run_dir / "passes"
    if not passes_root.is_dir():
        passes_root = run_dir

    discovered: list[tuple[int | None, Path]] = []
    for entry in sorted(passes_root.iterdir()):
        if not entry.is_dir():
            continue
        if (entry / "explain.json").is_file():
            discovered.append((None, entry))
            continue
        iter_match = ITER_DIR_RE.match(entry.name)
        parent_iter = int(iter_match.group("iter")) if iter_match else None
        for sub_entry in sorted(entry.iterdir()):
            if sub_entry.is_dir() and (sub_entry / "explain.json").is_file():
                discovered.append((parent_iter, sub_entry))

    if not discovered:
        raise FileNotFoundError(
            f"No benchmark pass directories with explain.json found under: {passes_root}"
        )

    rows: list[ShowdownPassRow] = []
    for parent_iter, pdir in discovered:
        pmeta_path = pdir / "pass_meta.json"
        pmeta: Mapping[str, Any] = {}
        if pmeta_path.is_file():
            loaded: Any = json.loads(pmeta_path.read_text(encoding="utf-8"))
            if isinstance(loaded, Mapping):
                pmeta = loaded

        dir_match = PASS_DIR_RE.match(pdir.name)
        cache_mode = str(
            pmeta.get("cache_mode") or (dir_match.group("cache_mode") if dir_match else "cold")
        )
        io_method = str(
            pmeta.get("io_method") or (dir_match.group("io_method") if dir_match else "unknown")
        )
        eic = _as_int(
            pmeta.get("effective_io_concurrency"),
            int(dir_match.group("eic")) if dir_match else 0,
        )
        workload = str(
            pmeta.get("workload") or (dir_match.group("workload") if dir_match else pdir.name)
        )
        dir_iter = (
            int(dir_match.group("iter")) if (dir_match and dir_match.group("iter")) else None
        )
        default_iter = (
            parent_iter if parent_iter is not None else (dir_iter if dir_iter is not None else 1)
        )
        iteration = _as_int(pmeta.get("iteration"), default_iter)
        if iteration < 1:
            iteration = 1

        raw_io_direct = str(pmeta.get("io_direct", "")).strip()
        if raw_io_direct:
            io_direct = raw_io_direct
        elif bool(pmeta.get("with_direct_io")):
            io_direct = "data"
        else:
            io_direct = "off"

        raw_wall = pmeta.get("wall_duration_ms")
        wall_duration_ms: float | None = None
        if raw_wall is not None and not isinstance(raw_wall, bool):
            parsed_wall = _as_float(raw_wall, -1.0)
            if parsed_wall > 0.0:
                wall_duration_ms = parsed_wall

        io_workers = _as_int(pmeta.get("io_workers"), 0)
        gather_workers = _as_int(pmeta.get("gather_workers"), 0)
        nvme_short = str(pmeta.get("nvme_short") or meta.nvme_short)

        event_ts = _parse_iso_utc(
            str(pmeta.get("finished_at_utc") or pmeta.get("started_at_utc") or meta.captured_at_utc)
        )

        explain_metrics = ex_p.parse(pdir / "explain.json")
        plan_shape_valid = validate_plan_shape(workload, explain_metrics)
        pg_stat_io_metrics = io_p.parse(pdir / "pg_stat_io.json")

        perf_path = pdir / "perf_stat.json"
        if not perf_path.is_file():
            perf_path = pdir / "perf_stat.jsonl"
        perf_metrics = pf_p.parse(perf_path)

        disk_delta = ds_p.parse(
            pdir / "diskstats_before.txt",
            pdir / "diskstats_after.txt",
            device=nvme_short or None,
        )

        rows.append(
            ShowdownPassRow(
                schema_version=meta.schema_version,
                run_id=str(pmeta.get("run_id") or meta.run_id),
                node_id=str(pmeta.get("node_id") or meta.node_id),
                pillar=meta.pillar,
                component=meta.component,
                status=CTD_STATUS_COMPLETE,
                event_timestamp=event_ts,
                architecture=meta.architecture,
                kernel_release=meta.kernel_release,
                device_tree_model=meta.device_tree_model,
                cpu_harts_count=meta.cpu_harts_count,
                pg_server_version=meta.pg_server_version,
                db_name=meta.db_name,
                table_name=meta.table_name,
                nvme_device=meta.nvme_device,
                cache_mode=cache_mode,
                io_method=io_method,
                effective_io_concurrency=eic,
                io_workers=io_workers,
                gather_workers=gather_workers,
                workload=workload,
                explain=explain_metrics,
                pg_stat_io=pg_stat_io_metrics,
                perf=perf_metrics,
                diskstats=disk_delta,
                iteration=iteration,
                io_direct=io_direct,
                wall_duration_ms=wall_duration_ms,
                plan_shape_valid=plan_shape_valid,
            )
        )

    return meta, rows


def _compute_canonical_digest(table: pa.Table) -> str:
    """Compute canonical SHA-256 provenance digest across sorted row payloads."""
    raw_rows: list[dict[str, Any]] = table.to_pylist()
    canonical_rows: list[dict[str, Any]] = []
    for row in raw_rows:
        encoded: dict[str, Any] = {}
        for k, v in row.items():
            if isinstance(v, datetime.datetime):
                encoded[k] = v.astimezone(datetime.UTC).isoformat()
            else:
                encoded[k] = v
        canonical_rows.append(encoded)
    canonical_bytes = json.dumps(
        canonical_rows,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical_bytes).hexdigest()


def _arrow_scalar_float(scalar: Any) -> float | None:
    if scalar is None:
        return None
    py_val = scalar.as_py()
    if py_val is None:
        return None
    if isinstance(py_val, (int, float)):
        return float(py_val)
    return None


def _compute_speedup_column(table: pa.Table) -> pa.Array:
    """Compute speedup vs sync baseline per (cache_mode, workload, io_direct)."""
    cache_modes: list[str] = [str(v) for v in table["cache_mode"].to_pylist()]
    workloads: list[str] = [str(v) for v in table["workload"].to_pylist()]
    eics: list[int] = [int(v) for v in table["effective_io_concurrency"].to_pylist()]
    if "io_direct" in table.column_names:
        io_directs: list[str] = [str(v) for v in table["io_direct"].to_pylist()]
    else:
        io_directs = ["off"] * table.num_rows

    # Precompute sync baseline per (cache_mode, workload, io_direct, eic) and fallbacks
    exact_direct_baselines: dict[tuple[str, str, str, int], float] = {}
    zero_direct_baselines: dict[tuple[str, str, str], float] = {}
    group_direct_baselines: dict[tuple[str, str, str], float] = {}
    exact_baselines: dict[tuple[str, str, int], float] = {}
    zero_baselines: dict[tuple[str, str], float] = {}
    group_baselines: dict[tuple[str, str], float] = {}

    sync_mask = pc.equal(table["io_method"], "sync")
    for cm, wl in sorted(set(zip(cache_modes, workloads, strict=True))):
        group_mask = pc.and_(
            pc.and_(
                pc.equal(table["cache_mode"], cm),
                pc.equal(table["workload"], wl),
            ),
            sync_mask,
        )
        sync_group = table.filter(group_mask)
        if sync_group.num_rows == 0:
            continue

        mean_val = _arrow_scalar_float(pc.mean(sync_group["execution_time_ms"]))
        if mean_val is not None and mean_val > 0.0:
            group_baselines[(cm, wl)] = mean_val

        sync_eics = sorted(
            {int(v) for v in sync_group["effective_io_concurrency"].to_pylist()}
        )
        for sync_eic in sync_eics:
            eic_scalar = pa.scalar(sync_eic, type=pa.int32())
            eic_sub = sync_group.filter(
                pc.equal(sync_group["effective_io_concurrency"], eic_scalar)
            )
            eic_mean = _arrow_scalar_float(pc.mean(eic_sub["execution_time_ms"]))
            if eic_mean is not None and eic_mean > 0.0:
                exact_baselines[(cm, wl, sync_eic)] = eic_mean
                if sync_eic == 0:
                    zero_baselines[(cm, wl)] = eic_mean

        if "io_direct" in sync_group.column_names:
            direct_vals = sorted({str(v) for v in sync_group["io_direct"].to_pylist()})
            for d_val in direct_vals:
                d_sub = sync_group.filter(pc.equal(sync_group["io_direct"], d_val))
                d_mean = _arrow_scalar_float(pc.mean(d_sub["execution_time_ms"]))
                if d_mean is not None and d_mean > 0.0:
                    group_direct_baselines[(cm, wl, d_val)] = d_mean
                for sync_eic in sync_eics:
                    eic_scalar = pa.scalar(sync_eic, type=pa.int32())
                    de_sub = d_sub.filter(
                        pc.equal(d_sub["effective_io_concurrency"], eic_scalar)
                    )
                    if de_sub.num_rows == 0:
                        continue
                    de_mean = _arrow_scalar_float(pc.mean(de_sub["execution_time_ms"]))
                    if de_mean is not None and de_mean > 0.0:
                        exact_direct_baselines[(cm, wl, d_val, sync_eic)] = de_mean
                        if sync_eic == 0:
                            zero_direct_baselines[(cm, wl, d_val)] = de_mean

    baseline_per_row: list[float | None] = []
    for cm, wl, d_val, eic in zip(cache_modes, workloads, io_directs, eics, strict=True):
        baseline = (
            exact_direct_baselines.get((cm, wl, d_val, eic))
            or zero_direct_baselines.get((cm, wl, d_val))
            or group_direct_baselines.get((cm, wl, d_val))
            or exact_baselines.get((cm, wl, eic))
            or zero_baselines.get((cm, wl))
            or group_baselines.get((cm, wl))
        )
        baseline_per_row.append(baseline)

    baseline_arr = pa.array(baseline_per_row, type=pa.float64())
    exec_arr = table["execution_time_ms"]
    valid_denom = pc.and_kleene(
        pc.is_valid(baseline_arr),
        pc.greater(exec_arr, pa.scalar(0.0, type=pa.float64())),
    )
    safe_denom = pc.if_else(valid_denom, exec_arr, pa.scalar(1.0, type=pa.float64()))
    raw_speedup = pc.divide(baseline_arr, safe_denom)
    return pc.if_else(valid_denom, pc.round(raw_speedup, 4), pa.scalar(None, type=pa.float64()))


def build_showdown_table(
    meta: RunMetadata,
    rows: Sequence[ShowdownPassRow],
) -> tuple[pa.Table, str]:
    """Build a sorted, CTD-annotated PyArrow Table using pyarrow.compute derivations."""
    sorted_rows = sorted(
        rows,
        key=lambda r: (
            0 if r.cache_mode == "cold" else 1,
            r.workload,
            r.effective_io_concurrency,
            METHOD_SORT_ORDER.get(r.io_method, 99),
            r.io_method,
            r.io_direct,
            r.iteration,
        ),
    )

    columns: dict[str, list[Any]] = {
        "schema_version": [r.schema_version for r in sorted_rows],
        "run_id": [r.run_id for r in sorted_rows],
        "node_id": [r.node_id for r in sorted_rows],
        "pillar": [r.pillar for r in sorted_rows],
        "component": [r.component for r in sorted_rows],
        "status": [r.status for r in sorted_rows],
        "event_timestamp": [r.event_timestamp for r in sorted_rows],
        "architecture": [r.architecture for r in sorted_rows],
        "kernel_release": [r.kernel_release for r in sorted_rows],
        "device_tree_model": [r.device_tree_model for r in sorted_rows],
        "cpu_harts_count": [r.cpu_harts_count for r in sorted_rows],
        "pg_server_version": [r.pg_server_version for r in sorted_rows],
        "db_name": [r.db_name for r in sorted_rows],
        "table_name": [r.table_name for r in sorted_rows],
        "nvme_device": [r.nvme_device for r in sorted_rows],
        "cache_mode": [r.cache_mode for r in sorted_rows],
        "io_method": [r.io_method for r in sorted_rows],
        "effective_io_concurrency": [r.effective_io_concurrency for r in sorted_rows],
        "io_workers": [r.io_workers for r in sorted_rows],
        "gather_workers": [r.gather_workers for r in sorted_rows],
        "workload": [r.workload for r in sorted_rows],
        "top_node_type": [r.explain.top_node_type for r in sorted_rows],
        "execution_time_ms": [r.explain.execution_time_ms for r in sorted_rows],
        "planning_time_ms": [r.explain.planning_time_ms for r in sorted_rows],
        "shared_hit_blocks": [r.explain.shared_hit_blocks for r in sorted_rows],
        "shared_read_blocks": [r.explain.shared_read_blocks for r in sorted_rows],
        "shared_dirtied_blocks": [r.explain.shared_dirtied_blocks for r in sorted_rows],
        "shared_written_blocks": [r.explain.shared_written_blocks for r in sorted_rows],
        "io_read_time_ms": [r.explain.io_read_time_ms for r in sorted_rows],
        "io_write_time_ms": [r.explain.io_write_time_ms for r in sorted_rows],
        "wal_records": [r.explain.wal_records for r in sorted_rows],
        "wal_fpi": [r.explain.wal_fpi for r in sorted_rows],
        "wal_bytes": [r.explain.wal_bytes for r in sorted_rows],
        "pg_stat_io_reads": [r.pg_stat_io.reads for r in sorted_rows],
        "pg_stat_io_read_bytes": [r.pg_stat_io.read_bytes for r in sorted_rows],
        "pg_stat_io_read_time_ms": [r.pg_stat_io.read_time_ms for r in sorted_rows],
        "pg_stat_io_hits": [r.pg_stat_io.hits for r in sorted_rows],
        "pg_stat_io_writes": [r.pg_stat_io.writes for r in sorted_rows],
        "pg_stat_io_write_bytes": [r.pg_stat_io.write_bytes for r in sorted_rows],
        "pg_stat_io_write_time_ms": [r.pg_stat_io.write_time_ms for r in sorted_rows],
        "pg_stat_io_io_worker_reads": [r.pg_stat_io.io_worker_reads for r in sorted_rows],
        "perf_cycles": [r.perf.cycles for r in sorted_rows],
        "perf_instructions": [r.perf.instructions for r in sorted_rows],
        "perf_ipc": [r.perf.ipc for r in sorted_rows],
        "perf_context_switches": [r.perf.context_switches for r in sorted_rows],
        "perf_cpu_migrations": [r.perf.cpu_migrations for r in sorted_rows],
        "perf_l1_dcache_load_misses": [r.perf.l1_dcache_load_misses for r in sorted_rows],
        "perf_llc_load_misses": [r.perf.llc_load_misses for r in sorted_rows],
        "perf_dtlb_load_misses": [r.perf.dtlb_load_misses for r in sorted_rows],
        "disk_reads_completed": [r.diskstats.reads_completed for r in sorted_rows],
        "disk_sectors_read": [r.diskstats.sectors_read for r in sorted_rows],
        "disk_read_bytes": [r.diskstats.read_bytes for r in sorted_rows],
        "disk_read_time_ms": [r.diskstats.read_time_ms for r in sorted_rows],
        "disk_writes_completed": [r.diskstats.writes_completed for r in sorted_rows],
        "disk_sectors_written": [r.diskstats.sectors_written for r in sorted_rows],
        "disk_write_bytes": [r.diskstats.write_bytes for r in sorted_rows],
        "disk_write_time_ms": [r.diskstats.write_time_ms for r in sorted_rows],
        "disk_io_time_ms": [r.diskstats.io_time_ms for r in sorted_rows],
        "disk_weighted_io_time_ms": [r.diskstats.weighted_io_time_ms for r in sorted_rows],
        "nvme_read_mib_s": [None for _ in sorted_rows],
        "speedup_vs_sync": [None for _ in sorted_rows],
        "iteration": [r.iteration for r in sorted_rows],
        "io_direct": [r.io_direct for r in sorted_rows],
        "wall_duration_ms": [r.wall_duration_ms for r in sorted_rows],
        "pg_io_read_mib_s": [None for _ in sorted_rows],
        "plan_shape_valid": [r.plan_shape_valid for r in sorted_rows],
        "perf_pmu_multiplexed": [r.perf.pmu_multiplexed for r in sorted_rows],
        "perf_min_pcnt_running": [r.perf.min_pcnt_running for r in sorted_rows],
    }

    table = pa.Table.from_pydict(columns, schema=SHOWDOWN_SCHEMA)

    # Vectorized NVMe throughput calculation over wall_duration_ms (falling back to
    # execution_time_ms only for legacy fixtures lacking wall_duration_ms) via pyarrow.compute
    has_wall = pc.and_kleene(
        pc.is_valid(table["wall_duration_ms"]),
        pc.greater(table["wall_duration_ms"], pa.scalar(0.0, type=pa.float64())),
    )
    effective_dur_ms = pc.if_else(has_wall, table["wall_duration_ms"], table["execution_time_ms"])
    dur_sec = pc.divide(effective_dur_ms, pa.scalar(1000.0, type=pa.float64()))
    read_mib = pc.divide(
        pc.cast(table["disk_read_bytes"], pa.float64()),
        pa.scalar(1048576.0, type=pa.float64()),
    )
    valid_tput = pc.and_kleene(
        pc.is_valid(read_mib),
        pc.greater(dur_sec, pa.scalar(0.0, type=pa.float64())),
    )
    safe_dur_sec = pc.if_else(valid_tput, dur_sec, pa.scalar(1.0, type=pa.float64()))
    nvme_mib_s = pc.if_else(
        valid_tput,
        pc.round(pc.divide(read_mib, safe_dur_sec), 3),
        pa.scalar(None, type=pa.float64()),
    )

    # Vectorized PG EXPLAIN I/O read throughput: Shared Read Blocks (8 KiB) / I/O Read Time
    pg_read_mib = pc.divide(
        pc.multiply(
            pc.cast(table["shared_read_blocks"], pa.float64()),
            pa.scalar(float(DEFAULT_PG_BLOCK_BYTES), type=pa.float64()),
        ),
        pa.scalar(1048576.0, type=pa.float64()),
    )
    pg_io_sec = pc.divide(table["io_read_time_ms"], pa.scalar(1000.0, type=pa.float64()))
    valid_pg_io = pc.greater(pg_io_sec, pa.scalar(0.0, type=pa.float64()))
    safe_pg_io_sec = pc.if_else(valid_pg_io, pg_io_sec, pa.scalar(1.0, type=pa.float64()))
    pg_io_mib_s = pc.if_else(
        valid_pg_io,
        pc.round(pc.divide(pg_read_mib, safe_pg_io_sec), 3),
        pa.scalar(None, type=pa.float64()),
    )

    speedup_arr = _compute_speedup_column(table)

    table = table.set_column(
        table.schema.get_field_index("nvme_read_mib_s"),
        "nvme_read_mib_s",
        nvme_mib_s,
    )
    table = table.set_column(
        table.schema.get_field_index("pg_io_read_mib_s"),
        "pg_io_read_mib_s",
        pg_io_mib_s,
    )
    table = table.set_column(
        table.schema.get_field_index("speedup_vs_sync"),
        "speedup_vs_sync",
        speedup_arr,
    )

    provenance_sha256 = _compute_canonical_digest(table)
    ctd_metadata: dict[bytes, bytes] = {
        b"ctd.schema_version": meta.schema_version.encode("utf-8"),
        b"ctd.pillar": meta.pillar.encode("utf-8"),
        b"ctd.component": meta.component.encode("utf-8"),
        b"ctd.run_id": meta.run_id.encode("utf-8"),
        b"ctd.node_id": meta.node_id.encode("utf-8"),
        b"ctd.sha256_provenance_digest": provenance_sha256.encode("utf-8"),
    }
    table = table.replace_schema_metadata(ctd_metadata)
    return table, provenance_sha256


def compute_method_summaries(table: pa.Table) -> list[MethodLatencySummary]:
    """Compute per-(cache_mode, workload, io_method, eic, io_direct) quantiles."""
    cache_modes = [str(v) for v in table["cache_mode"].to_pylist()]
    workloads = [str(v) for v in table["workload"].to_pylist()]
    methods = [str(v) for v in table["io_method"].to_pylist()]
    eics = [int(v) for v in table["effective_io_concurrency"].to_pylist()]
    has_io_direct = "io_direct" in table.column_names
    io_directs = (
        [str(v) if v is not None else "off" for v in table["io_direct"].to_pylist()]
        if has_io_direct
        else ["off"] * table.num_rows
    )

    unique_keys = sorted(
        set(zip(cache_modes, workloads, methods, eics, io_directs, strict=True)),
        key=lambda k: (
            0 if k[0] == "cold" else 1,
            k[1],
            k[3],
            METHOD_SORT_ORDER.get(k[2], 99),
            k[2],
            k[4],
        ),
    )

    summaries: list[MethodLatencySummary] = []
    for cm, wl, method, eic, io_direct in unique_keys:
        eic_scalar = pa.scalar(eic, type=pa.int32())
        mask = pc.and_(
            pc.and_(
                pc.and_(
                    pc.equal(table["cache_mode"], cm),
                    pc.equal(table["workload"], wl),
                ),
                pc.equal(table["io_method"], method),
            ),
            pc.equal(table["effective_io_concurrency"], eic_scalar),
        )
        if has_io_direct:
            mask = pc.and_(mask, pc.equal(table["io_direct"], io_direct))

        sub = table.filter(mask)
        if sub.num_rows == 0:
            continue
        exec_col = sub["execution_time_ms"]
        min_ms = _arrow_scalar_float(pc.min(exec_col)) or 0.0
        max_ms = _arrow_scalar_float(pc.max(exec_col)) or 0.0
        mean_ms = _arrow_scalar_float(pc.mean(exec_col)) or 0.0
        q_arr = pc.quantile(exec_col, q=[0.5, 0.95, 0.99])
        p50_ms = _arrow_scalar_float(q_arr[0]) if len(q_arr) > 0 else mean_ms
        p95_ms = _arrow_scalar_float(q_arr[1]) if len(q_arr) > 1 else max_ms
        p99_ms = _arrow_scalar_float(q_arr[2]) if len(q_arr) > 2 else max_ms
        ddof = 1 if sub.num_rows > 1 else 0
        stddev_ms = _arrow_scalar_float(pc.stddev(exec_col, ddof=ddof))
        if stddev_ms is None:
            stddev_ms = 0.0
        summaries.append(
            MethodLatencySummary(
                cache_mode=cm,
                workload=wl,
                io_method=method,
                effective_io_concurrency=eic,
                io_direct=io_direct,
                n=int(sub.num_rows),
                min_ms=round(min_ms, 3),
                p50_ms=round(p50_ms if p50_ms is not None else mean_ms, 3),
                p95_ms=round(p95_ms if p95_ms is not None else max_ms, 3),
                p99_ms=round(p99_ms if p99_ms is not None else max_ms, 3),
                mean_ms=round(mean_ms, 3),
                stddev_ms=round(stddev_ms, 3),
                max_ms=round(max_ms, 3),
            )
        )
    return summaries


def _fmt_opt_float(val: Any, decimals: int = 2, suffix: str = "") -> str:
    if val is None:
        return "n/a"
    return f"{float(val):.{decimals}f}{suffix}"


def _fmt_opt_int(val: Any) -> str:
    if val is None:
        return "n/a"
    return f"{int(val):,}"


def render_markdown_summary(
    meta: RunMetadata,
    table: pa.Table,
    provenance_sha256: str,
) -> str:
    """Render a concise Markdown ablation report from the aggregated PyArrow Table."""
    lines: list[str] = [
        f"## BrakerRak PG18 Async I/O Showdown — `{meta.run_id}`",
        "",
        f"- **Node ID:** `{meta.node_id}` | **Silicon:** `{meta.device_tree_model}` "
        f"(`{meta.architecture}`, {meta.cpu_harts_count} harts)",
        f"- **PostgreSQL:** `{meta.pg_server_version}` | **Database/Table:** "
        f"`{meta.db_name}.{meta.table_name}` | **NVMe:** `{meta.nvme_device}`",
        f"- **CTD Schema:** `{meta.schema_version}` | **Provenance SHA-256:** "
        f"`{provenance_sha256[:16]}...`",
        "",
        "### Per-Pass Ablation Matrix",
        "",
        "| Cache | Workload | io_method | EIC | Exec (ms) | Iter | Plan (ms) | I/O Read (ms) "
        "| Shared Read Blks | NVMe Read (MiB/s) | PG I/O (MiB/s) | IPC | Ctx Sw | Plan OK "
        "| vs sync |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: "
        "| --- | ---: |",
    ]

    mux_warnings: list[str] = []
    plan_warnings: list[str] = []

    for row in table.to_pylist():
        plan_ok = bool(row.get("plan_shape_valid", True))
        if not plan_ok:
            plan_warnings.append(
                f"{row['cache_mode']}/{row['workload']}/{row['io_method']}"
                f"/eic{row['effective_io_concurrency']}/iter{row['iteration']} "
                f"(top={row['top_node_type']})"
            )
        if bool(row.get("perf_pmu_multiplexed", False)):
            mux_warnings.append(
                f"{row['cache_mode']}/{row['workload']}/{row['io_method']}"
                f"/eic{row['effective_io_concurrency']}/iter{row['iteration']} "
                f"(min pcnt-running={_fmt_opt_float(row.get('perf_min_pcnt_running'), 1, '%')})"
            )
        lines.append(
            f"| {row['cache_mode']} "
            f"| {row['workload']} "
            f"| `{row['io_method']}` "
            f"| {int(row['effective_io_concurrency'])} "
            f"| {float(row['execution_time_ms']):.2f} "
            f"| {int(row.get('iteration', 1))} "
            f"| {float(row['planning_time_ms']):.2f} "
            f"| {float(row['io_read_time_ms']):.2f} "
            f"| {int(row['shared_read_blocks']):,} "
            f"| {_fmt_opt_float(row['nvme_read_mib_s'], 1)} "
            f"| {_fmt_opt_float(row.get('pg_io_read_mib_s'), 1)} "
            f"| {_fmt_opt_float(row['perf_ipc'], 2)} "
            f"| {_fmt_opt_int(row['perf_context_switches'])} "
            f"| {'yes' if plan_ok else 'NO'} "
            f"| {_fmt_opt_float(row['speedup_vs_sync'], 2, 'x')} |"
        )

    summaries = compute_method_summaries(table)
    if summaries:
        show_direct = len({s.io_direct for s in summaries}) > 1 or any(
            s.io_direct != "off" for s in summaries
        )
        direct_hdr = " Direct I/O |" if show_direct else ""
        direct_sep = " --- |" if show_direct else ""
        lines.extend(
            [
                "",
                "### Latency Summary by `io_method`",
                "",
                f"| Cache | Workload | io_method | EIC |{direct_hdr} N | Min (ms) | P50 (ms) "
                "| P95 (ms) | P99 (ms) | Mean (ms) | Stddev (ms) | Max (ms) |",
                f"| --- | --- | --- | ---: |{direct_sep} ---: | ---: | ---: | ---: | ---: "
                "| ---: | ---: | ---: |",
            ]
        )
        for s in summaries:
            direct_cell = f" `{s.io_direct}` |" if show_direct else ""
            lines.append(
                f"| {s.cache_mode} | {s.workload} | `{s.io_method}` | {s.effective_io_concurrency} "
                f"|{direct_cell} {s.n} | {s.min_ms:.2f} | {s.p50_ms:.2f} | {s.p95_ms:.2f} "
                f"| {s.p99_ms:.2f} | {s.mean_ms:.2f} | {s.stddev_ms:.2f} | {s.max_ms:.2f} |"
            )

    if mux_warnings:
        lines.extend(
            [
                "",
                f"> **PMU Multiplexing Warning:** `pcnt-running < 100%` detected on "
                f"{len(mux_warnings)} pass(es): {', '.join(mux_warnings[:5])}",
            ]
        )
    if plan_warnings:
        lines.extend(
            [
                "",
                f"> **Plan Shape Warning:** Unexpected EXPLAIN node shape on "
                f"{len(plan_warnings)} pass(es): {', '.join(plan_warnings[:5])}",
            ]
        )

    return "\n".join(lines)


def analyze_showdown_run(
    run_dir: Path,
    *,
    out_dir: Path | None = None,
    stem: str | None = None,
    parquet_sink: ArtifactSink | None = None,
    arrow_sink: ArtifactSink | None = None,
) -> ShowdownArtifacts:
    """Parse a showdown run directory, build Arrow Table, and emit Parquet + IPC + Markdown."""
    meta, rows = load_showdown_passes(run_dir)
    table, provenance_sha256 = build_showdown_table(meta, rows)

    resolved_out_dir = out_dir if out_dir is not None else run_dir.parent
    resolved_stem = stem if stem else meta.run_id

    pq_writer = parquet_sink or ParquetZstdSink()
    ipc_writer = arrow_sink or ArrowIPCSink()

    parquet_path = pq_writer.write(table, resolved_out_dir, resolved_stem)
    arrow_path = ipc_writer.write(table, resolved_out_dir, resolved_stem)
    markdown = render_markdown_summary(meta, table, provenance_sha256)

    return ShowdownArtifacts(
        table=table,
        parquet_path=parquet_path,
        arrow_path=arrow_path,
        markdown=markdown,
        provenance_sha256=provenance_sha256,
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="analyze_showdown.py",
        description=(
            "Aggregate BrakerRak PostgreSQL 18 io_uring showdown telemetry into "
            "CTD-aligned Zstd Parquet + Arrow IPC artifacts and a Markdown summary."
        ),
    )
    parser.add_argument(
        "run_dir",
        type=Path,
        help="Path to raw benchmark run directory (e.g. ~/.brakerrak/snapshots/benchmarks/<id>)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="Output directory for .parquet and .arrow artifacts (default: <run_dir>/..)",
    )
    parser.add_argument(
        "--stem",
        type=str,
        default=None,
        help="Base filename stem for output artifacts (default: run_id from metadata.json)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    artifacts = analyze_showdown_run(
        args.run_dir,
        out_dir=args.out_dir,
        stem=args.stem,
    )
    print(artifacts.markdown)
    print("")
    print(f"Parquet (Zstd): {artifacts.parquet_path}")
    print(f"Arrow IPC     : {artifacts.arrow_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
