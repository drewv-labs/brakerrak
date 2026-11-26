"""Read-only Linux/RISC-V hardware, kernel, PostgreSQL 18, and service probes."""

from __future__ import annotations

import fnmatch
import glob
import json
import os
import platform
import re
import select
import socket
import statistics
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from brakerrak_ort.profiles import (
    ACCELERATOR_PCI_CLASSES,
    DEDICATED_ACCELERATOR_VENDORS,
    GPU_ACCELERATOR_VENDORS,
)
from brakerrak_ort.types import (
    AcceleratorInfo,
    AcceleratorRuntimeInfo,
    BtrfsDeviceStatsInfo,
    CommandResult,
    MountInfo,
    PrimaryNicStatus,
    SystemProbe,
)

SYSCTL_KEYS: tuple[str, ...] = (
    "kernel.perf_event_paranoid",
    "kernel.kptr_restrict",
    "kernel.io_uring_disabled",
    "vm.nr_hugepages",
    "vm.swappiness",
    "vm.dirty_background_bytes",
    "vm.dirty_bytes",
)

PG_SETTINGS_NAMES: tuple[str, ...] = (
    "server_version",
    "data_directory",
    "io_method",
    "io_workers",
    "io_combine_limit",
    "io_max_combine_limit",
    "io_max_concurrency",
    "effective_io_concurrency",
    "maintenance_io_concurrency",
    "track_io_timing",
    "shared_buffers",
    "huge_pages",
    "huge_pages_status",
    "effective_cache_size",
    "work_mem",
    "maintenance_work_mem",
    "wal_compression",
    "random_page_cost",
)

_PG_SETTINGS_SQL_LIST = ", ".join(f"'{name}'" for name in PG_SETTINGS_NAMES)

PG_INSPECT_SQL: str = (
    "SELECT json_build_object("
    "'settings', COALESCE(("
    "SELECT json_object_agg(name, current_setting(name)) "
    f"FROM pg_settings WHERE name IN ({_PG_SETTINGS_SQL_LIST})"
    "), '{}'::json), "
    "'tablespaces', COALESCE(("
    "SELECT json_agg(spcname ORDER BY spcname) "
    "FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')"
    "), '[]'::json)"
    ");"
)

_PCI_LINE_RE = re.compile(
    r"^(?P<addr>(?:[0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F])\s+"
    r"(?P<rest>.*?)\[(?P<vendor>[0-9a-fA-F]{4}):(?P<device>[0-9a-fA-F]{4})\]"
)
_PCI_CLASS_RE = re.compile(r"\[(?P<cls>[0-9a-fA-F]{4})\]:")
_BTRFS_STAT_RE = re.compile(
    r"^\[(?P<dev>[^\]]+)\]\.(?P<stat>[A-Za-z0-9_]+)\s+(?P<count>\d+)\s*$"
)
_GANESHA_EXPORT_HDR_RE = re.compile(r"\bEXPORT\s*\{", re.IGNORECASE)
_GANESHA_CLIENT_HDR_RE = re.compile(r"\bCLIENT\s*\{", re.IGNORECASE)
_GANESHA_KV_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*;?\s*$")
_GANESHA_INCLUDE_RE = re.compile(r'^\s*%include\s+"?([^"\s]+)"?\s*$', re.IGNORECASE)


def read_sysfs(path: str) -> str | None:
    """Read a sysfs, procfs, or config file safely, returning None if unavailable."""
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return fh.read().strip()
    except OSError:
        return None


class LocalSystemProbe:
    """Default SystemProbe implementation reading directly from the local OS."""

    def read_text(self, path: str) -> str | None:
        return read_sysfs(path)

    def path_exists(self, path: str) -> bool:
        return os.path.exists(path)

    def is_mount(self, path: str) -> bool:
        return os.path.ismount(path)

    def glob_paths(self, pattern: str) -> list[str]:
        return sorted(glob.glob(pattern))

    def run_cmd(
        self,
        cmd: Sequence[str],
        *,
        use_sudo: bool = False,
        timeout: float = 15.0,
    ) -> CommandResult:
        argv = list(cmd)
        if use_sudo and os.geteuid() != 0:
            argv = ["sudo", "-n", *argv]
        try:
            proc = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            return CommandResult(
                stdout=proc.stdout.strip(),
                stderr=proc.stderr.strip(),
                returncode=proc.returncode,
            )
        except Exception as exc:
            return CommandResult(stdout="", stderr="", returncode=1, error=str(exc))

    def get_loadavg(self) -> tuple[float, float, float] | None:
        try:
            return os.getloadavg()
        except OSError:
            return None

    def get_total_ram_kb(self) -> int:
        meminfo = self.read_text("/proc/meminfo")
        if meminfo:
            for line in meminfo.splitlines():
                if line.startswith("MemTotal:"):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        return int(parts[1])
        try:
            page_size = os.sysconf("SC_PAGE_SIZE")
            phys_pages = os.sysconf("SC_PHYS_PAGES")
            if page_size > 0 and phys_pages > 0:
                return int(page_size * phys_pages // 1024)
        except (AttributeError, OSError, ValueError):
            pass
        return 0

    def get_hostname(self) -> str:
        return socket.gethostname()

    def get_fqdn(self) -> str:
        return socket.getfqdn()

    def get_architecture(self) -> str:
        return platform.machine()

    def get_kernel_release(self) -> str:
        return platform.release()

    def get_uname(self) -> dict[str, str]:
        return dict(platform.uname()._asdict())

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


def parse_cpuinfo_harts(cpuinfo_raw: str) -> list[dict[str, str]]:
    """Parse /proc/cpuinfo stanzas, keeping only stanzas with a 'processor' or 'hart' key."""
    harts: list[dict[str, str]] = []
    current: dict[str, str] = {}

    def _flush() -> None:
        nonlocal current
        if current and any(k.lower() in ("processor", "hart") for k in current):
            harts.append(current)
        current = {}

    for line in cpuinfo_raw.splitlines():
        if not line.strip():
            _flush()
            continue
        if ":" in line:
            key, val = (part.strip() for part in line.split(":", 1))
            if key:
                current[key] = val
    _flush()
    return harts


def parse_gt_per_sec(link_speed: str | None) -> float:
    """Extract numeric GT/s value from a PCIe sysfs link speed string."""
    if not link_speed:
        return 0.0
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*GT/s", link_speed)
    return float(match.group(1)) if match else 0.0


def parse_pcie_width(link_width: str | None) -> int:
    """Extract numeric PCIe lane width from a sysfs link width string."""
    if not link_width:
        return 0
    match = re.search(r"([0-9]+)", link_width)
    return int(match.group(1)) if match else 0


def has_global_ipv4(iface: Mapping[str, Any]) -> bool:
    """Return True if an `ip -j addr` interface record carries a global non-loopback IPv4 lease."""
    addr_info = iface.get("addr_info")
    if not isinstance(addr_info, list):
        return False
    for entry in addr_info:
        if not isinstance(entry, dict):
            continue
        if entry.get("family") != "inet":
            continue
        scope = str(entry.get("scope") or "").lower()
        local = str(entry.get("local") or "")
        if scope == "global" and local and not local.startswith(("127.", "169.254.")):
            return True
    return False


def detect_primary_nic(
    net_ifaces: Sequence[Mapping[str, Any]],
    net_routes: Sequence[Mapping[str, Any]],
    kit_env: Mapping[str, str],
) -> PrimaryNicStatus:
    """Identify the primary NIC and verify both carrier UP and a global IPv4 address."""
    candidates: list[str] = []
    for route in net_routes:
        if route.get("dst") == "default" and route.get("dev"):
            candidates.append(str(route["dev"]))
    kit_nic = (kit_env.get("RVDK_PRIMARY_NIC") or "").strip()
    if kit_nic:
        candidates.append(kit_nic)
    candidates.extend(["end0", "eth0", "enp1s0", "enp2s0", "wan", "wlan0", "esp0"])

    iface_by_name: dict[str, Mapping[str, Any]] = {}
    for iface in net_ifaces:
        name = str(iface.get("ifname") or "")
        if not name:
            continue
        iface_by_name[name] = iface
        altnames = iface.get("altnames")
        if isinstance(altnames, list):
            for alt in altnames:
                alt_s = str(alt)
                if alt_s:
                    iface_by_name[alt_s] = iface

    def _status_for(entry: Mapping[str, Any], fallback_name: str) -> PrimaryNicStatus:
        name = str(entry.get("ifname") or fallback_name)
        is_up = str(entry.get("operstate") or "").upper() == "UP"
        return PrimaryNicStatus(
            name=name,
            operstate="UP" if is_up else "DOWN",
            has_global_ipv4=has_global_ipv4(entry),
        )

    for cand in candidates:
        if cand in iface_by_name:
            return _status_for(iface_by_name[cand], cand)

    virtual_prefixes = ("lo", "tailscale", "docker", "br-", "veth", "virbr")
    for iface in net_ifaces:
        name = str(iface.get("ifname") or "")
        if name and not name.startswith(virtual_prefixes):
            return _status_for(iface, name)

    return PrimaryNicStatus(name="eth0", operstate="DOWN", has_global_ipv4=False)


def detect_pcie_accelerators(
    pci_lines: Sequence[str],
    probe: SystemProbe,
) -> list[AcceleratorInfo]:
    """Identify PCIe NPU/GPU accelerators (Hailo 1e60:*, Tenstorrent 1e52:*, etc.) from lspci."""
    accelerators: list[AcceleratorInfo] = []
    for line in pci_lines:
        match = _PCI_LINE_RE.match(line.strip())
        if not match:
            continue
        addr = match.group("addr")
        rest = match.group("rest").strip()
        vendor = match.group("vendor").lower()
        device = match.group("device").lower()
        cls_match = _PCI_CLASS_RE.search(rest)
        pci_class = cls_match.group("cls").lower() if cls_match else ""

        vendor_name: str | None = None
        if vendor in DEDICATED_ACCELERATOR_VENDORS:
            vendor_name = DEDICATED_ACCELERATOR_VENDORS[vendor]
        elif vendor in GPU_ACCELERATOR_VENDORS and pci_class in ACCELERATOR_PCI_CLASSES:
            vendor_name = GPU_ACCELERATOR_VENDORS[vendor]
        elif pci_class == "1200":
            vendor_name = "PCIe Processing Accelerator"

        if vendor_name is None:
            continue

        full_addr = addr if addr.count(":") == 2 else f"0000:{addr}"
        sysfs_dir = f"/sys/bus/pci/devices/{full_addr}"
        link_speed = probe.read_text(f"{sysfs_dir}/current_link_speed")
        link_width = probe.read_text(f"{sysfs_dir}/current_link_width")

        accelerators.append(
            AcceleratorInfo(
                address=full_addr,
                vendor_id=vendor,
                device_id=device,
                vendor_name=vendor_name,
                description=line.strip(),
                pcie_link_speed=link_speed,
                pcie_link_width=link_width,
            )
        )
    return accelerators


def read_sysctl_baseline(probe: SystemProbe) -> dict[str, str]:
    """Read kernel and VM sysctl baselines directly from /proc/sys/ without spawning sysctl."""
    values: dict[str, str] = {}
    for key in SYSCTL_KEYS:
        proc_path = f"/proc/sys/{key.replace('.', '/')}"
        raw = probe.read_text(proc_path)
        values[key] = raw if raw is not None else ""
    return values


def sample_quiescent_metrics(
    probe: SystemProbe,
    duration_sec: float = 5.0,
    interval_sec: float = 0.5,
) -> dict[str, Any]:
    """Sample CPU frequencies, thermals, fan RPM, loadavg, and MemAvailable over a window."""
    if duration_sec <= 0 or interval_sec <= 0:
        samples = 1
    else:
        samples = max(1, int(duration_sec / interval_sec))

    cpu_freqs: dict[str, list[float]] = {}
    thermals: dict[str, list[float]] = {}
    fan_rpms: list[int] = []
    load_1m: list[float] = []
    mem_avail_kb: list[int] = []

    freq_paths = probe.glob_paths("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")
    if not freq_paths:
        freq_paths = probe.glob_paths("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_cur_freq")

    tz_paths = probe.glob_paths("/sys/class/thermal/thermal_zone*")
    hwmon_temp_paths = probe.glob_paths("/sys/class/hwmon/hwmon*/temp*_input")
    fan_paths = probe.glob_paths("/sys/class/hwmon/hwmon*/fan*_input")

    for idx in range(samples):
        for fp in freq_paths:
            parts = fp.split("/")
            cpu_id = parts[5] if len(parts) > 5 else os.path.basename(os.path.dirname(fp))
            val = probe.read_text(fp)
            if val and val.isdigit():
                cpu_freqs.setdefault(cpu_id, []).append(round(int(val) / 1000.0, 2))

        for tz in tz_paths:
            tz_name = probe.read_text(f"{tz}/type") or os.path.basename(tz)
            t_val = probe.read_text(f"{tz}/temp")
            if t_val and t_val.lstrip("-").isdigit():
                deg_c = round(int(t_val) / 1000.0, 2)
                if 0.0 < deg_c < 150.0:
                    thermals.setdefault(tz_name, []).append(deg_c)

        for hp in hwmon_temp_paths:
            hw_dir = os.path.dirname(hp)
            hw_name = probe.read_text(f"{hw_dir}/name") or os.path.basename(hw_dir)
            lbl = (
                probe.read_text(hp.replace("_input", "_label"))
                or os.path.basename(hp).replace("_input", "")
            )
            t_val = probe.read_text(hp)
            if t_val and t_val.lstrip("-").isdigit():
                deg_c = round(int(t_val) / 1000.0, 2)
                if 0.0 < deg_c < 150.0:
                    thermals.setdefault(f"{hw_name}:{lbl}", []).append(deg_c)

        for fp in fan_paths:
            f_val = probe.read_text(fp)
            if f_val and f_val.isdigit():
                fan_rpms.append(int(f_val))

        loadavg = probe.get_loadavg()
        if loadavg is not None:
            load_1m.append(round(loadavg[0], 4))

        meminfo = probe.read_text("/proc/meminfo") or ""
        for line in meminfo.splitlines():
            if line.startswith("MemAvailable:"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    mem_avail_kb.append(int(parts[1]))
                break

        if idx + 1 < samples and interval_sec > 0:
            probe.sleep(interval_sec)

    def _summarize(arr: Sequence[int | float], unit: str = "") -> dict[str, Any]:
        if not arr:
            return {"min": None, "mean": None, "max": None, "samples": 0, "unit": unit}
        return {
            "min": round(float(min(arr)), 2),
            "mean": round(float(statistics.mean(arr)), 2),
            "max": round(float(max(arr)), 2),
            "samples": len(arr),
            "unit": unit,
        }

    return {
        "window_seconds": duration_sec,
        "sample_interval_seconds": interval_sec,
        "cpu_frequency_mhz": {k: _summarize(v, "MHz") for k, v in cpu_freqs.items()},
        "thermal_zones_celsius": {k: _summarize(v, "C") for k, v in thermals.items()},
        "som_fan_rpm": _summarize(fan_rpms, "RPM"),
        "loadavg_1m": _summarize(load_1m, "load"),
        "mem_available_kb": _summarize(mem_avail_kb, "kB"),
    }


def resolve_soc_peak_temp(thermals_summary: Mapping[str, Mapping[str, Any]]) -> float | None:
    """Return peak SoC temperature in Celsius, falling back to NVMe composite if no SoC sensor."""
    soc_peaks = [
        float(val["max"])
        for key, val in thermals_summary.items()
        if val.get("max") is not None and not key.lower().startswith("nvme:")
    ]
    if soc_peaks:
        return max(soc_peaks)
    fallback_peaks = [
        float(val["max"])
        for key, val in thermals_summary.items()
        if val.get("max") is not None and key.lower() in ("nvme:composite", "nvme:temp1")
    ]
    return max(fallback_peaks) if fallback_peaks else None


def inspect_postgres_state(probe: SystemProbe) -> dict[str, Any]:
    """Inspect PostgreSQL 18 state with a single psql -X -tAc JSON query."""
    psql_res = probe.run_cmd(["psql", "--version"])
    psql_ver = psql_res.stdout if (psql_res.ok and psql_res.stdout) else "not_installed"
    svc_res = probe.run_cmd(["systemctl", "is-active", "postgresql"])
    service_active = svc_res.stdout.strip() == "active"

    pg_settings: dict[str, str] = {}
    tablespaces: list[str] = []

    if service_active:
        query_res = probe.run_cmd(
            ["sudo", "-n", "-u", "postgres", "psql", "-X", "-tAc", PG_INSPECT_SQL]
        )
        if query_res.ok and query_res.stdout:
            try:
                parsed: Any = json.loads(query_res.stdout)
                if isinstance(parsed, dict):
                    raw_settings = parsed.get("settings")
                    if isinstance(raw_settings, dict):
                        for k, v in raw_settings.items():
                            if isinstance(k, str) and v is not None:
                                pg_settings[k] = str(v)
                    raw_ts = parsed.get("tablespaces")
                    if isinstance(raw_ts, list):
                        tablespaces = [str(ts).strip() for ts in raw_ts if str(ts).strip()]
            except json.JSONDecodeError:
                pass

    return {
        "psql_client_version": psql_ver,
        "systemd_service_active": service_active,
        "active_runtime_parameters": pg_settings,
        "custom_tablespaces": tablespaces,
    }


def _strip_ganesha_comments(text: str) -> str:
    cleaned_lines: list[str] = []
    for raw_line in text.splitlines():
        in_quote: str | None = None
        out_chars: list[str] = []
        i = 0
        length = len(raw_line)
        while i < length:
            ch = raw_line[i]
            if in_quote:
                out_chars.append(ch)
                if ch == in_quote and (i == 0 or raw_line[i - 1] != "\\"):
                    in_quote = None
                i += 1
                continue
            if ch in ('"', "'"):
                in_quote = ch
                out_chars.append(ch)
                i += 1
                continue
            if ch == "#" or (ch == "/" and i + 1 < length and raw_line[i + 1] == "/"):
                break
            out_chars.append(ch)
            i += 1
        cleaned_lines.append("".join(out_chars))
    return "\n".join(cleaned_lines)


def _extract_brace_blocks(text: str, header_re: re.Pattern[str]) -> list[str]:
    blocks: list[str] = []
    pos = 0
    while True:
        match = header_re.search(text, pos)
        if not match:
            break
        start = match.end()
        depth = 1
        idx = start
        in_quote: str | None = None
        while idx < len(text) and depth > 0:
            ch = text[idx]
            if in_quote:
                if ch == in_quote and text[idx - 1] != "\\":
                    in_quote = None
            elif ch in ('"', "'"):
                in_quote = ch
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            idx += 1
        if depth == 0:
            blocks.append(text[start : idx - 1])
            pos = idx
        else:
            break
    return blocks


def _strip_nested_blocks(block_body: str) -> str:
    out: list[str] = []
    depth = 0
    in_quote: str | None = None
    for idx, ch in enumerate(block_body):
        if in_quote:
            if depth == 0:
                out.append(ch)
            if ch == in_quote and (idx == 0 or block_body[idx - 1] != "\\"):
                in_quote = None
            continue
        if ch in ('"', "'"):
            in_quote = ch
            if depth == 0:
                out.append(ch)
            continue
        if ch == "{":
            depth += 1
            continue
        if ch == "}":
            depth = max(0, depth - 1)
            continue
        if depth == 0:
            out.append(ch)
    return "".join(out)


def _parse_ganesha_kv(body: str) -> dict[str, str]:
    kv: dict[str, str] = {}
    for segment in re.split(r"[;\n]", body):
        match = _GANESHA_KV_RE.match(segment)
        if not match:
            continue
        key = match.group(1).strip().lower()
        val = match.group(2).strip().rstrip(";").strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        kv[key] = val
    return kv


def parse_ganesha_exports(conf_text: str) -> list[str]:
    """Parse NFS-Ganesha EXPORT blocks into normalized export specification strings."""
    cleaned = _strip_ganesha_comments(conf_text)
    exports: list[str] = []

    for export_body in _extract_brace_blocks(cleaned, _GANESHA_EXPORT_HDR_RE):
        top_kv = _parse_ganesha_kv(_strip_nested_blocks(export_body))
        path = top_kv.get("path") or top_kv.get("pseudo")
        if not path:
            continue
        export_id = top_kv.get("export_id", "")
        pseudo = top_kv.get("pseudo", path)
        access = top_kv.get("access_type", "")

        client_specs: list[str] = []
        client_access: list[str] = []
        for client_body in _extract_brace_blocks(export_body, _GANESHA_CLIENT_HDR_RE):
            c_kv = _parse_ganesha_kv(client_body)
            if c_kv.get("clients"):
                client_specs.append(c_kv["clients"])
            if c_kv.get("access_type"):
                client_access.append(c_kv["access_type"])

        meta_parts = ["ganesha"]
        if export_id:
            meta_parts.append(f"id={export_id}")
        if pseudo:
            meta_parts.append(f"pseudo={pseudo}")
        eff_access = client_access[0] if client_access else access
        if eff_access:
            meta_parts.append(f"access={eff_access}")

        meta = ",".join(meta_parts)
        if client_specs:
            exports.append(f"{path} {', '.join(client_specs)} ({meta})")
        else:
            exports.append(f"{path} ({meta})")

    return exports


def _read_ganesha_config_with_includes(probe: SystemProbe, conf_path: str) -> str:
    root_text = probe.read_text(conf_path)
    if not root_text:
        return ""
    chunks = [root_text]
    for line in root_text.splitlines():
        match = _GANESHA_INCLUDE_RE.match(line)
        if not match:
            continue
        inc_target = match.group(1)
        if not os.path.isabs(inc_target):
            inc_target = os.path.join(os.path.dirname(conf_path), inc_target)
        for inc_path in probe.glob_paths(inc_target):
            inc_text = probe.read_text(inc_path)
            if inc_text:
                chunks.append(inc_text)
    return "\n".join(chunks)


def inspect_databroker_services(
    env_map: Mapping[str, str],
    probe: SystemProbe,
) -> dict[str, Any]:
    """Inspect Mosquitto MQTT and NFSv4 (kernel or nfs-ganesha) service states and exports."""
    mqtt_active = probe.run_cmd(["systemctl", "is-active", "mosquitto"]).stdout.strip() == "active"
    raw_port = (env_map.get("MQTT_PORT") or "1883").strip()
    mqtt_port = int(raw_port) if raw_port.isdigit() else 1883

    nfs_kernel_active = (
        probe.run_cmd(["systemctl", "is-active", "nfs-server.service"]).stdout.strip() == "active"
    )
    nfs_ganesha_active = (
        probe.run_cmd(["systemctl", "is-active", "nfs-ganesha.service"]).stdout.strip() == "active"
    )
    nfs_active = nfs_kernel_active or nfs_ganesha_active
    nfs_backend = (
        "nfs-ganesha"
        if nfs_ganesha_active
        else ("nfs-kernel-server" if nfs_kernel_active else "none")
    )

    active_exports: list[str] = []
    if nfs_ganesha_active:
        ganesha_text = _read_ganesha_config_with_includes(probe, "/etc/ganesha/ganesha.conf")
        if ganesha_text:
            active_exports.extend(parse_ganesha_exports(ganesha_text))

    if nfs_kernel_active or not active_exports:
        kernel_paths = ["/etc/exports"]
        exports_d = probe.glob_paths("/etc/exports.d/*.exports")
        if exports_d:
            kernel_paths.extend(exports_d)
        else:
            kernel_paths.append("/etc/exports.d/rvdk-vaults.exports")
        for exp_path in kernel_paths:
            raw_exp = probe.read_text(exp_path) or ""
            for line in raw_exp.splitlines():
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    active_exports.append(stripped)

    return {
        "mosquitto_mqtt": {
            "systemd_service_active": mqtt_active,
            "configured_port": mqtt_port,
        },
        "nfs_v4_server": {
            "systemd_service_active": nfs_active,
            "backend": nfs_backend,
            "configured_exports": active_exports,
        },
    }


def _is_kmod_loaded(probe: SystemProbe, module_name: str) -> bool:
    """Return True if a kernel module is loaded via /sys/module or /proc/modules."""
    if probe.path_exists(f"/sys/module/{module_name}"):
        return True
    normalized = module_name.replace("-", "_")
    proc_modules = probe.read_text("/proc/modules") or ""
    for line in proc_modules.splitlines():
        parts = line.split()
        if parts and parts[0].replace("-", "_") == normalized:
            return True
    return False


def inspect_accelerator_runtime(
    pcie_accelerators: Sequence[AcceleratorInfo],
    probe: SystemProbe,
) -> dict[str, AcceleratorRuntimeInfo]:
    """Inspect Hailo (1e60) and Tenstorrent (1e52) device nodes, kmods, and userspace CLIs."""
    vendors = {acc["vendor_id"].lower() for acc in pcie_accelerators}
    runtime: dict[str, AcceleratorRuntimeInfo] = {}

    if "1e60" in vendors:
        hailo_devs = probe.glob_paths("/dev/hailo*")
        hailo_kmod = _is_kmod_loaded(probe, "hailo_pci")
        hailo_cli = probe.run_cmd(["hailortcli", "fw-control", "identify"])
        runtime["hailo"] = AcceleratorRuntimeInfo(
            vendor_id="1e60",
            device_nodes=hailo_devs,
            kmod_name="hailo_pci",
            kmod_loaded=hailo_kmod,
            cli_tool="hailortcli",
            cli_ok=hailo_cli.ok,
        )

    if "1e52" in vendors:
        tt_devs = sorted(
            {p for p in probe.glob_paths("/dev/tenstorrent*") if p != "/dev/tenstorrent"}
            | set(probe.glob_paths("/dev/tenstorrent/*"))
        )
        tt_kmod = _is_kmod_loaded(probe, "tenstorrent")
        tt_cli = probe.run_cmd(["tt-smi", "-s"])
        runtime["tenstorrent"] = AcceleratorRuntimeInfo(
            vendor_id="1e52",
            device_nodes=tt_devs,
            kmod_name="tenstorrent",
            kmod_loaded=tt_kmod,
            cli_tool="tt-smi",
            cli_ok=tt_cli.ok,
        )

    return runtime


def _decode_proc_mount_path(raw: str) -> str:
    decoded = (
        raw.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
    )
    return decoded.rstrip("/") or "/"


def inspect_mount_fstype(mount_path: str, probe: SystemProbe) -> MountInfo:
    """Inspect mount status and filesystem type for a target mountpoint."""
    cleaned = mount_path.strip()
    if not cleaned:
        return MountInfo(mountpoint=mount_path, mounted=False, fstype=None)

    target = cleaned.rstrip("/") or "/"
    mounts_raw = probe.read_text("/proc/mounts") or ""
    matched_fstype: str | None = None
    matched_in_proc = False

    for line in mounts_raw.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        if _decode_proc_mount_path(parts[1]) == target:
            matched_in_proc = True
            matched_fstype = parts[2]

    if matched_in_proc:
        return MountInfo(mountpoint=cleaned, mounted=True, fstype=matched_fstype)

    is_mounted = probe.is_mount(cleaned)
    if is_mounted or not mounts_raw:
        findmnt_res = probe.run_cmd(["findmnt", "-n", "-o", "FSTYPE", cleaned])
        if findmnt_res.ok and findmnt_res.stdout.strip():
            fstype = findmnt_res.stdout.strip().splitlines()[-1].strip()
            return MountInfo(mountpoint=cleaned, mounted=True, fstype=fstype)

    return MountInfo(mountpoint=cleaned, mounted=is_mounted, fstype=None)


def inspect_btrfs_device_stats(mount_path: str, probe: SystemProbe) -> BtrfsDeviceStatsInfo:
    """Run read-only `btrfs device stats` on a Btrfs mountpoint and tally device errors."""
    cleaned = mount_path.strip()
    if not cleaned:
        return BtrfsDeviceStatsInfo(
            mountpoint=mount_path,
            stats_available=False,
            total_errors=0,
            nonzero_errors=[],
            error="empty mountpoint",
        )

    res = probe.run_cmd(["btrfs", "device", "stats", cleaned], use_sudo=True)
    if not res.ok or not res.stdout:
        err_msg = res.stderr or res.error or f"rc={res.returncode}"
        return BtrfsDeviceStatsInfo(
            mountpoint=cleaned,
            stats_available=False,
            total_errors=0,
            nonzero_errors=[],
            error=err_msg,
        )

    parsed_count = 0
    total_errors = 0
    nonzero_errors: list[str] = []
    for line in res.stdout.splitlines():
        match = _BTRFS_STAT_RE.match(line.strip())
        if not match:
            continue
        parsed_count += 1
        cnt = int(match.group("count"))
        total_errors += cnt
        if cnt > 0:
            nonzero_errors.append(f"{match.group('dev')}.{match.group('stat')}={cnt}")

    if parsed_count == 0:
        return BtrfsDeviceStatsInfo(
            mountpoint=cleaned,
            stats_available=False,
            total_errors=0,
            nonzero_errors=[],
            error="unrecognized btrfs device stats output",
        )

    return BtrfsDeviceStatsInfo(
        mountpoint=cleaned,
        stats_available=True,
        total_errors=total_errors,
        nonzero_errors=nonzero_errors,
        error=None,
    )


def format_sd_partition_name(sd_name: str) -> str:
    """Return the Linux first-partition basename for a block device, guarding empty names."""
    cleaned = os.path.basename(sd_name.strip().rstrip("/"))
    if not cleaned:
        return ""
    return f"{cleaned}p1" if cleaned[-1].isdigit() else f"{cleaned}1"


def _coerce_int(value: Any, default: int) -> int:
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str) and value.strip().lstrip("-").isdigit():
        return int(value.strip())
    return default


def _coerce_float(value: Any, default: float) -> float:
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return default
    return default


def _normalize_iface_entry(raw_iface: Mapping[str, Any]) -> dict[str, Any]:
    ifname = str(raw_iface.get("ifname") or raw_iface.get("name") or "").strip()
    raw_addr_info = raw_iface.get("addr_info")
    addr_info: list[dict[str, Any]] = []
    if isinstance(raw_addr_info, list):
        addr_info = [dict(item) for item in raw_addr_info if isinstance(item, Mapping)]
    else:
        ipv4 = raw_iface.get("ipv4") or raw_iface.get("ip")
        if isinstance(ipv4, str) and ipv4.strip():
            addr_info.append({"family": "inet", "local": ipv4.strip(), "scope": "global"})
    default_state = "UP" if addr_info else "DOWN"
    operstate = str(raw_iface.get("operstate") or default_state).strip().upper()
    entry: dict[str, Any] = {
        "ifname": ifname,
        "operstate": operstate,
        "addr_info": addr_info,
    }
    if isinstance(raw_iface.get("altnames"), list):
        entry["altnames"] = [str(a) for a in raw_iface["altnames"]]
    return entry


class HostProxiedTelemetryProbe:
    """SystemProbe adapter synthesizing virtual OS nodes from ESP32-P4 telemetry JSON."""

    is_host_proxied: bool = True

    def __init__(self, telemetry: Mapping[str, Any]) -> None:
        self._telemetry: dict[str, Any] = dict(telemetry)
        self._files: dict[str, str] = {}
        self._existing_paths: set[str] = set()
        self._mounts: set[str] = set()
        self._mount_fstypes: dict[str, str] = {}
        self._commands: dict[tuple[str, ...], CommandResult] = {}

        cpu_raw = telemetry.get("cpu")
        cpu_map: Mapping[str, Any] = cpu_raw if isinstance(cpu_raw, Mapping) else {}
        mem_raw = telemetry.get("memory")
        mem_map: Mapping[str, Any] = mem_raw if isinstance(mem_raw, Mapping) else {}
        net_raw = telemetry.get("network")
        net_map: Mapping[str, Any] = net_raw if isinstance(net_raw, Mapping) else {}
        thermal_raw = telemetry.get("thermal")
        thermal_map: Mapping[str, Any] = thermal_raw if isinstance(thermal_raw, Mapping) else {}

        dt_model = str(
            telemetry.get("dt_model")
            or telemetry.get("device_tree_model")
            or telemetry.get("board_model")
            or telemetry.get("model")
            or "Waveshare ESP32-P4-WIFI6-DEV-KIT (ESP32-P4NRW32X)"
        )
        self._hostname = str(
            telemetry.get("hostname")
            or telemetry.get("node_id")
            or telemetry.get("id")
            or "esp32p4-node"
        )
        self._fqdn = str(telemetry.get("fqdn") or f"{self._hostname}.local")
        self._arch = str(telemetry.get("arch") or telemetry.get("architecture") or "riscv32")
        os_id = str(telemetry.get("os") or telemetry.get("os_id") or "esp-idf")
        self._kernel_release = str(
            telemetry.get("kernel_release")
            or telemetry.get("firmware_version")
            or f"{os_id}-{self._arch}"
        )
        os_release = str(telemetry.get("os_release") or f'PRETTY_NAME="{os_id} ({self._arch})"\n')
        raw_role = telemetry.get("node_role") or telemetry.get("role")
        self.node_role: str | None = (
            str(raw_role).strip().lower()
            if isinstance(raw_role, str) and raw_role.strip()
            else None
        )

        # CPU topology & frequency
        isa_str = str(
            telemetry.get("isa") or cpu_map.get("isa") or "rv32imafc_zicsr_zifencei"
        )
        raw_mmu = (
            telemetry["mmu"]
            if "mmu" in telemetry and telemetry["mmu"] is not None
            else (
                telemetry["mmu_type"]
                if "mmu_type" in telemetry and telemetry["mmu_type"] is not None
                else cpu_map.get("mmu", "none")
            )
        )
        mmu_str = str(raw_mmu) if raw_mmu is not None else "none"
        raw_harts = (
            telemetry["harts"]
            if "harts" in telemetry
            else (telemetry["cpu_harts"] if "cpu_harts" in telemetry else cpu_map.get("harts"))
        )
        cpu_stanzas: list[str] = []
        if isinstance(raw_harts, Sequence) and not isinstance(raw_harts, (str, bytes)):
            hart_dicts = [h for h in raw_harts if isinstance(h, Mapping)]
            hart_count = len(hart_dicts)
            for idx, h_item in enumerate(hart_dicts):
                h_proc = h_item.get("processor", idx)
                h_id = h_item.get("hart", idx)
                h_isa = str(h_item.get("isa") or isa_str)
                h_mmu = str(h_item.get("mmu") if h_item.get("mmu") is not None else mmu_str)
                cpu_stanzas.append(
                    "\n".join(
                        [
                            f"processor\t: {h_proc}",
                            f"hart\t\t: {h_id}",
                            f"isa\t\t: {h_isa}",
                            f"mmu\t\t: {h_mmu}",
                        ]
                    )
                )
        else:
            hart_count = max(0, _coerce_int(raw_harts, 2))
            for idx in range(hart_count):
                cpu_stanzas.append(
                    "\n".join(
                        [
                            f"processor\t: {idx}",
                            f"hart\t\t: {idx}",
                            f"isa\t\t: {isa_str}",
                            f"mmu\t\t: {mmu_str}",
                        ]
                    )
                )
        if cpu_stanzas:
            cpu_stanzas.append(f"Hardware\t: {dt_model}")
        cpuinfo_text = ("\n\n".join(cpu_stanzas) + "\n") if cpu_stanzas else ""

        freq_mhz = _coerce_float(
            telemetry.get("cpu_freq_mhz")
            if telemetry.get("cpu_freq_mhz") is not None
            else (
                telemetry.get("freq_mhz")
                if telemetry.get("freq_mhz") is not None
                else cpu_map.get("freq_mhz")
            ),
            400.0,
        )
        if freq_mhz > 0:
            freq_khz = str(int(round(freq_mhz * 1000.0)))
            for idx in range(hart_count):
                self._files[f"/sys/devices/system/cpu/cpu{idx}/cpufreq/scaling_cur_freq"] = freq_khz

        # PSRAM / memory capacity
        ram_kb: int | None = None
        for candidate in (
            telemetry.get("total_ram_kb"),
            telemetry.get("psram_kb"),
            telemetry.get("mem_total_kb"),
            mem_map.get("psram_kb"),
            mem_map.get("total_ram_kb"),
            mem_map.get("total_kb"),
        ):
            if candidate is not None:
                ram_kb = _coerce_int(candidate, 0)
                break
        if ram_kb is None:
            for mb_candidate in (telemetry.get("psram_mb"), mem_map.get("psram_mb")):
                if mb_candidate is not None:
                    ram_kb = _coerce_int(mb_candidate, 0) * 1024
                    break
        if ram_kb is None:
            for byte_candidate in (telemetry.get("psram_bytes"), mem_map.get("psram_bytes")):
                if byte_candidate is not None:
                    ram_kb = _coerce_int(byte_candidate, 0) // 1024
                    break
        if ram_kb is None:
            ram_kb = 32_768
        self._total_ram_kb = max(0, ram_kb)

        avail_candidate = (
            telemetry.get("mem_available_kb")
            if telemetry.get("mem_available_kb") is not None
            else mem_map.get("available_kb")
        )
        default_avail = (
            max(0, self._total_ram_kb - 1024) if self._total_ram_kb > 1024 else self._total_ram_kb
        )
        avail_kb = (
            _coerce_int(avail_candidate, self._total_ram_kb)
            if avail_candidate is not None
            else default_avail
        )

        # Thermal sensor
        temp_candidate = None
        for cand in (
            telemetry.get("thermal_c"),
            telemetry.get("temp_c"),
            telemetry.get("soc_temp_c"),
            thermal_map.get("soc_c"),
        ):
            if cand is not None:
                temp_candidate = cand
                break
        if temp_candidate is not None:
            temp_c = _coerce_float(temp_candidate, 0.0)
            self._existing_paths.add("/sys/class/thermal/thermal_zone0")
            self._files["/sys/class/thermal/thermal_zone0/type"] = "esp32p4-tsens"
            self._files["/sys/class/thermal/thermal_zone0/temp"] = str(int(round(temp_c * 1000.0)))

        # SDMMC storage & /proc/mounts
        mount_lines: list[str] = []
        block_devices: list[dict[str, Any]] = []
        raw_blocks = telemetry.get("block_devices")
        sd_raw = (
            telemetry.get("sd_storage")
            or telemetry.get("sdmmc")
            or telemetry.get("sd")
        )
        if isinstance(sd_raw, Mapping):
            sd_size_bytes = 0
            if sd_raw.get("size_bytes") is not None:
                sd_size_bytes = _coerce_int(sd_raw.get("size_bytes"), 0)
            elif sd_raw.get("size_gib") is not None:
                sd_size_bytes = int(round(_coerce_float(sd_raw.get("size_gib"), 0.0) * (1024**3)))
            elif sd_raw.get("size_mib") is not None:
                sd_size_bytes = int(round(_coerce_float(sd_raw.get("size_mib"), 0.0) * (1024**2)))

            explicit_present = sd_raw.get("present")
            sd_present = (
                bool(explicit_present)
                if explicit_present is not None
                else bool(sd_raw.get("device") or sd_size_bytes > 0)
            )
            if sd_present:
                sd_dev_raw = str(sd_raw.get("device") or "/dev/mmcblk0").strip()
                sd_name = os.path.basename(sd_dev_raw.rstrip("/")) or "mmcblk0"
                sd_dev = sd_dev_raw if sd_dev_raw and sd_dev_raw != "/" else f"/dev/{sd_name}"
                sd_bus = str(sd_raw.get("bus") or "sdmmc")
                sd_mp = str(sd_raw["mountpoint"]) if sd_raw.get("mountpoint") else None
                sd_fs = str(sd_raw["fstype"]) if sd_raw.get("fstype") else None
                sd_mounted = (
                    bool(sd_raw["mounted"])
                    if sd_raw.get("mounted") is not None
                    else bool(sd_mp)
                )
                sd_label = str(sd_raw["label"]) if sd_raw.get("label") else None

                self._existing_paths.add(f"/sys/block/{sd_name}")
                self._files[f"/sys/block/{sd_name}/size"] = str(sd_size_bytes // 512)

                part_name = format_sd_partition_name(sd_name)
                part_path = f"/dev/{part_name}"
                child_entry: dict[str, Any] = {
                    "name": part_name,
                    "path": part_path,
                    "size": sd_size_bytes,
                    "type": "part",
                    "fstype": sd_fs,
                    "label": sd_label,
                    "mountpoint": sd_mp if sd_mounted else None,
                }
                disk_entry: dict[str, Any] = {
                    "name": sd_name,
                    "path": sd_dev,
                    "size": sd_size_bytes,
                    "type": "disk",
                    "tran": sd_bus,
                    "rota": False,
                    "fstype": None,
                    "label": sd_label,
                    "mountpoint": None,
                    "children": [child_entry],
                }
                block_devices.append(disk_entry)
                if sd_mounted and sd_mp:
                    eff_fs = sd_fs or "vfat"
                    mount_lines.append(f"{part_path} {sd_mp} {eff_fs} rw,relatime 0 0")
                    self._mounts.add(sd_mp)
                    self._mount_fstypes[sd_mp.rstrip("/") or "/"] = eff_fs
        elif isinstance(raw_blocks, list):
            block_devices = [dict(b) for b in raw_blocks if isinstance(b, Mapping)]
            for bd in block_devices:
                bd_mp = bd.get("mountpoint")
                bd_fs = bd.get("fstype")
                bd_path = str(bd.get("path") or f"/dev/{bd.get('name', 'mmcblk0')}")
                if isinstance(bd_mp, str) and bd_mp.strip():
                    mount_lines.append(
                        f"{bd_path} {bd_mp} {str(bd_fs or 'vfat')} rw,relatime 0 0"
                    )
                    self._mounts.add(bd_mp)
                    self._mount_fstypes[bd_mp.rstrip("/") or "/"] = str(bd_fs or "vfat")
                children = bd.get("children")
                if isinstance(children, list):
                    for ch in children:
                        if not isinstance(ch, Mapping):
                            continue
                        ch_mp = ch.get("mountpoint")
                        ch_fs = ch.get("fstype")
                        ch_path = str(ch.get("path") or f"/dev/{ch.get('name', 'mmcblk0p1')}")
                        if isinstance(ch_mp, str) and ch_mp.strip():
                            mount_lines.append(
                                f"{ch_path} {ch_mp} {str(ch_fs or 'vfat')} rw,relatime 0 0"
                            )
                            self._mounts.add(ch_mp)
                            self._mount_fstypes[ch_mp.rstrip("/") or "/"] = str(ch_fs or "vfat")

        # Network interfaces & ESP32-C6 wireless coprocessor
        wifi_raw = (
            telemetry.get("wireless_coprocessor")
            or telemetry.get("c6_sdio")
            or telemetry.get("wifi")
        )
        wifi_map: Mapping[str, Any] = wifi_raw if isinstance(wifi_raw, Mapping) else {}
        c6_disabled = bool(telemetry.get("c6_sdio_disabled")) or bool(
            wifi_map.get("disabled_by_quirk")
        )

        ip_ifaces: list[dict[str, Any]] = []
        raw_ifaces = (
            telemetry.get("interfaces")
            if isinstance(telemetry.get("interfaces"), list)
            else net_map.get("interfaces")
        )
        if isinstance(raw_ifaces, list):
            for entry in raw_ifaces:
                if isinstance(entry, Mapping):
                    norm = _normalize_iface_entry(entry)
                    if norm["ifname"]:
                        ip_ifaces.append(norm)
        else:
            flat_nic = telemetry.get("nic_name") or net_map.get("nic_name")
            flat_ip = telemetry.get("ipv4") or net_map.get("ipv4") or net_map.get("ip")
            if flat_nic or flat_ip:
                ip_ifaces.append(
                    _normalize_iface_entry(
                        {
                            "ifname": str(flat_nic or "wlan0"),
                            "operstate": str(
                                telemetry.get("nic_operstate")
                                or net_map.get("operstate")
                                or "UP"
                            ),
                            "ipv4": flat_ip,
                        }
                    )
                )

        if c6_disabled:
            self._files["/etc/rvdk/c6-sdio.env"] = (
                'RVDK_C6_SDIO_ENABLED="false"\n'
                'RVDK_C6_SDIO_TRANSPORT="disabled"\n'
                'RVDK_C6_SDIO_SLAVE_TARGET="none"\n'
            )
        elif wifi_map:
            w_present = (
                bool(wifi_map["present"]) if wifi_map.get("present") is not None else False
            )
            w_chip = str(wifi_map.get("chip") or "esp32-c6")
            w_transport = str(wifi_map.get("transport") or "sdio")
            w_slave = "esp32c6" if w_chip.lower() == "esp32-c6" else w_chip
            w_iface = (
                str(wifi_map["interface"])
                if wifi_map.get("interface")
                else ("wlan0" if w_present else None)
            )
            w_state = str(wifi_map.get("operstate") or "UP").upper()
            if w_present:
                self._existing_paths.add("/sys/bus/sdio/devices/mmc1:0001:1")
                self._files["/sys/bus/sdio/devices/mmc1:0001:1/uevent"] = (
                    "SDIO_CLASS=07\nDRIVER=esp_hosted\n"
                )
                self._files["/etc/rvdk/c6-sdio.env"] = (
                    'RVDK_C6_SDIO_ENABLED="true"\n'
                    f'RVDK_C6_SDIO_TRANSPORT="{w_transport}"\n'
                    f'RVDK_C6_SDIO_SLAVE_TARGET="{w_slave}"\n'
                )
                if w_iface:
                    self._existing_paths.add(f"/sys/class/net/{w_iface}/wireless")
                    if not any(item["ifname"] == w_iface for item in ip_ifaces):
                        ip_ifaces.append(
                            _normalize_iface_entry(
                                {
                                    "ifname": w_iface,
                                    "operstate": w_state,
                                    "ipv4": wifi_map.get("ipv4"),
                                }
                            )
                        )

        ip_routes: list[dict[str, Any]] = []
        raw_routes = (
            telemetry.get("routes")
            if isinstance(telemetry.get("routes"), list)
            else net_map.get("routes")
        )
        if isinstance(raw_routes, list):
            ip_routes = [dict(r) for r in raw_routes if isinstance(r, Mapping)]
        else:
            default_dev = net_map.get("default_dev") or telemetry.get("default_dev")
            if isinstance(default_dev, str) and default_dev.strip():
                ip_routes.append({"dst": "default", "dev": default_dev.strip()})
            elif ip_ifaces:
                preferred = next(
                    (
                        i
                        for i in ip_ifaces
                        if i["operstate"] == "UP" and has_global_ipv4(i)
                    ),
                    next((i for i in ip_ifaces if i["operstate"] == "UP"), ip_ifaces[0]),
                )
                ip_routes.append({"dst": "default", "dev": preferred["ifname"]})

        # Virtual files & baseline sysctls (nommu / RTOS defaults)
        uptime_sec = _coerce_float(telemetry.get("uptime_seconds"), 0.0)
        dns_list = net_map.get("dns") or telemetry.get("dns")
        if isinstance(dns_list, list):
            resolv_text = "\n".join(f"nameserver {d}" for d in dns_list if d) + "\n"
        else:
            resolv_text = str(telemetry.get("resolv_conf") or "")

        self._files.update(
            {
                "/proc/device-tree/model": dt_model + "\x00",
                "/proc/cpuinfo": cpuinfo_text,
                "/proc/meminfo": (
                    f"MemTotal:       {self._total_ram_kb} kB\n"
                    f"MemAvailable:   {avail_kb} kB\n"
                ),
                "/proc/uptime": f"{uptime_sec:.2f} 0.00\n",
                "/proc/cmdline": str(
                    telemetry.get("proc_cmdline") or f"console=usb_serial_jtag arch={self._arch}"
                ),
                "/proc/mounts": ("\n".join(mount_lines) + "\n") if mount_lines else "",
                "/etc/os-release": os_release,
                "/etc/resolv.conf": resolv_text,
            }
        )
        self._existing_paths.update(self._files.keys())

        raw_load = telemetry.get("loadavg")
        if "loadavg" in telemetry and raw_load is None:
            self._loadavg: tuple[float, float, float] | None = None
        elif isinstance(raw_load, Sequence) and len(raw_load) >= 3:
            self._loadavg = (
                _coerce_float(raw_load[0], 0.0),
                _coerce_float(raw_load[1], 0.0),
                _coerce_float(raw_load[2], 0.0),
            )
        else:
            self._loadavg = (0.05, 0.03, 0.01)

        raw_dmesg = telemetry.get("dmesg")
        if isinstance(raw_dmesg, list):
            dmesg_stdout = "\n".join(str(line) for line in raw_dmesg)
        elif isinstance(raw_dmesg, str):
            dmesg_stdout = raw_dmesg
        else:
            dmesg_stdout = ""

        usb_topology = str(
            telemetry.get("usb_topology")
            or "/:  Bus 01.Port 1: Dev 1, Class=root_hub, Driver=usb-serial-jtag, 12M\n"
        )

        self._commands = {
            ("lsblk", "-J"): CommandResult(stdout=json.dumps({"blockdevices": block_devices})),
            ("lsusb", "-t"): CommandResult(stdout=usb_topology.strip()),
            ("lspci", "-nn"): CommandResult(stdout=""),
            ("ip", "-j", "addr", "show"): CommandResult(stdout=json.dumps(ip_ifaces)),
            ("ip", "-j", "route", "show"): CommandResult(stdout=json.dumps(ip_routes)),
            ("dmesg",): CommandResult(stdout=dmesg_stdout),
        }

    def read_text(self, path: str) -> str | None:
        val = self._files.get(path)
        return val.strip() if val is not None else None

    def path_exists(self, path: str) -> bool:
        return path in self._existing_paths or path in self._files

    def is_mount(self, path: str) -> bool:
        return path in self._mounts

    def glob_paths(self, pattern: str) -> list[str]:
        candidates = self._existing_paths | set(self._files.keys())
        return sorted(p for p in candidates if fnmatch.fnmatch(p, pattern))

    def run_cmd(
        self,
        cmd: Sequence[str],
        *,
        use_sudo: bool = False,
        timeout: float = 15.0,
    ) -> CommandResult:
        del use_sudo, timeout
        key = tuple(cmd)
        if len(key) == 5 and key[:4] == ("findmnt", "-n", "-o", "FSTYPE"):
            target = key[4].rstrip("/") or "/"
            fstype = self._mount_fstypes.get(target)
            if fstype:
                return CommandResult(stdout=fstype)
            return CommandResult(stdout="", stderr="", returncode=1)
        if key in self._commands:
            return self._commands[key]
        for registered, result in self._commands.items():
            if len(key) >= len(registered) and key[: len(registered)] == registered:
                return result
        return CommandResult(stdout="", stderr="", returncode=1)

    def get_loadavg(self) -> tuple[float, float, float] | None:
        return self._loadavg

    def get_total_ram_kb(self) -> int:
        return self._total_ram_kb

    def get_hostname(self) -> str:
        return self._hostname

    def get_fqdn(self) -> str:
        return self._fqdn

    def get_architecture(self) -> str:
        return self._arch

    def get_kernel_release(self) -> str:
        return self._kernel_release

    def get_uname(self) -> dict[str, str]:
        return {
            "system": "RTOS" if "esp-idf" in self._kernel_release.lower() else "Linux",
            "node": self._hostname,
            "release": self._kernel_release,
            "version": "#1 ESP32-P4 Host-Proxied CTD",
            "machine": self._arch,
        }

    def sleep(self, seconds: float) -> None:
        del seconds


def load_esp32p4_telemetry_probe(path: Path | str) -> HostProxiedTelemetryProbe:
    """Load an ESP32-P4 telemetry JSON file into a HostProxiedTelemetryProbe."""
    file_path = Path(path)
    raw_text = file_path.read_text(encoding="utf-8")
    parsed: Any = json.loads(raw_text)
    if not isinstance(parsed, dict):
        raise ValueError(f"Telemetry JSON in {file_path} must be a top-level JSON object")
    return HostProxiedTelemetryProbe(parsed)


MAX_SERIAL_BUFFER_BYTES: int = 1_048_576
_MAX_SERIAL_DISCARDED_BYTES: int = 16 * MAX_SERIAL_BUFFER_BYTES
_JSON_WHITESPACE_BYTES: frozenset[int] = frozenset({0x20, 0x09, 0x0D, 0x0A})


def _try_parse_json_object(candidate: str) -> dict[str, object] | None:
    stripped = candidate.strip()
    if not stripped:
        return None
    start = stripped.find("{")
    if start == -1:
        return None
    snippet = stripped[start:]
    try:
        parsed: Any = json.loads(snippet)
    except json.JSONDecodeError:
        return None
    if isinstance(parsed, dict):
        return {str(k): v for k, v in parsed.items()}
    return None


def capture_serial_telemetry_json(
    port: str,
    baud: int = 115200,
    timeout_sec: float = 10.0,
) -> dict[str, object]:
    """Read-only capture of a single ESP32-P4 JSON telemetry object over a POSIX serial port."""
    if sys.platform == "win32":
        raise RuntimeError("Read-only serial capture requires POSIX termios support")
    import termios

    if baud <= 0:
        raise ValueError(f"Invalid serial baud rate: {baud}")
    baud_const = getattr(termios, f"B{baud}", None)
    if not isinstance(baud_const, int):
        raise ValueError(f"Unsupported serial baud rate: {baud}")

    try:
        fd = os.open(port, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
    except OSError as exc:
        raise RuntimeError(f"Unable to open serial port {port!r}: {exc}") from exc

    old_attrs: list[Any] | None = None
    try:
        try:
            old_attrs = list(termios.tcgetattr(fd))
        except termios.error:
            old_attrs = None

        if old_attrs is not None:
            new_attrs: list[Any] = list(old_attrs)
            new_attrs[0] = 0
            new_attrs[1] = 0
            new_attrs[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
            new_attrs[3] = 0
            new_attrs[4] = baud_const
            new_attrs[5] = baud_const
            cc = list(old_attrs[6])
            cc[termios.VMIN] = 0
            cc[termios.VTIME] = 0
            new_attrs[6] = cc
            termios.tcsetattr(fd, termios.TCSANOW, new_attrs)

        deadline = time.monotonic() + max(0.05, timeout_sec)
        buf = bytearray()
        total_discarded = 0
        scan_idx = 0
        candidate_start: int | None = None
        awaiting_key_or_close = False
        brace_depth = 0
        in_string = False
        escape = False

        def _reject_candidate(*, resume_at: int) -> None:
            nonlocal scan_idx, candidate_start, awaiting_key_or_close, brace_depth
            nonlocal in_string, escape
            scan_idx = resume_at
            candidate_start = None
            awaiting_key_or_close = False
            brace_depth = 0
            in_string = False
            escape = False

        def _scan_buf_for_json() -> dict[str, object] | None:
            nonlocal scan_idx, candidate_start, awaiting_key_or_close, brace_depth
            nonlocal in_string, escape
            n = len(buf)
            while scan_idx < n:
                if candidate_start is None:
                    next_open = buf.find(b"{", scan_idx)
                    if next_open == -1:
                        scan_idx = n
                        return None
                    candidate_start = next_open
                    awaiting_key_or_close = True
                    brace_depth = 1
                    in_string = False
                    escape = False
                    scan_idx = next_open + 1
                    continue

                byte = buf[scan_idx]
                if awaiting_key_or_close:
                    if byte in _JSON_WHITESPACE_BYTES:
                        scan_idx += 1
                        continue
                    if byte == 0x22:  # '"'
                        awaiting_key_or_close = False
                        in_string = True
                        scan_idx += 1
                        continue
                    if byte == 0x7D:  # '}'
                        awaiting_key_or_close = False
                        brace_depth = 0
                        scan_idx += 1
                        snippet = buf[candidate_start:scan_idx].decode("utf-8", errors="replace")
                        parsed_obj = _try_parse_json_object(snippet)
                        if parsed_obj is not None:
                            return parsed_obj
                        _reject_candidate(resume_at=candidate_start + 1)
                        continue
                    # Violates RFC 8259 rule (a): object opening '{' + ws must see '"' or '}'
                    _reject_candidate(resume_at=scan_idx)
                    continue

                if in_string:
                    if byte < 0x20:
                        # Violates RFC 8259 rule (b): unescaped control char inside JSON string
                        _reject_candidate(resume_at=candidate_start + 1)
                        continue
                    scan_idx += 1
                    if escape:
                        escape = False
                    elif byte == 0x5C:  # '\\'
                        escape = True
                    elif byte == 0x22:  # '"'
                        in_string = False
                    continue

                scan_idx += 1
                if byte == 0x22:  # '"'
                    in_string = True
                elif byte == 0x7B:  # '{'
                    brace_depth += 1
                elif byte == 0x7D:  # '}'
                    brace_depth -= 1
                    if brace_depth == 0:
                        snippet = buf[candidate_start:scan_idx].decode("utf-8", errors="replace")
                        parsed_obj = _try_parse_json_object(snippet)
                        if parsed_obj is not None:
                            return parsed_obj
                        _reject_candidate(resume_at=candidate_start + 1)
            return None

        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            readable, _, _ = select.select([fd], [], [], remaining)
            if not readable:
                break
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            except OSError as exc:
                raise RuntimeError(f"Serial read failed on {port!r}: {exc}") from exc

            if not chunk:
                for _ in range(32):
                    if candidate_start is None:
                        break
                    tail = buf[candidate_start:].decode("utf-8", errors="replace")
                    parsed_tail = _try_parse_json_object(tail)
                    if parsed_tail is not None:
                        return parsed_tail
                    _reject_candidate(resume_at=candidate_start + 1)
                    parsed_next = _scan_buf_for_json()
                    if parsed_next is not None:
                        return parsed_next
                break

            if len(buf) + len(chunk) > MAX_SERIAL_BUFFER_BYTES:
                raise ValueError(
                    f"Serial telemetry buffer exceeded {MAX_SERIAL_BUFFER_BYTES} bytes on {port!r}"
                )

            buf.extend(chunk)
            parsed_obj = _scan_buf_for_json()
            if parsed_obj is not None:
                return parsed_obj

            # Discard complete newline-delimited non-JSON log lines when no candidate is open
            if candidate_start is None and scan_idx > 0:
                last_nl = buf.rfind(b"\n", 0, scan_idx)
                if last_nl != -1:
                    discard = last_nl + 1
                    total_discarded += discard
                    del buf[:discard]
                    scan_idx -= discard
                    if total_discarded > _MAX_SERIAL_DISCARDED_BYTES:
                        raise ValueError(
                            f"Serial telemetry stream exceeded {_MAX_SERIAL_DISCARDED_BYTES} bytes "
                            f"without valid JSON on {port!r}"
                        )

        raise ValueError(
            f"No valid JSON telemetry payload received from {port!r} within {timeout_sec:.1f}s"
        )
    finally:
        if old_attrs is not None:
            try:
                termios.tcsetattr(fd, termios.TCSANOW, old_attrs)
            except termios.error:
                pass
        try:
            os.close(fd)
        except OSError:
            pass
