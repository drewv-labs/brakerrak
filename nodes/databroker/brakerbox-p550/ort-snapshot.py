#!/usr/bin/env python3
"""
DREW-V Labs // Operational Readiness Test (ORT) & CTD Provenance Snapshot
Path: drewv-labs/brakerrak/nodes/databrokers/brakerbox-p550/ort-snapshot.py
Strictly Read-Only System Inspector & Quiescent Baseline Profiler.

Usage:
  ./ort-snapshot.py                                  # Defaults to --stage day0-pre-forge
  ./ort-snapshot.py --stage day1-post-forge          # Run after forge.sh completes
  ./ort-snapshot.py --out-dir /home/drew --window 5  # Custom output dir & polling window
"""
import argparse
import datetime
import glob
import grp
import hashlib
import json
import os
import platform
import pwd
import re
import socket
import statistics
import subprocess
import time

# ANSI Colors for Console ORT Summary
C_CYAN = "\033[1;36m"
C_GREEN = "\033[1;32m"
C_YELLOW = "\033[1;33m"
C_RED = "\033[1;31m"
C_RESET = "\033[0m"


def run_cmd(cmd, use_sudo=False):
    if use_sudo and os.geteuid() != 0:
        cmd = ["sudo", "-n"] + cmd
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
        return res.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"


def read_sysfs(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return None


def sample_quiescent_metrics(duration_sec=5.0, interval_sec=0.5):
    """Samples clocks, thermals, fan RPM, loadavg, and memory over a time window."""
    samples = max(1, int(duration_sec / interval_sec))
    cpu_freqs = {}
    thermals = {}
    fan_rpms = []
    load_1m = []
    mem_avail_kb = []

    freq_paths = sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"))
    if not freq_paths:
        freq_paths = sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_cur_freq"))

    tz_paths = sorted(glob.glob("/sys/class/thermal/thermal_zone*"))
    fan_paths = sorted(glob.glob("/sys/class/hwmon/hwmon*/fan*_input"))

    for _ in range(samples):
        # 1. Per-Hart CPU Frequencies (kHz -> MHz)
        for fp in freq_paths:
            cpu_id = fp.split("/")[5]
            val = read_sysfs(fp)
            if val and val.isdigit():
                cpu_freqs.setdefault(cpu_id, []).append(round(int(val) / 1000.0, 2))

        # 2. Thermal Zones (millidegrees -> Celsius)
        for tz in tz_paths:
            tz_name = read_sysfs(f"{tz}/type") or os.path.basename(tz)
            t_val = read_sysfs(f"{tz}/temp")
            if t_val and t_val.lstrip("-").isdigit():
                thermals.setdefault(tz_name, []).append(round(int(t_val) / 1000.0, 2))

        # Also read /sys/class/hwmon/hwmon*/temp*_input when thermal_zone* is empty/absent
        for hp in sorted(glob.glob("/sys/class/hwmon/hwmon*/temp*_input")):
            hw_dir = os.path.dirname(hp)
            hw_name = read_sysfs(f"{hw_dir}/name") or os.path.basename(hw_dir)
            lbl = read_sysfs(hp.replace("_input", "_label")) or os.path.basename(hp).replace("_input", "")
            t_val = read_sysfs(hp)
            if t_val and t_val.lstrip("-").isdigit():
                thermals.setdefault(f"{hw_name}:{lbl}", []).append(round(int(t_val) / 1000.0, 2))

        # 3. Fan Tachometer RPM
        for fp in fan_paths:
            f_val = read_sysfs(fp)
            if f_val and f_val.isdigit():
                fan_rpms.append(int(f_val))

        # 4. Load Average & Memory Available
        try:
            load_1m.append(round(os.getloadavg()[0], 4))
        except Exception:
            pass

        meminfo = read_sysfs("/proc/meminfo") or ""
        for line in meminfo.splitlines():
            if line.startswith("MemAvailable:"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    mem_avail_kb.append(int(parts[1]))

        time.sleep(interval_sec)

    def summarize(arr, unit=""):
        if not arr:
            return {"min": None, "mean": None, "max": None, "samples": 0, "unit": unit}
        return {
            "min": round(min(arr), 2),
            "mean": round(statistics.mean(arr), 2),
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


def inspect_postgres_state():
    """Read-only check of PostgreSQL state (populated on post-forge runs)."""
    psql_ver = run_cmd(["psql", "--version"])
    service_active = run_cmd(["systemctl", "is-active", "postgresql"]) == "active"
    pg_settings = {}
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
    return {
        "psql_client_version": psql_ver if not psql_ver.startswith("ERROR:") else "not_installed",
        "systemd_service_active": service_active,
        "active_runtime_parameters": pg_settings,
    }


def main():
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
        "--window",
        type=float,
        default=5.0,
        help="Quiescent profiling window in seconds (default: 5.0)",
    )
    args = parser.parse_args()

    now_utc = datetime.datetime.now(datetime.UTC)
    epoch_sec = int(now_utc.timestamp())
    iso_compact = now_utc.strftime("%Y%m%dT%H%M%SZ")
    iso_full = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    safe_stage = re.sub(r"[^a-zA-Z0-9_-]", "-", args.stage)
    os.makedirs(args.out_dir, exist_ok=True)
    out_file = os.path.join(
        args.out_dir, f"brakerbox-snapshot-{safe_stage}-{iso_compact}-{epoch_sec}.json"
    )

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
    harts = []
    current_hart = {}
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
    nvme_present = os.path.exists("/sys/block/nvme0n1")
    nvme_info = {
        "device": "/dev/nvme0n1" if nvme_present else None,
        "model": read_sysfs("/sys/block/nvme0n1/device/model"),
        "serial": read_sysfs("/sys/block/nvme0n1/device/serial"),
        "firmware_rev": read_sysfs("/sys/block/nvme0n1/device/firmware_rev"),
        "pcie_link_speed": read_sysfs("/sys/class/nvme/nvme0/device/current_link_speed"),
        "pcie_link_width": read_sysfs("/sys/class/nvme/nvme0/device/current_link_width"),
        "max_link_speed": read_sysfs("/sys/class/nvme/nvme0/device/max_link_speed"),
        "max_link_width": read_sysfs("/sys/class/nvme/nvme0/device/max_link_width"),
        "logical_block_size_bytes": read_sysfs("/sys/block/nvme0n1/queue/logical_block_size"),
        "physical_block_size_bytes": read_sysfs("/sys/block/nvme0n1/queue/physical_block_size"),
        "size_bytes": int(read_sysfs("/sys/block/nvme0n1/size") or 0) * 512 if nvme_present else 0,
    }

    # --- Block Devices & USB RAID Enclosure Discovery ---
    lsblk_raw = run_cmd([
        "lsblk", "-J", "-b", "-o",
        "NAME,PATH,SIZE,TYPE,TRAN,VENDOR,MODEL,SERIAL,REV,LOG-SEC,PHY-SEC,FSTYPE,LABEL,PARTLABEL,UUID,MOUNTPOINT"
    ])
    try:
        block_devices = json.loads(lsblk_raw).get("blockdevices", [])
    except Exception:
        block_devices = []

    bigred_disks = []
    lilblu_disks = []
    for bd in block_devices:
        if bd.get("type") == "disk":
            sz = int(bd.get("size") or 0)
            if 11_000_000_000_000 <= sz <= 13_000_000_000_000:
                bigred_disks.append({
                    "path": bd.get("path"),
                    "size_bytes": sz,
                    "model": bd.get("model"),
                    "serial": bd.get("serial"),
                    "tran": bd.get("tran"),
                })
            elif 5_500_000_000_000 <= sz <= 6_500_000_000_000:
                lilblu_disks.append({
                    "path": bd.get("path"),
                    "size_bytes": sz,
                    "model": bd.get("model"),
                    "serial": bd.get("serial"),
                    "tran": bd.get("tran"),
                })

    lsusb_tree = run_cmd(["lsusb", "-t"])
    usb_superspeed_5000m = "5000M" in lsusb_tree

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
            if re.search(r"(pcieport.*error|AER:.*error|AER:.*Corrected|AER:.*Uncorrected|nvme.*error|I/O error|usb.*reset|under-voltage)", line, re.IGNORECASE):
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
            "description": "WD_BLACK SN850X 2TB Seated at PCIe Gen3 x4 (8.0 GT/s, Width x4)",
            "expected": "8.0 GT/s PCIe | x4",
            "actual": f"{nvme_info['pcie_link_speed']} | x{nvme_info['pcie_link_width']}",
            "status": "PASS" if (nvme_present and "8.0" in str(nvme_info["pcie_link_speed"]) and str(nvme_info["pcie_link_width"]) == "4") else "FAIL",
        },
        {
            "id": "ORT-04_BIGRED_ARRAY_JBOD",
            "description": "BigRed-WDR48: 4x 12TB WD Red Plus CMR Disks Enumerated in Clear RAID Mode",
            "expected": 4,
            "actual": len(bigred_disks),
            "status": "PASS" if len(bigred_disks) == 4 else "WARN",
        },
        {
            "id": "ORT-05_LILBLU_ARRAY_JBOD",
            "description": "LilBlu-WDB24: 4x 6TB WD Blue Disks Enumerated in Clear RAID Mode",
            "expected": 4,
            "actual": len(lilblu_disks),
            "status": "PASS" if len(lilblu_disks) == 4 else "WARN",
        },
        {
            "id": "ORT-06_USB3_SUPERSPEED",
            "description": "Rear Teal USB 3.2 Gen1 Ports Negotiated at 5000M SuperSpeed",
            "expected": "5000M SuperSpeed present",
            "actual": "5000M detected" if usb_superspeed_5000m else "No 5000M devices detected",
            "status": "PASS" if usb_superspeed_5000m else "WARN",
        },
        {
            "id": "ORT-07_PRIMARY_NIC_END0",
            "description": "Primary SoC NIC (end0) Carrier UP with IPv4 Lease",
            "expected": "UP",
            "actual": "UP" if end0_up else "DOWN",
            "status": "PASS" if end0_up else "FAIL",
        },
        {
            "id": "ORT-08_THERMAL_IDLE_FLOOR",
            "description": "Quiescent SoC Thermal Ceiling Below 55.0 C",
            "expected": "< 55.0 C",
            "actual": f"{max([v['max'] for v in quiescent['thermal_zones_celsius'].values() if v['max'] is not None], default=0.0)} C",
            "status": "PASS" if max([v["max"] for v in quiescent["thermal_zones_celsius"].values() if v["max"] is not None], default=0.0) < 55.0 else "WARN",
        },
        {
            "id": "ORT-09_KERNEL_BUS_HEALTH",
            "description": "Zero PCIe AER, NVMe I/O, or USB Bus Reset Errors in dmesg",
            "expected": 0,
            "actual": len(bus_errors),
            "status": "PASS" if len(bus_errors) == 0 else "WARN",
        },
    ]

    # --- Construct CarrierPigeons / HamStack CTD Artifact Envelope ---
    snapshot_payload = {
        "schema_version": "drewv-ctd-manifest/v1.0",
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
            "usb_raid_candidates": {
                "bigred_wdr48_12tb_disks": bigred_disks,
                "lilblu_wdb24_6tb_disks": lilblu_disks,
            },
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
                    "vm.swappiness",
                    "vm.dirty_background_ratio",
                    "vm.dirty_ratio",
                    "net.core.rmem_max",
                    "net.core.wmem_max",
                ]
            },
            "dmesg_bus_events": bus_errors[-25:],
        },
        "postgresql_broker_state": postgres_state,
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

    # Compute Canonical SHA-256 Signature of the Entire Snapshot
    canonical_bytes = json.dumps(snapshot_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    manifest_sha256 = hashlib.sha256(canonical_bytes).hexdigest()
    snapshot_payload["provenance_signature"] = {
        "algorithm": "SHA-256",
        "canonical_payload_sha256": manifest_sha256,
    }

    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(snapshot_payload, f, indent=2)

    # Print Console ORT Report
    print(f"\n{C_CYAN}--- Operational Readiness Test (ORT) Assertions ---{C_RESET}")
    for chk in ort_checks:
        st = chk["status"]
        color = C_GREEN if st == "PASS" else (C_YELLOW if st == "WARN" else C_RED)
        print(f"  [{color}{st:4s}{C_RESET}] {chk['id']:24s} : {chk['actual']} (Expected: {chk['expected']})")

    print(f"\n{C_CYAN}--- {args.window:.0f}-Second Quiescent Hardware Baseline Summary ---{C_RESET}")
    for tz_name, stats in quiescent["thermal_zones_celsius"].items():
        print(f"  Thermal ({tz_name:12s}) : min={stats['min']}C | mean={stats['mean']}C | max={stats['max']}C")
    for cpu_id, stats in quiescent["cpu_frequency_mhz"].items():
        print(f"  Clock   ({cpu_id:12s}) : min={stats['min']}MHz | mean={stats['mean']}MHz | max={stats['max']}MHz")
    if quiescent["som_fan_rpm"]["samples"] > 0:
        fstats = quiescent["som_fan_rpm"]
        print(f"  Cooler  (SOM Fan     ) : min={fstats['min']} RPM | mean={fstats['mean']} RPM | max={fstats['max']} RPM")

    print(f"\n{C_GREEN}[OK] Wrote CTD Provenance Snapshot ({os.path.getsize(out_file) // 1024} KB):{C_RESET}")
    print(f"     Path   : {out_file}")
    print(f"     SHA256 : {manifest_sha256}")
    print(f"{C_CYAN}======================================================================{C_RESET}")


if __name__ == "__main__":
    main()
