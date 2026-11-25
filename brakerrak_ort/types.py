"""Structural protocols and typed data models for BrakerRak ORT collection."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Protocol, TypedDict, runtime_checkable

AssertionStatus = Literal["PASS", "WARN", "FAIL"]


@dataclass(frozen=True)
class CommandResult:
    """Result of executing an external read-only inspection command."""

    stdout: str
    stderr: str = ""
    returncode: int = 0
    error: str | None = None

    @property
    def ok(self) -> bool:
        return self.error is None and self.returncode == 0


@dataclass(frozen=True)
class UserIdentity:
    """Resolved non-root operator identity for snapshot ownership and paths."""

    username: str
    groupname: str
    home: str
    uid: int | None
    gid: int | None


@dataclass(frozen=True)
class PrimaryNicStatus:
    """Detected primary network interface state and IPv4 lease readiness."""

    name: str
    operstate: Literal["UP", "DOWN"]
    has_global_ipv4: bool

    @property
    def healthy(self) -> bool:
        return self.operstate == "UP" and self.has_global_ipv4


class AssertionResult(TypedDict):
    """Single Operational Readiness Test assertion record."""

    id: str
    description: str
    expected: str | int
    actual: str | int
    status: AssertionStatus


class AcceleratorInfo(TypedDict):
    """Detected PCIe NPU/GPU accelerator inventory entry."""

    address: str
    vendor_id: str
    device_id: str
    vendor_name: str
    description: str
    pcie_link_speed: str | None
    pcie_link_width: str | None


class AcceleratorRuntimeInfo(TypedDict):
    """Day-1 kernel driver, device node, and CLI runtime probe state."""

    vendor_id: str
    device_nodes: list[str]
    kmod_name: str
    kmod_loaded: bool
    cli_tool: str
    cli_ok: bool


class MountInfo(TypedDict):
    """Filesystem mount status and detected fstype for a target mountpoint."""

    mountpoint: str
    mounted: bool
    fstype: str | None


class BtrfsDeviceStatsInfo(TypedDict):
    """Parsed read-only `btrfs device stats` health summary."""

    mountpoint: str
    stats_available: bool
    total_errors: int
    nonzero_errors: list[str]
    error: str | None


@dataclass(frozen=True)
class SnapshotOutputs:
    """Paths, digests, and payloads produced by a single ORT run."""

    private_path: Path
    public_path: Path | None
    private_sha256: str
    public_sha256: str | None
    overall_status: AssertionStatus
    private_payload: dict[str, Any]
    public_payload: dict[str, Any] | None


@runtime_checkable
class SystemProbe(Protocol):
    """Dependency-injectable read-only host inspection interface."""

    def read_text(self, path: str) -> str | None:
        """Read UTF-8 text from a sysfs/procfs/config path, returning None on error."""
        ...

    def path_exists(self, path: str) -> bool:
        """Return True if the given filesystem path exists."""
        ...

    def is_mount(self, path: str) -> bool:
        """Return True if the given path is an active mountpoint."""
        ...

    def glob_paths(self, pattern: str) -> list[str]:
        """Return sorted filesystem paths matching a glob pattern."""
        ...

    def run_cmd(
        self,
        cmd: Sequence[str],
        *,
        use_sudo: bool = False,
        timeout: float = 15.0,
    ) -> CommandResult:
        """Execute a read-only command with bounded timeout."""
        ...

    def get_loadavg(self) -> tuple[float, float, float] | None:
        """Return (1m, 5m, 15m) system load averages if available."""
        ...

    def get_total_ram_kb(self) -> int:
        """Return total physical memory in KiB."""
        ...

    def get_hostname(self) -> str:
        """Return host short name."""
        ...

    def get_fqdn(self) -> str:
        """Return host fully qualified domain name."""
        ...

    def get_architecture(self) -> str:
        """Return CPU architecture string (e.g., riscv64)."""
        ...

    def get_kernel_release(self) -> str:
        """Return OS kernel release string."""
        ...

    def get_uname(self) -> dict[str, str]:
        """Return uname fields as a string dictionary."""
        ...

    def sleep(self, seconds: float) -> None:
        """Sleep for the given interval during quiescent sampling."""
        ...
