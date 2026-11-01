#!/usr/bin/env python3
"""
DREW-V Labs // Operational Readiness Test (ORT) & CTD Provenance Snapshot
Path: drewv-labs/brakerrak/nodes/databroker/brakerbox-p550/ort-snapshot.py
Strictly Read-Only System Inspector & Quiescent Baseline Profiler.

Emits:
  1. Unredacted CTD Snapshot : brakerbox-snapshot-<stage>-<ts>-<epoch>.json
  2. Redacted Public Snapshot: brakerbox-snapshot-<stage>-<ts>-<epoch>.public.json
"""
import argparse
import copy
import datetime
import glob
import grp
import hashlib
import json
import os
import platform
import pwd
import re
import shlex
import socket
import statistics
import subprocess
import time
from collections.abc import Sequence
from typing import Any

# ANSI Colors for Console ORT Summary
C_CYAN = "\033[1;36m"
C_GREEN = "\033[1;32m"
C_YELLOW = "\033[1;33m"
C_RED = "\033[1;31m"
C_RESET = "\033[0m"

# Hardware-agnostic default: empty list unless populated via ~/.brakerrak/node.env
DEFAULT_RAID_ARRAYS: list[dict[str, Any]] = []


def resolve_real_user_home() -> str:
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        try:
            return pwd.getpwnam(sudo_user).pw_dir
        except KeyError:
            pass
    if os.path.isdir("/home/drew"):
        return "/home/drew"
    return os.path.expanduser("~")


def load_node_env(config_path: str | None = None) -> dict[str, str]:
    """Parses bash-style KEY=VALUE and multiline JSON strings from node.env."""
    candidates: list[str] = []
    if config_path:
        candidates.append(config_path)
    real_home = resolve_real_user_home()
    candidates.append(os.path.join(real_home, ".brakerrak", "node.env"))
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates.append(os.path.join(script_dir, "node.env"))

    env_map: dict[str, str] = {}
    for path in candidates:
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    lexer = shlex.shlex(f.read(), posix=True)
                    lexer.whitespace_split = True
                    lexer.commenters = "#"
                    for token in lexer:
                        if "=" in token:
                            k, v = token.split("=", 1)
                            if k.isidentifier():
                                env_map[k] = v
                break
            except Exception:
                continue
    return env_map


def get_raid_arrays_config(env_map: dict[str, str]) -> list[dict[str, Any]]:
    with_raid = (os.environ.get("WITH_RAID") or env_map.get("WITH_RAID") or "false").lower()
    if with_raid != "true":
        return []
    raw_json = os.environ.get("RAID_ARRAYS_JSON") or env_map.get("RAID_ARRAYS_JSON")
    if raw_json:
        try:
            parsed = json.loads(raw_json)
            if isinstance(parsed, list):
                return parsed
        except Exception:
            pass
    return DEFAULT_RAID_ARRAYS


def run_cmd(cmd: list[str], use_sudo: bool = False) -> str:
    if use_sudo and os.geteuid() != 0:
        cmd = ["sudo", "-n"] + cmd
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return res.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"


def read_sysfs(path: str) -> str | None:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return None


def sample_quiescent_metrics(duration_sec: float = 5.0, interval_sec: float = 0.5) -> dict[str, Any]:
    """Samples clocks, thermals, fan RPM, loadavg, and memory over a time window."""
    samples = max(1, int(duration_sec / interval_sec))
    cpu_freqs: dict[str, list[float]] = {}
    thermals: dict[str, list[float]] = {}
    fan_rpms: list[int] = []
    load_1m: list[float] = []
    mem_avail_kb: list[int] = []

    freq_paths = sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"))
    if not freq_paths:
        freq_paths = sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_cur_freq"))

    tz_paths = sorted(glob.glob("/sys/class/thermal/thermal_zone*"))
    fan_paths = sorted(glob.glob("/sys/class/hwmon/hwmon*/fan*_input"))

    for _ in range(samples):
        for fp in freq_paths:
            cpu_id = fp.split("/")[5]
            val = read_sysfs(fp)
            if val and val.isdigit():
                cpu_freqs.setdefault(cpu_id, []).append(round(int(val) / 1000.0, 2))

        for tz in tz_paths:
            tz_name = read_sysfs(f"{tz}/type") or os.path.basename(tz)
            t_val = read_sysfs(f"{tz}/temp")
            if t_val and t_val.lstrip("-").isdigit():
                thermals.setdefault(tz_name, []).append(round(int(t_val) / 1000.0, 2))

        for fp in fan_paths:
            f_val = read_sysfs(fp)
            if f_val and f_val.isdigit():
                fan_rpms.append(int(f_val))

        try:
            load_1m.append(round(os.getloadavg()[0], 4))
        except OSError:
            pass

        meminfo = read_sysfs("/proc/meminfo") or ""
        for line in meminfo.splitlines():
            if line.startswith("MemAvailable:"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    mem_avail_kb.append(int(parts[1]))

        time.sleep(interval_sec)

    def summarize(arr: Sequence[int | float], unit: str = "") -> dict[str, Any]:
        if not arr:
            return {"min": None, "mean": None, "max": None, "samples": 0, "unit": unit}
        return {
            "min": round(min(arr), 2),
            "mean": round(float(statistics.mean(arr)), 2),
            "max": round(max(arr), 2),
            "samples": len(arr),
            "unit": unit,
        }

    return {
        "window_seconds": duration_sec,
        "sample_interval_seconds": interval_sec,
        "cpu_frequency_mhz": {k: summarize(v, "MHz") for k, v in cpu_freqs.items()},
        "thermal_zones_celsius": {k: summarize(v, "C") for k, v in thermals.items()},
        "som_fan_rpm": summarize(fan_rpms, "RPM"),
        "loadavg_1m": summarize(load_1m, "load"),
        "mem_available_kb": summarize(mem_avail_kb, "kB"),
    }


def inspect_postgres_state() -> dict[str, Any]:
    """Read-only check of PostgreSQL state and custom tablespaces."""
    psql_ver = run_cmd(["psql", "--version"])
    service_active = run_cmd(["systemctl", "is-active", "postgresql"]) == "active"
    pg_settings: dict[str, str] = {}
    tablespaces: list[str] = []
    if service_active:
        for param in [
            "server_version",
            "data_directory",
            "io_method",
            "shared_buffers",
            "effective_cache_size",
            "work_mem",
            "maintenance_work_mem",
            "wal_compression",
            "random_page_cost",
            "effective_io_concurrency",
        ]:
            val = run_cmd(["sudo", "-n", "-u", "postgres", "psql", "-tAc", f"SHOW {param};"])
            if not val.startswith("ERROR:"):
                pg_settings[param] = val

        ts_raw = run_cmd([
            "sudo", "-n", "-u", "postgres", "psql", "-tAc",
            "SELECT spcname FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global') ORDER BY spcname;"
        ])
        if ts_raw and not ts_raw.startswith("ERROR:"):
            tablespaces = [line.strip() for line in ts_raw.splitlines() if line.strip()]

    return {
        "psql_client_version": psql_ver if not psql_ver.startswith("ERROR:") else "not_installed",
        "systemd_service_active": service_active,
        "active_runtime_parameters": pg_settings,
        "custom_tablespaces": tablespaces,
    }


def inspect_databroker_services(env_map: dict[str, str]) -> dict[str, Any]:
    """Read-only check of Mosquitto MQTT broker and NFSv4 server state."""
    mqtt_active = run_cmd(["systemctl", "is-active", "mosquitto"]) == "active"
    mqtt_port = int(env_map.get("MQTT_PORT", "1883"))
    nfs_active = run_cmd(["systemctl", "is-active", "nfs-kernel-server"]) == "active"
    exports_raw = read_sysfs("/etc/exports") or ""
    active_exports = [
        line.strip()
        for line in exports_raw.splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    return {
        "mosquitto_mqtt": {
            "systemd_service_active": mqtt_active,
            "configured_port": mqtt_port,
        },
        "nfs_v4_server": {
            "systemd_service_active": nfs_active,
            "configured_exports": active_exports,
        },
    }


def redact_block_tree(devices: list[dict[str, Any]]) -> None:
    """Recursively redacts serial numbers and UUIDs across block devices and child partitions."""
    for dev in devices:
        if dev.get("serial") is not None:
            dev["serial"] = "REDACTED"
        if dev.get("uuid") is not None:
            dev["uuid"] = "REDACTED"
        children = dev.get("children")
        if isinstance(children, list):
            redact_block_tree(children)


def build_public_snapshot(raw_payload: dict[str, Any], raw_sha256: str, end0_up: bool) -> dict[str, Any]:
    """Constructs a GitHub-safe redacted copy of the CTD snapshot payload."""
    pub = copy.deepcopy(raw_payload)
    pub.pop("provenance_signature", None)

    hw = pub.get("hardware_inventory", {})
    if isinstance(hw.get("nvme_primary"), dict) and hw["nvme_primary"].get("serial") is not None:
        hw["nvme_primary"]["serial"] = "REDACTED"

    raid_arrays = hw.get("usb_raid_arrays", {})
    if isinstance(raid_arrays, dict):
        for arr_entry in raid_arrays.values():
            if isinstance(arr_entry, dict):
                for disk in arr_entry.get("detected_disks", []):
                    if isinstance(disk, dict) and disk.get("serial") is not None:
                        disk["serial"] = "REDACTED"

    if isinstance(hw.get("block_devices"), list):
        redact_block_tree(hw["block_devices"])

    pub["network_topology"] = {
        "hostname": raw_payload.get("network_topology", {}).get("hostname"),
        "primary_nic_end0_operstate": "UP" if end0_up else "DOWN",
    }

    pub.pop("security_and_users", None)

    proc_count = raw_payload.get("runtime_processes", {}).get("total_process_count", 0)
    pub["runtime_processes"] = {"total_process_count": proc_count}

    if isinstance(pub.get("software_provenance"), dict):
        pub["software_provenance"].pop("installed_apt_packages", None)

    pub_bytes = json.dumps(pub, sort_keys=True, separators=(",", ":")).encode("utf-8")
    pub_sha256 = hashlib.sha256(pub_bytes).hexdigest()
    pub["provenance_signature"] = {
        "algorithm": "SHA-256",
        "canonical_payload_sha256": pub_sha256,
        "unredacted_vault_sha256": raw_sha256,
        "redacted_for_public_repo": True,
    }
    return pub


def ensure_snapshots_gitignore(out_dir: str) -> None:
    """Ensures snapshots/.gitignore protects raw JSON files while allowing *.public.json."""
    if os.path.basename(os.path.abspath(out_dir)) == "snapshots":
        gitignore_path = os.path.join(out_dir, ".gitignore")
        if not os.path.exists(gitignore_path):
            with open(gitignore_path, "w", encoding="utf-8") as f:
                f.write(
                    "# Ignore unredacted CTD snapshots containing hardware serials and network topology\n"
                    "brakerbox-snapshot-*.json\n"
                    "!brakerbox-snapshot-*.public.json\n"
                )


def main() -> None:
    parser = argparse.ArgumentParser(description="DREW-V Labs Read-Only ORT & CTD Snapshot Generator")
    parser.add_argument(
        "--stage",
        default="day0-pre-forge",
        help="Lifecycle stage tag (e.g., day0-pre-forge, day1-post-forge, converged-idempotent)",
    )
    parser.add_argument(
        "--out-dir",
        default="/home/drew" if os.path.isdir("/home/drew") else os.path.expanduser("~"),
        help="Directory to write the output JSON snapshot",
    )
    parser.add_argument(
        "--config",
        default=None,
        help="Optional path to node.env configuration file",
    )
    parser.add_argument(
        "--window",
        type=float,
        default=5.0,
        help="Quiescent profiling window in seconds (default: 5.0)",
    )
    parser.add_argument(
        "--no-public",
        action="store_true",
        help="Skip generating the redacted .public.json companion manifest",
    )
    args = parser.parse_args()

    node_env = load_node_env(args.config)
    raid_arrays_cfg = get_raid_arrays_config(node_env)

    now_utc = datetime.datetime.now(datetime.UTC)
    epoch_sec = int(now_utc.timestamp())
    iso_compact = now_utc.strftime("%Y%m%dT%H%M%SZ")
    iso_full = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    safe_stage = re.sub(r"[^a-zA-Z0-9_-]", "-", args.stage)
    os.makedirs(args.out_dir, exist_ok=True)
    ensure_snapshots_gitignore(args.out_dir)

    base_stem = f"brakerbox-snapshot-{safe_stage}-{iso_compact}-{epoch_sec}"
    out_file = os.path.join(args.out_dir, f"{base_stem}.json")
    public_out_file = os.path.join(args.out_dir, f"{base_stem}.public.json")

    print(f"{C_CYAN}======================================================================{C_RESET}")
    print(f"{C_CYAN} DREW-V Labs // Operational Readiness Test (ORT) & CTD Snapshot{C_RESET}")
    print(f" Stage     : {args.stage}")
    print(f" Timestamp : {iso_full} (Epoch: {epoch_sec})")
    print(f" Target    : {socket.gethostname()} ({platform.machine()})")
    print(f"{C_CYAN}======================================================================{C_RESET}")

    print(f"\n[*] Running {args.window:.1f}-second Quiescent Baseline Profiling (@ 2Hz)...")
    quiescent = sample_quiescent_metrics(args.window, 0.5)

    # --- Silicon & Cache Topology ---
    cpuinfo_raw = read_sysfs("/proc/cpuinfo") or ""
    harts: list[dict[str, str]] = []
    current_hart: dict[str, str] = {}
    for line in cpuinfo_raw.splitlines():
        if not line.strip():
            if current_hart:
                harts.append(current_hart)
                current_hart = {}
            continue
        if ":" in line:
            k, v = [x.strip() for x in line.split(":", 1)]
            current_hart[k] = v
    if current_hart:
        harts.append(current_hart)

    caches = []
    for cdir in sorted(glob.glob("/sys/devices/system/cpu/cpu0/cache/index*")):
        caches.append({
            "index": os.path.basename(cdir),
            "level": read_sysfs(f"{cdir}/level"),
            "type": read_sysfs(f"{cdir}/type"),
            "size": read_sysfs(f"{cdir}/size"),
            "ways_of_associativity": read_sysfs(f"{cdir}/ways_of_associativity"),
            "coherency_line_size": read_sysfs(f"{cdir}/coherency_line_size"),
            "shared_cpu_list": read_sysfs(f"{cdir}/shared_cpu_list"),
        })

    # --- PCIe & NVMe Inspection ---
    nvme_dev = node_env.get("NVME_DEV", "/dev/nvme0n1")
    nvme_short = os.path.basename(nvme_dev)
    nvme_ctrl = re.sub(r"n[0-9]+$", "", nvme_short)
    nvme_present = os.path.exists(f"/sys/block/{nvme_short}")
    nvme_info = {
        "device": nvme_dev if nvme_present else None,
        "model": read_sysfs(f"/sys/block/{nvme_short}/device/model"),
        "serial": read_sysfs(f"/sys/block/{nvme_short}/device/serial"),
        "firmware_rev": read_sysfs(f"/sys/block/{nvme_short}/device/firmware_rev"),
        "pcie_link_speed": read_sysfs(f"/sys/class/nvme/{nvme_ctrl}/device/current_link_speed"),
        "pcie_link_width": read_sysfs(f"/sys/class/nvme/{nvme_ctrl}/device/current_link_width"),
        "max_link_speed": read_sysfs(f"/sys/class/nvme/{nvme_ctrl}/device/max_link_speed"),
        "max_link_width": read_sysfs(f"/sys/class/nvme/{nvme_ctrl}/device/max_link_width"),
        "logical_block_size_bytes": read_sysfs(f"/sys/block/{nvme_short}/queue/logical_block_size"),
        "physical_block_size_bytes": read_sysfs(f"/sys/block/{nvme_short}/queue/physical_block_size"),
        "size_bytes": int(read_sysfs(f"/sys/block/{nvme_short}/size") or 0) * 512 if nvme_present else 0,
    }

    # --- Block Devices & Dynamic USB RAID Enclosure Discovery ---
    lsblk_raw = run_cmd([
        "lsblk", "-J", "-b", "-o",
        "NAME,PATH,SIZE,TYPE,TRAN,VENDOR,MODEL,SERIAL,REV,LOG-SEC,PHY-SEC,FSTYPE,LABEL,PARTLABEL,UUID,MOUNTPOINT"
    ])
    try:
        block_devices = json.loads(lsblk_raw).get("blockdevices", [])
    except Exception:
        block_devices = []

    usb_raid_arrays: dict[str, dict[str, Any]] = {}
    raid_ort_checks: list[dict[str, Any]] = []

    for idx, arr_cfg in enumerate(raid_arrays_cfg, start=4):
        arr_name = str(arr_cfg.get("name", f"Array{idx}"))
        arr_id = str(arr_cfg.get("id") or arr_name.lower())
        arr_type = str(arr_cfg.get("type", "vault"))
        arr_label = str(arr_cfg.get("label", ""))
        arr_mount = str(arr_cfg.get("mount", ""))
        expected_disks = int(arr_cfg.get("disks", 4))
        min_b = int(arr_cfg.get("min_bytes", 0))
        max_b = int(arr_cfg.get("max_bytes", 0))

        matched_disks: list[dict[str, Any]] = []
        for bd in block_devices:
            if bd.get("type") == "disk":
                sz = int(bd.get("size") or 0)
                if min_b <= sz <= max_b:
                    matched_disks.append({
                        "path": bd.get("path"),
                        "size_bytes": sz,
                        "model": bd.get("model"),
                        "serial": bd.get("serial"),
                        "tran": bd.get("tran"),
                    })

        usb_raid_arrays[arr_id] = {
            "name": arr_name,
            "type": arr_type,
            "label": arr_label,
            "mount": arr_mount,
            "expected_disks": expected_disks,
            "detected_disks_count": len(matched_disks),
            "mounted": os.path.ismount(arr_mount) if arr_mount else False,
            "detected_disks": matched_disks,
        }

        chk_id = f"ORT-{idx:02d}_{re.sub(r'[^A-Z0-9]', '_', arr_name.upper())}_ARRAY_JBOD"
        raid_ort_checks.append({
            "id": chk_id,
            "description": f"{arr_name} ({arr_type}): {expected_disks}x Rotational Disks Enumerated ({arr_label})",
            "expected": expected_disks,
            "actual": len(matched_disks),
            "status": "PASS" if len(matched_disks) == expected_disks else "WARN",
        })

    lsusb_tree = run_cmd(["lsusb", "-t"])
    usb_superspeed_5000m = "5000M" in lsusb_tree
    if len(raid_arrays_cfg) > 0:
        usb_ort_idx = 4 + len(raid_ort_checks)
        raid_ort_checks.append({
            "id": f"ORT-{usb_ort_idx:02d}_USB3_SUPERSPEED",
            "description": "Rear Teal USB 3.2 Gen1 Ports Negotiated at 5000M SuperSpeed",
            "expected": "5000M SuperSpeed present",
            "actual": "5000M detected" if usb_superspeed_5000m else "No 5000M devices detected",
            "status": "PASS" if usb_superspeed_5000m else "WARN",
        })

    # --- Network State ---
    ip_addr_raw = run_cmd(["ip", "-j", "addr", "show"])
    ip_route_raw = run_cmd(["ip", "-j", "route", "show"])
    try:
        net_ifaces = json.loads(ip_addr_raw)
    except Exception:
        net_ifaces = []
    try:
        net_routes = json.loads(ip_route_raw)
    except Exception:
        net_routes = []

    end0_up = any(i.get("ifname") == "end0" and i.get("operstate") == "UP" for i in net_ifaces)

    # --- Kernel Ring Buffer Bus Error Scan ---
    dmesg_raw = run_cmd(["dmesg"], use_sudo=True)
    bus_errors = []
    if not dmesg_raw.startswith("ERROR:"):
        for line in dmesg_raw.splitlines():
            if re.search(r"(pcieport.*error|AER|nvme.*error|I/O error|usb.*reset|under-voltage)", line, re.IGNORECASE):
                bus_errors.append(line)

    # --- Users, Groups & Sudoers ---
    human_users = []
    system_users_count = 0
    for u in pwd.getpwall():
        if u.pw_uid == 0 or (1000 <= u.pw_uid < 65534):
            user_groups = [g.gr_name for g in grp.getgrall() if u.pw_name in g.gr_mem]
            primary_grp = grp.getgrgid(u.pw_gid).gr_name if u.pw_gid else str(u.pw_gid)
            human_users.append({
                "username": u.pw_name,
                "uid": u.pw_uid,
                "gid": u.pw_gid,
                "primary_group": primary_grp,
                "supplementary_groups": user_groups,
                "home": u.pw_dir,
                "shell": u.pw_shell,
            })
        else:
            system_users_count += 1

    # --- Running Processes (Top 35 by RSS Memory + Summary) ---
    ps_raw = run_cmd(["ps", "-eo", "pid,ppid,user,stat,pcpu,pmem,rss,comm,args", "--sort=-rss"])
    ps_lines = ps_raw.splitlines()
    top_processes = []
    for line in ps_lines[1:36]:
        parts = line.split(None, 8)
        if len(parts) >= 9:
            top_processes.append({
                "pid": int(parts[0]),
                "ppid": int(parts[1]),
                "user": parts[2],
                "stat": parts[3],
                "cpu_pct": float(parts[4]),
                "mem_pct": float(parts[5]),
                "rss_kb": int(parts[6]),
                "comm": parts[7],
                "args": parts[8],
            })

    # --- Full APT / DPKG Package Manifest ---
    dpkg_raw = run_cmd(["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\t${Status}\n"])
    packages = []
    for line in dpkg_raw.splitlines():
        cols = line.split("\t")
        if len(cols) >= 4 and "install ok installed" in cols[3]:
            packages.append({
                "name": cols[0],
                "version": cols[1],
                "arch": cols[2],
            })
    pkg_hash = hashlib.sha256(dpkg_raw.encode("utf-8")).hexdigest()

    # --- Key Toolchain, Storage & Database State ---
    postgres_state = inspect_postgres_state()
    broker_services_state = inspect_databroker_services(node_env)
    toolchains = {
        "linux_kernel": platform.release(),
        "glibc_ldd": (run_cmd(["ldd", "--version"]).splitlines() or [""])[0],
        "systemd": (run_cmd(["systemctl", "--version"]).splitlines() or [""])[0],
        "python3": run_cmd(["python3", "--version"]),
        "gcc": (run_cmd(["gcc", "--version"]).splitlines() or ["not_installed"])[0],
        "git": run_cmd(["git", "--version"]),
        "go": run_cmd(["go", "version"]),
        "openssl": run_cmd(["openssl", "version"]),
        "postgres_psql": postgres_state["psql_client_version"],
        "nvme_cli": run_cmd(["nvme", "--version"]),
        "mdadm": (run_cmd(["mdadm", "--version"]).splitlines() or ["not_installed"])[0],
    }

    # --- Automated Operational Readiness Test (ORT) Assertions ---
    next_ort_idx = 4 + len(raid_ort_checks)
    ort_checks = [
        {
            "id": "ORT-01_CPU_HARTS",
            "description": "4x SiFive P550 Harts Online (rv64imafdc_zba_zbb)",
            "expected": 4,
            "actual": len(harts),
            "status": "PASS" if len(harts) == 4 else "FAIL",
        },
        {
            "id": "ORT-02_LPDDR5_CAPACITY",
            "description": "32GB LPDDR5 System Memory Detected (>= 30 GiB usable)",
            "expected": ">= 30000000 kB",
            "actual": f"{os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') // 1024} kB",
            "status": "PASS" if (os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") // 1024) >= 30000000 else "FAIL",
        },
        {
            "id": "ORT-03_PCIE_NVME_LINK",
            "description": "Primary NVMe Seated at PCIe Gen3 x4 (8.0 GT/s, Width x4)",
            "expected": "8.0 GT/s PCIe | x4",
            "actual": f"{nvme_info['pcie_link_speed']} | x{nvme_info['pcie_link_width']}",
            "status": "PASS" if (nvme_present and "8.0" in str(nvme_info["pcie_link_speed"]) and str(nvme_info["pcie_link_width"]) == "4") else "FAIL",
        },
        *raid_ort_checks,
        {
            "id": f"ORT-{next_ort_idx:02d}_PRIMARY_NIC_END0",
            "description": "Primary SoC NIC (end0) Carrier UP with IPv4 Lease",
            "expected": "UP",
            "actual": "UP" if end0_up else "DOWN",
            "status": "PASS" if end0_up else "FAIL",
        },
        {
            "id": f"ORT-{next_ort_idx + 1:02d}_THERMAL_IDLE_FLOOR",
            "description": "Quiescent SoC Thermal Ceiling Below 55.0 C",
            "expected": "< 55.0 C",
            "actual": f"{max([v['max'] for v in quiescent['thermal_zones_celsius'].values() if v['max'] is not None], default=0.0)} C",
            "status": "PASS" if max([v["max"] for v in quiescent["thermal_zones_celsius"].values() if v["max"] is not None], default=0.0) < 55.0 else "WARN",
        },
        {
            "id": f"ORT-{next_ort_idx + 2:02d}_KERNEL_BUS_HEALTH",
            "description": "Zero PCIe AER, NVMe I/O, or USB Bus Reset Errors in dmesg",
            "expected": 0,
            "actual": len(bus_errors),
            "status": "PASS" if len(bus_errors) == 0 else "WARN",
        },
    ]

    # --- Construct CarrierPigeons / HamStack CTD Artifact Envelope ---
    snapshot_payload: dict[str, Any] = {
        "schema_version": "drewv-ctd-manifest/v1.1",
        "artifact": {
            "id": socket.gethostname(),
            "node_group": "brakerrak-databrokers",
            "target_designation": "brakerbox-p550 (interim prod) / brakerbench-p550",
            "kind": "hardware_node_baseline_snapshot",
            "stage": args.stage,
            "captured_at_utc": iso_full,
            "captured_at_epoch": epoch_sec,
        },
        "operational_readiness_test": {
            "overall_status": (
                "PASS"
                if all(c["status"] == "PASS" for c in ort_checks)
                else ("FAIL" if any(c["status"] == "FAIL" for c in ort_checks) else "WARN")
            ),
            "assertions": ort_checks,
        },
        "quiescent_profile": quiescent,
        "hardware_inventory": {
            "device_tree_model": (read_sysfs("/proc/device-tree/model") or "").rstrip("\x00"),
            "architecture": platform.machine(),
            "cpu_harts_count": len(harts),
            "isa_string": harts[0].get("isa") if harts else None,
            "mmu_type": harts[0].get("mmu") if harts else None,
            "cpu_harts": harts,
            "cache_hierarchy": caches,
            "nvme_primary": nvme_info,
            "usb_raid_arrays": usb_raid_arrays,
            "usb_topology_tree": lsusb_tree.splitlines(),
            "pci_devices": run_cmd(["lspci", "-nn"]).splitlines(),
            "block_devices": block_devices,
        },
        "os_and_kernel_state": {
            "uname": platform.uname()._asdict(),
            "os_release": read_sysfs("/etc/os-release"),
            "proc_cmdline": read_sysfs("/proc/cmdline"),
            "uptime_seconds": float((read_sysfs("/proc/uptime") or "0 0").split()[0]),
            "systemd_default_target": run_cmd(["systemctl", "get-default"]),
            "cpufreq_governors": {
                os.path.basename(os.path.dirname(os.path.dirname(p))): read_sysfs(p)
                for p in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor"))
            },
            "sysctl_baseline": {
                k: run_cmd(["sysctl", "-n", k])
                for k in [
                    "kernel.perf_event_paranoid",
                    "kernel.kptr_restrict",
                    "kernel.io_uring_disabled",
                    "vm.nr_hugepages",
                    "vm.swappiness",
                    "vm.dirty_background_bytes",
                    "vm.dirty_bytes",
                ]
            },
            "dmesg_bus_events": bus_errors[-25:],
        },
        "postgresql_broker_state": postgres_state,
        "databroker_services_state": broker_services_state,
        "network_topology": {
            "hostname": socket.gethostname(),
            "fqdn": socket.getfqdn(),
            "interfaces": net_ifaces,
            "routes": net_routes,
            "resolv_conf": read_sysfs("/etc/resolv.conf"),
        },
        "security_and_users": {
            "human_and_root_users": human_users,
            "system_users_count": system_users_count,
            "total_groups_count": len(grp.getgrall()),
            "sudoers_dropins": [os.path.basename(p) for p in sorted(glob.glob("/etc/sudoers.d/*"))],
        },
        "runtime_processes": {
            "total_process_count": max(0, len(ps_lines) - 1),
            "top_35_by_rss_memory": top_processes,
        },
        "software_provenance": {
            "toolchains": toolchains,
            "installed_apt_packages_count": len(packages),
            "installed_apt_packages_sha256": pkg_hash,
            "installed_apt_packages": packages,
        },
    }

    # Compute Canonical SHA-256 Signature of the Unredacted Snapshot
    canonical_bytes = json.dumps(snapshot_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    manifest_sha256 = hashlib.sha256(canonical_bytes).hexdigest()
    snapshot_payload["provenance_signature"] = {
        "algorithm": "SHA-256",
        "canonical_payload_sha256": manifest_sha256,
    }

    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(snapshot_payload, f, indent=2)

    # Build and Write Redacted Public Snapshot
    public_sha256 = None
    if not args.no_public:
        public_payload = build_public_snapshot(snapshot_payload, manifest_sha256, end0_up)
        public_sha256 = public_payload["provenance_signature"]["canonical_payload_sha256"]
        with open(public_out_file, "w", encoding="utf-8") as f:
            json.dump(public_payload, f, indent=2)

    # Print Console ORT Report
    print(f"\n{C_CYAN}--- Operational Readiness Test (ORT) Assertions ---{C_RESET}")
    for chk in ort_checks:
        st = chk["status"]
        color = C_GREEN if st == "PASS" else (C_YELLOW if st == "WARN" else C_RED)
        print(f"  [{color}{st:4s}{C_RESET}] {chk['id']:26s} : {chk['actual']} (Expected: {chk['expected']})")

    print(f"\n{C_CYAN}--- {args.window:.0f}-Second Quiescent Hardware Baseline Summary ---{C_RESET}")
    for tz_name, stats in quiescent["thermal_zones_celsius"].items():
        print(f"  Thermal ({tz_name:12s}) : min={stats['min']}C | mean={stats['mean']}C | max={stats['max']}C")
    for cpu_id, stats in quiescent["cpu_frequency_mhz"].items():
        print(f"  Clock   ({cpu_id:12s}) : min={stats['min']}MHz | mean={stats['mean']}MHz | max={stats['max']}MHz")
    if quiescent["som_fan_rpm"]["samples"] > 0:
        fstats = quiescent["som_fan_rpm"]
        print(f"  Cooler  (SOM Fan     ) : min={fstats['min']} RPM | mean={fstats['mean']} RPM | max={fstats['max']} RPM")

    print(f"\n{C_GREEN}[OK] Wrote Unredacted CTD Snapshot ({os.path.getsize(out_file) // 1024} KB):{C_RESET}")
    print(f"     Path   : {out_file}")
    print(f"     SHA256 : {manifest_sha256}")
    if public_sha256:
        print(f"{C_GREEN}[OK] Wrote Redacted Public Snapshot ({os.path.getsize(public_out_file) // 1024} KB):{C_RESET}")
        print(f"     Path   : {public_out_file}")
        print(f"     SHA256 : {public_sha256}")
    print(f"{C_CYAN}======================================================================{C_RESET}")


if __name__ == "__main__":
    main()
