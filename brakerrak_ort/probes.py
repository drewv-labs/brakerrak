"""Read-only Linux/RISC-V hardware, kernel, PostgreSQL 18, and service probes."""

from __future__ import annotations

import glob
import json
import os
import platform
import re
import socket
import statistics
import subprocess
import time
from collections.abc import Mapping, Sequence
from typing import Any

from brakerrak_ort.profiles import (
    ACCELERATOR_PCI_CLASSES,
    DEDICATED_ACCELERATOR_VENDORS,
    GPU_ACCELERATOR_VENDORS,
)
from brakerrak_ort.types import AcceleratorInfo, CommandResult, PrimaryNicStatus, SystemProbe

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
    candidates.extend(["end0", "eth0", "enp1s0", "enp2s0", "wan"])

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
