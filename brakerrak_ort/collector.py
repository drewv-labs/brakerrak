"""Core Operational Readiness Test (ORT) evaluation, snapshot assembly, and atomic output."""

from __future__ import annotations

import datetime
import grp
import hashlib
import json
import os
import pwd
import re
import tempfile
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from brakerrak_ort.env import (
    SYSTEM_KIT_ENV_PATH,
    get_raid_arrays_config,
    load_kv_file,
    load_node_env,
    resolve_feature_flag,
    resolve_real_user,
)
from brakerrak_ort.probes import (
    LocalSystemProbe,
    detect_pcie_accelerators,
    detect_primary_nic,
    inspect_accelerator_runtime,
    inspect_btrfs_device_stats,
    inspect_databroker_services,
    inspect_mount_fstype,
    inspect_postgres_state,
    parse_cpuinfo_harts,
    parse_gt_per_sec,
    parse_pcie_width,
    read_sysctl_baseline,
    resolve_soc_peak_temp,
    sample_quiescent_metrics,
)
from brakerrak_ort.profiles import (
    ROLE_STEM_MAP,
    SocProfile,
    resolve_profile,
)
from brakerrak_ort.redact import build_public_snapshot, sign_snapshot
from brakerrak_ort.types import (
    AcceleratorInfo,
    AcceleratorRuntimeInfo,
    AssertionResult,
    AssertionStatus,
    BtrfsDeviceStatsInfo,
    MountInfo,
    PrimaryNicStatus,
    SnapshotOutputs,
    SystemProbe,
    UserIdentity,
)

C_CYAN = "\033[1;36m"
C_GREEN = "\033[1;32m"
C_YELLOW = "\033[1;33m"
C_RED = "\033[1;31m"
C_RESET = "\033[0m"

_BUS_ERROR_RE = re.compile(
    r"(pcieport.*error|AER:.*error|AER:.*Corrected|AER:.*Uncorrected|"
    r"nvme.*error|I/O error|usb.*reset|under-voltage)",
    re.IGNORECASE,
)


def is_day1_stage(stage: str) -> bool:
    """Return True when the lifecycle stage requires Day-1 / converged service assertions."""
    lower = stage.strip().lower()
    return lower.startswith("day1") or lower.startswith("converged")


def compute_overall_status(assertions: Sequence[AssertionResult]) -> AssertionStatus:
    """Aggregate assertion statuses into overall PASS / WARN / FAIL."""
    if any(chk["status"] == "FAIL" for chk in assertions):
        return "FAIL"
    if any(chk["status"] == "WARN" for chk in assertions):
        return "WARN"
    return "PASS"


_PROTECTED_OS_MOUNTS: frozenset[str] = frozenset(
    {"/", "/boot", "/boot/efi", "/boot/firmware", "[SWAP]"}
)


def _is_rotational_disk(bd: Mapping[str, Any]) -> bool:
    """Return True when lsblk reports a rotational (ROTA == 1 / true) disk."""
    rota = bd.get("rota")
    if isinstance(rota, bool):
        return rota
    if isinstance(rota, int):
        return rota == 1
    if isinstance(rota, str):
        return rota.strip().lower() in ("1", "true")
    return False


def _is_protected_os_disk(bd: Mapping[str, Any]) -> bool:
    """Return True if a disk or any of its children hosts root, boot, or active swap."""
    mp = str(bd.get("mountpoint") or "").strip()
    if mp in _PROTECTED_OS_MOUNTS:
        return True
    raw_mps = bd.get("mountpoints")
    if isinstance(raw_mps, list):
        for entry in raw_mps:
            if entry is not None and str(entry).strip() in _PROTECTED_OS_MOUNTS:
                return True
    fstype = str(bd.get("fstype") or "").strip().lower()
    if fstype == "swap":
        return True
    children = bd.get("children")
    if isinstance(children, list):
        for child in children:
            if isinstance(child, Mapping) and _is_protected_os_disk(child):
                return True
    return False


def _build_accelerator_link_assertion(
    assertion_id: str,
    pcie_accelerators: Sequence[AcceleratorInfo],
    profile: SocProfile,
) -> AssertionResult:
    """Build an independent PCIe accelerator link assertion for ORT-03 or ORT-03B."""
    if not pcie_accelerators:
        return {
            "id": assertion_id,
            "description": (
                "PCIe Accelerator Seated (NPU/GPU occupying M.2/PCIe slot; NVMe optional)"
            ),
            "expected": "PCIe accelerator present (e.g., 1e60:* / 1e52:*)",
            "actual": "missing (no PCIe accelerator detected)",
            "status": "FAIL",
        }

    parts: list[str] = []
    overall: AssertionStatus = "PASS"
    for acc in pcie_accelerators:
        acc_speed = acc["pcie_link_speed"]
        acc_width = acc["pcie_link_width"]
        if acc_speed:
            acc_gt_s = parse_gt_per_sec(acc_speed)
            if acc_gt_s != 0.0 and acc_gt_s < profile.min_gt_s:
                overall = "WARN"
            parts.append(
                f"{acc['vendor_name']} [{acc['vendor_id']}:{acc['device_id']}] "
                f"({acc_speed} | x{acc_width or '?'})"
            )
        else:
            parts.append(
                f"{acc['vendor_name']} [{acc['vendor_id']}:{acc['device_id']}] (detected)"
            )

    return {
        "id": assertion_id,
        "description": (
            "PCIe Accelerator Seated (NPU/GPU occupying M.2/PCIe slot; NVMe optional)"
        ),
        "expected": "PCIe accelerator present (e.g., 1e60:* / 1e52:*)",
        "actual": "; ".join(parts),
        "status": overall,
    }


def evaluate_assertions(
    *,
    profile: SocProfile,
    stage: str,
    node_role: str,
    node_env: Mapping[str, str],
    harts: Sequence[Mapping[str, str]],
    total_ram_kb: int,
    nvme_present: bool,
    nvme_info: Mapping[str, Any],
    pcie_accelerators: Sequence[AcceleratorInfo],
    raid_ort_checks: Sequence[AssertionResult],
    primary_nic: PrimaryNicStatus,
    soc_peak_c: float | None,
    bus_errors: Sequence[str],
    postgres_state: Mapping[str, Any],
    broker_services_state: Mapping[str, Any],
    sysctl_baseline: Mapping[str, str],
    env: Mapping[str, str] | None = None,
    accelerator_runtime: Mapping[str, AcceleratorRuntimeInfo] | None = None,
    nvme_mount_info: MountInfo | None = None,
    raid_mount_checks: Sequence[tuple[str, str, MountInfo, BtrfsDeviceStatsInfo]] = (),
    with_raid: bool = False,
    mount_point: str = "/mnt/nvme_pgdata",
) -> list[AssertionResult]:
    """Evaluate hardware, bus, network, thermal, and stage-aware Day-1 ORT assertions."""
    active_env = os.environ if env is None else env
    role_lower = node_role.strip().lower()
    is_accel_persona = role_lower.startswith(("vision", "babbage"))
    enable_pg = resolve_feature_flag("ENABLE_POSTGRES", node_env, role_lower, active_env)
    enable_mqtt = resolve_feature_flag("ENABLE_MQTT_BROKER", node_env, role_lower, active_env)
    enable_nfs = resolve_feature_flag("ENABLE_NFS_SERVER", node_env, role_lower, active_env)

    # ORT-01: CPU Harts
    hart_count = len(harts)
    if profile.expected_harts is not None:
        harts_expected: str | int = profile.expected_harts
        harts_status: AssertionStatus = "PASS" if hart_count == profile.expected_harts else "FAIL"
    else:
        harts_expected = ">= 1"
        harts_status = "PASS" if hart_count > 0 else "FAIL"

    # ORT-02: System Memory
    ram_status: AssertionStatus = "PASS" if total_ram_kb >= profile.ram_floor_kb else "FAIL"

    # ORT-03 & ORT-03B: Decoupled Primary PCIe NVMe and Accelerator Slots
    ort_03_checks: list[AssertionResult] = []
    if nvme_present:
        actual_gt_s = parse_gt_per_sec(
            str(nvme_info["pcie_link_speed"])
            if nvme_info.get("pcie_link_speed") is not None
            else None
        )
        actual_width = parse_pcie_width(
            str(nvme_info["pcie_link_width"])
            if nvme_info.get("pcie_link_width") is not None
            else None
        )
        link_speed_raw = nvme_info.get("pcie_link_speed")
        link_width_raw = nvme_info.get("pcie_link_width")
        if link_speed_raw is None:
            pcie_status: AssertionStatus = (
                "PASS" if profile.slug == "generic-riscv64" else "WARN"
            )
        elif actual_gt_s >= profile.min_gt_s and (
            actual_width == 0 or actual_width >= profile.min_width
        ):
            pcie_status = "PASS"
        else:
            pcie_status = "WARN"
        ort_03_checks.append(
            {
                "id": "ORT-03_PCIE_NVME_LINK",
                "description": profile.pcie_desc,
                "expected": f">= {profile.min_gt_s:.1f} GT/s PCIe | >= x{profile.min_width}",
                "actual": f"{link_speed_raw} | x{link_width_raw}",
                "status": pcie_status,
            }
        )
        if pcie_accelerators or is_accel_persona:
            ort_03_checks.append(
                _build_accelerator_link_assertion(
                    "ORT-03B_PCIE_ACCELERATOR_LINK",
                    pcie_accelerators,
                    profile,
                )
            )
    elif is_accel_persona and not enable_pg:
        ort_03_checks.append(
            _build_accelerator_link_assertion(
                "ORT-03_PCIE_ACCELERATOR_LINK",
                pcie_accelerators,
                profile,
            )
        )
    else:
        ort_03_checks.append(
            {
                "id": "ORT-03_PCIE_NVME_LINK",
                "description": profile.pcie_desc,
                "expected": f">= {profile.min_gt_s:.1f} GT/s PCIe | >= x{profile.min_width}",
                "actual": "missing",
                "status": "FAIL",
            }
        )
        if pcie_accelerators:
            ort_03_checks.append(
                _build_accelerator_link_assertion(
                    "ORT-03B_PCIE_ACCELERATOR_LINK",
                    pcie_accelerators,
                    profile,
                )
            )

    next_idx = 4 + len(raid_ort_checks)
    nic_tag = re.sub(r"[^A-Z0-9]", "_", primary_nic.name.upper())
    if primary_nic.healthy:
        nic_actual = "UP (global IPv4)"
    elif primary_nic.operstate == "UP":
        nic_actual = "UP (no global IPv4)"
    else:
        nic_actual = "DOWN"

    checks: list[AssertionResult] = [
        {
            "id": "ORT-01_CPU_HARTS",
            "description": profile.cpu_desc,
            "expected": harts_expected,
            "actual": hart_count,
            "status": harts_status,
        },
        {
            "id": profile.ram_check_id,
            "description": profile.ram_desc,
            "expected": f">= {profile.ram_floor_kb} kB",
            "actual": f"{total_ram_kb} kB",
            "status": ram_status,
        },
        *ort_03_checks,
        *raid_ort_checks,
        {
            "id": f"ORT-{next_idx:02d}_PRIMARY_NIC_{nic_tag}",
            "description": (
                f"Primary SoC NIC ({primary_nic.name}) Carrier UP with Global IPv4 Lease"
            ),
            "expected": "UP with global IPv4",
            "actual": nic_actual,
            "status": "PASS" if primary_nic.healthy else "FAIL",
        },
        {
            "id": f"ORT-{next_idx + 1:02d}_THERMAL_IDLE_FLOOR",
            "description": f"Quiescent SoC Thermal Ceiling Below {profile.thermal_ceiling_c:.1f} C",
            "expected": f"< {profile.thermal_ceiling_c:.1f} C",
            "actual": f"{soc_peak_c} C" if soc_peak_c is not None else "no sensor",
            "status": (
                "PASS"
                if (soc_peak_c is not None and soc_peak_c < profile.thermal_ceiling_c)
                else "WARN"
            ),
        },
        {
            "id": f"ORT-{next_idx + 2:02d}_KERNEL_BUS_HEALTH",
            "description": "Zero PCIe AER, NVMe I/O, or USB Bus Reset Errors in dmesg",
            "expected": 0,
            "actual": len(bus_errors),
            "status": "PASS" if len(bus_errors) == 0 else "WARN",
        },
    ]

    # Stage-Aware Day-1 / Converged Assertions
    if is_day1_stage(stage):
        if nvme_present:
            logical_bs = str(nvme_info.get("logical_block_size_bytes") or "unknown")
            checks.append(
                {
                    "id": "ORT-D1_NVME_4KN",
                    "description": "Primary NVMe Formatted to 4Kn Logical Sector Alignment",
                    "expected": "4096",
                    "actual": logical_bs,
                    "status": "PASS" if logical_bs == "4096" else "FAIL",
                }
            )

        if (nvme_present or enable_pg) and nvme_mount_info is not None:
            xfs_mounted = bool(nvme_mount_info.get("mounted"))
            xfs_fstype = nvme_mount_info.get("fstype")
            xfs_ok = xfs_mounted and xfs_fstype == "xfs"
            checks.append(
                {
                    "id": "ORT-D1_NVME_XFS_MOUNT",
                    "description": f"Primary NVMe Data Volume ({mount_point}) Mounted as XFS",
                    "expected": "mounted (xfs)",
                    "actual": (
                        f"mounted ({xfs_fstype or 'unknown'})" if xfs_mounted else "unmounted"
                    ),
                    "status": "PASS" if xfs_ok else "FAIL",
                }
            )

        if enable_pg:
            pg_active = bool(postgres_state.get("systemd_service_active"))
            checks.append(
                {
                    "id": "ORT-D1_POSTGRES_ACTIVE",
                    "description": "PostgreSQL 18 Systemd Service Active",
                    "expected": "active",
                    "actual": "active" if pg_active else "inactive",
                    "status": "PASS" if pg_active else "FAIL",
                }
            )

            raw_params = postgres_state.get("active_runtime_parameters")
            pg_params = raw_params if isinstance(raw_params, Mapping) else {}
            io_method = str(pg_params.get("io_method") or "unavailable")
            checks.append(
                {
                    "id": "ORT-D1_POSTGRES_IO_URING",
                    "description": "PostgreSQL 18 Asynchronous I/O Method Set to io_uring",
                    "expected": "io_uring",
                    "actual": io_method,
                    "status": "PASS" if io_method == "io_uring" else "FAIL",
                }
            )

            hp_raw = str(sysctl_baseline.get("vm.nr_hugepages") or "").strip()
            hp_val = int(hp_raw) if hp_raw.isdigit() else 0
            hp_pg_status = str(pg_params.get("huge_pages_status") or "unavailable").strip().lower()
            hp_ok = hp_val > 0 and hp_pg_status == "on"
            checks.append(
                {
                    "id": "ORT-D1_VM_HUGEPAGES",
                    "description": (
                        "Static Linux Kernel HugePages Allocated and Active in PostgreSQL"
                    ),
                    "expected": "vm.nr_hugepages > 0 and huge_pages_status = on",
                    "actual": f"vm.nr_hugepages={hp_val}, huge_pages_status={hp_pg_status}",
                    "status": "PASS" if hp_ok else "FAIL",
                }
            )

        if with_raid:
            if raid_mount_checks:
                for arr_name, arr_mount, m_info, btrfs_stats in raid_mount_checks:
                    arr_tag = re.sub(r"[^A-Z0-9]", "_", arr_name.upper())
                    b_mounted = bool(m_info.get("mounted"))
                    b_fstype = m_info.get("fstype")
                    b_mount_ok = b_mounted and b_fstype == "btrfs"
                    checks.append(
                        {
                            "id": f"ORT-D1_{arr_tag}_BTRFS_MOUNT",
                            "description": (
                                f"{arr_name} Btrfs RAID Volume ({arr_mount}) Mounted as btrfs"
                            ),
                            "expected": "mounted (btrfs)",
                            "actual": (
                                f"mounted ({b_fstype or 'unknown'})" if b_mounted else "unmounted"
                            ),
                            "status": "PASS" if b_mount_ok else "FAIL",
                        }
                    )

                    stats_ok = bool(btrfs_stats.get("stats_available"))
                    total_errs = int(btrfs_stats.get("total_errors") or 0)
                    nonzero = btrfs_stats.get("nonzero_errors") or []
                    if stats_ok and total_errs == 0:
                        stats_actual = "0 errors"
                        stats_status: AssertionStatus = "PASS"
                    elif stats_ok:
                        stats_actual = f"{total_errs} errors ({', '.join(nonzero)})"
                        stats_status = "FAIL"
                    else:
                        stats_actual = str(btrfs_stats.get("error") or "unavailable")
                        stats_status = "FAIL"
                    checks.append(
                        {
                            "id": f"ORT-D1_{arr_tag}_BTRFS_STATS",
                            "description": (
                                f"{arr_name} Btrfs Device Error Counters Zero ({arr_mount})"
                            ),
                            "expected": "0 errors",
                            "actual": stats_actual,
                            "status": stats_status,
                        }
                    )
            else:
                checks.append(
                    {
                        "id": "ORT-D1_RAID_BTRFS_MOUNT",
                        "description": "Configured Btrfs RAID Vault Mounted",
                        "expected": "mounted (btrfs)",
                        "actual": "WITH_RAID=true but RAID_ARRAYS_JSON is empty",
                        "status": "FAIL",
                    }
                )

        if enable_mqtt:
            raw_req_mqtt = (
                active_env.get("REQUIRE_MQTT_BROKER")
                if active_env.get("REQUIRE_MQTT_BROKER") is not None
                else node_env.get("REQUIRE_MQTT_BROKER")
            )
            if raw_req_mqtt is not None and raw_req_mqtt.strip() != "":
                mqtt_required = raw_req_mqtt.strip().lower() in ("1", "true", "yes", "on")
            else:
                mqtt_required = role_lower == "databroker"

            raw_mqtt = broker_services_state.get("mosquitto_mqtt")
            mqtt_map = raw_mqtt if isinstance(raw_mqtt, Mapping) else {}
            mqtt_active = bool(mqtt_map.get("systemd_service_active"))
            mqtt_fail_status: AssertionStatus = "FAIL" if mqtt_required else "WARN"
            checks.append(
                {
                    "id": "ORT-D1_MQTT_ACTIVE",
                    "description": "Mosquitto MQTT Broker Systemd Service Active",
                    "expected": "active" if mqtt_required else "active (optional/supplemental)",
                    "actual": "active" if mqtt_active else "inactive",
                    "status": "PASS" if mqtt_active else mqtt_fail_status,
                }
            )

        if enable_nfs:
            raw_nfs = broker_services_state.get("nfs_v4_server")
            nfs_map = raw_nfs if isinstance(raw_nfs, Mapping) else {}
            nfs_active = bool(nfs_map.get("systemd_service_active"))
            checks.append(
                {
                    "id": "ORT-D1_NFS_ACTIVE",
                    "description": "NFSv4 Vault Exporter Systemd Service Active",
                    "expected": "active",
                    "actual": "active" if nfs_active else "inactive",
                    "status": "PASS" if nfs_active else "FAIL",
                }
            )

        detected_vendors = {acc["vendor_id"].lower() for acc in pcie_accelerators}
        rt_map = accelerator_runtime or {}
        if "1e60" in detected_vendors:
            hailo_rt = rt_map.get("hailo")
            devs = list(hailo_rt.get("device_nodes", [])) if hailo_rt else []
            kmod = bool(hailo_rt.get("kmod_loaded")) if hailo_rt else False
            cli_ok = bool(hailo_rt.get("cli_ok")) if hailo_rt else False
            hailo_ok = bool(devs) and kmod and cli_ok
            checks.append(
                {
                    "id": "ORT-D1_HAILO_RUNTIME",
                    "description": (
                        "Hailo NPU Runtime (/dev/hailo*, hailo_pci kmod, hailortcli) Operational"
                    ),
                    "expected": "/dev/hailo* + hailo_pci + hailortcli ok",
                    "actual": (
                        f"devs={','.join(devs) if devs else 'none'} | "
                        f"kmod={'loaded' if kmod else 'missing'} | "
                        f"hailortcli={'ok' if cli_ok else 'failed'}"
                    ),
                    "status": "PASS" if hailo_ok else "FAIL",
                }
            )
        if "1e52" in detected_vendors:
            tt_rt = rt_map.get("tenstorrent")
            devs = list(tt_rt.get("device_nodes", [])) if tt_rt else []
            kmod = bool(tt_rt.get("kmod_loaded")) if tt_rt else False
            cli_ok = bool(tt_rt.get("cli_ok")) if tt_rt else False
            tt_ok = bool(devs) and kmod and cli_ok
            checks.append(
                {
                    "id": "ORT-D1_TENSTORRENT_RUNTIME",
                    "description": (
                        "Tenstorrent AI Runtime (/dev/tenstorrent*, tenstorrent kmod, tt-smi) "
                        "Operational"
                    ),
                    "expected": "/dev/tenstorrent* + tenstorrent + tt-smi ok",
                    "actual": (
                        f"devs={','.join(devs) if devs else 'none'} | "
                        f"kmod={'loaded' if kmod else 'missing'} | "
                        f"tt-smi={'ok' if cli_ok else 'failed'}"
                    ),
                    "status": "PASS" if tt_ok else "FAIL",
                }
            )

    return checks


def _collect_local_users() -> tuple[list[dict[str, Any]], int, int]:
    human_users: list[dict[str, Any]] = []
    system_users_count = 0
    all_groups = grp.getgrall()
    for user in pwd.getpwall():
        if user.pw_uid == 0 or (1000 <= user.pw_uid < 65534):
            user_groups = [g.gr_name for g in all_groups if user.pw_name in g.gr_mem]
            try:
                primary_grp = grp.getgrgid(user.pw_gid).gr_name
            except KeyError:
                primary_grp = str(user.pw_gid)
            human_users.append(
                {
                    "username": user.pw_name,
                    "uid": user.pw_uid,
                    "gid": user.pw_gid,
                    "primary_group": primary_grp,
                    "supplementary_groups": user_groups,
                    "home": user.pw_dir,
                    "shell": user.pw_shell,
                }
            )
        else:
            system_users_count += 1
    return human_users, system_users_count, len(all_groups)


def collect_snapshot(
    probe: SystemProbe,
    *,
    soc: str | None = None,
    stage: str = "day0-pre-forge",
    node_env: Mapping[str, str] | None = None,
    kit_env: Mapping[str, str] | None = None,
    window_sec: float = 5.0,
    interval_sec: float = 0.5,
    now_utc: datetime.datetime | None = None,
    env: Mapping[str, str] | None = None,
) -> tuple[dict[str, Any], PrimaryNicStatus, str, str]:
    """Collect a full, signed CTD hardware baseline snapshot using the supplied SystemProbe."""
    active_env = os.environ if env is None else env
    resolved_kit = dict(kit_env) if kit_env is not None else load_kv_file(SYSTEM_KIT_ENV_PATH)
    resolved_node_env = dict(node_env) if node_env is not None else {}

    dt_model = (probe.read_text("/proc/device-tree/model") or "").rstrip("\x00")
    requested_soc = (
        soc
        or active_env.get("BRAKERRAK_TARGET")
        or resolved_kit.get("RVDK_SOC_SLUG")
    )
    profile = resolve_profile(requested_soc, dt_model=dt_model)
    soc_slug = profile.slug

    node_role = (
        active_env.get("NODE_ROLE") or resolved_node_env.get("NODE_ROLE") or "devbench"
    ).strip().lower()
    with_raid = (
        (active_env.get("WITH_RAID") or resolved_node_env.get("WITH_RAID") or "false")
        .strip()
        .lower()
        == "true"
    )
    mount_point = (
        active_env.get("MOUNT_POINT")
        or resolved_node_env.get("MOUNT_POINT")
        or "/mnt/nvme_pgdata"
    ).strip() or "/mnt/nvme_pgdata"
    raid_arrays_cfg = get_raid_arrays_config(resolved_node_env, active_env)

    ts = now_utc or datetime.datetime.now(datetime.UTC)
    epoch_sec = int(ts.timestamp())
    iso_full = ts.strftime("%Y-%m-%dT%H:%M:%SZ")

    quiescent = sample_quiescent_metrics(probe, window_sec, interval_sec)
    harts = parse_cpuinfo_harts(probe.read_text("/proc/cpuinfo") or "")

    caches: list[dict[str, Any]] = []
    for cdir in probe.glob_paths("/sys/devices/system/cpu/cpu0/cache/index*"):
        caches.append(
            {
                "index": os.path.basename(cdir),
                "level": probe.read_text(f"{cdir}/level"),
                "type": probe.read_text(f"{cdir}/type"),
                "size": probe.read_text(f"{cdir}/size"),
                "ways_of_associativity": probe.read_text(f"{cdir}/ways_of_associativity"),
                "coherency_line_size": probe.read_text(f"{cdir}/coherency_line_size"),
                "shared_cpu_list": probe.read_text(f"{cdir}/shared_cpu_list"),
            }
        )

    nvme_dev = resolved_node_env.get("NVME_DEV", "/dev/nvme0n1")
    nvme_short = os.path.basename(nvme_dev)
    nvme_ctrl = re.sub(r"n[0-9]+$", "", nvme_short)
    nvme_present = probe.path_exists(f"/sys/block/{nvme_short}")
    raw_size_sectors = probe.read_text(f"/sys/block/{nvme_short}/size")
    size_bytes = (
        int(raw_size_sectors) * 512
        if (nvme_present and raw_size_sectors and raw_size_sectors.isdigit())
        else 0
    )
    nvme_info: dict[str, Any] = {
        "device": nvme_dev if nvme_present else None,
        "model": probe.read_text(f"/sys/block/{nvme_short}/device/model"),
        "serial": probe.read_text(f"/sys/block/{nvme_short}/device/serial"),
        "firmware_rev": probe.read_text(f"/sys/block/{nvme_short}/device/firmware_rev"),
        "pcie_link_speed": probe.read_text(
            f"/sys/class/nvme/{nvme_ctrl}/device/current_link_speed"
        ),
        "pcie_link_width": probe.read_text(
            f"/sys/class/nvme/{nvme_ctrl}/device/current_link_width"
        ),
        "max_link_speed": probe.read_text(f"/sys/class/nvme/{nvme_ctrl}/device/max_link_speed"),
        "max_link_width": probe.read_text(f"/sys/class/nvme/{nvme_ctrl}/device/max_link_width"),
        "logical_block_size_bytes": probe.read_text(
            f"/sys/block/{nvme_short}/queue/logical_block_size"
        ),
        "physical_block_size_bytes": probe.read_text(
            f"/sys/block/{nvme_short}/queue/physical_block_size"
        ),
        "size_bytes": size_bytes,
    }

    lsblk_res = probe.run_cmd(
        [
            "lsblk",
            "-J",
            "-b",
            "-o",
            (
                "NAME,PATH,SIZE,TYPE,TRAN,ROTA,VENDOR,MODEL,SERIAL,REV,"
                "LOG-SEC,PHY-SEC,FSTYPE,LABEL,PARTLABEL,UUID,PARTUUID,MOUNTPOINT"
            ),
        ]
    )
    block_devices: list[dict[str, Any]] = []
    if lsblk_res.ok and lsblk_res.stdout:
        try:
            parsed_lsblk: Any = json.loads(lsblk_res.stdout)
            if isinstance(parsed_lsblk, dict) and isinstance(
                parsed_lsblk.get("blockdevices"), list
            ):
                block_devices = [
                    d for d in parsed_lsblk["blockdevices"] if isinstance(d, dict)
                ]
        except json.JSONDecodeError:
            block_devices = []

    usb_raid_arrays: dict[str, dict[str, Any]] = {}
    raid_ort_checks: list[AssertionResult] = []
    raid_mount_checks: list[tuple[str, str, MountInfo, BtrfsDeviceStatsInfo]] = []
    day1_mode = is_day1_stage(stage)

    for idx, arr_cfg in enumerate(raid_arrays_cfg, start=4):
        arr_name = str(arr_cfg.get("name", f"Array{idx}"))
        arr_id = str(arr_cfg.get("id") or arr_name.lower())
        arr_type = str(arr_cfg.get("type", "vault"))
        arr_label = str(arr_cfg.get("label", ""))
        arr_mount = str(arr_cfg.get("mount", "")).strip()
        expected_disks = int(arr_cfg.get("disks", 4))
        min_b = int(arr_cfg.get("min_bytes", 0))
        max_b = int(arr_cfg.get("max_bytes", 0))

        explicit_raw = arr_cfg.get("devices")
        explicit_devices: set[str] = set()
        if isinstance(explicit_raw, list):
            explicit_devices = {str(dev).strip() for dev in explicit_raw if str(dev).strip()}
        has_explicit_devices = bool(explicit_devices)

        matched_disks: list[dict[str, Any]] = []
        for bd in block_devices:
            if bd.get("type") != "disk":
                continue
            if _is_protected_os_disk(bd):
                continue
            sz = int(bd.get("size") or 0)
            if has_explicit_devices:
                bd_path = str(bd.get("path") or "").strip()
                bd_name = str(bd.get("name") or "").strip()
                if bd_path not in explicit_devices and bd_name not in explicit_devices:
                    continue
            else:
                if not _is_rotational_disk(bd):
                    continue
                if not (min_b <= sz <= max_b):
                    continue
            matched_disks.append(
                {
                    "path": bd.get("path"),
                    "size_bytes": sz,
                    "model": bd.get("model"),
                    "serial": bd.get("serial"),
                    "tran": bd.get("tran"),
                    "rota": bd.get("rota"),
                }
            )

        arr_mount_info = (
            inspect_mount_fstype(arr_mount, probe)
            if arr_mount
            else MountInfo(mountpoint="", mounted=False, fstype=None)
        )
        if day1_mode and arr_mount_info["mounted"] and arr_mount_info["fstype"] == "btrfs":
            btrfs_stats = inspect_btrfs_device_stats(arr_mount, probe)
        else:
            btrfs_stats = BtrfsDeviceStatsInfo(
                mountpoint=arr_mount,
                stats_available=False,
                total_errors=0,
                nonzero_errors=[],
                error="not mounted as btrfs" if arr_mount else "missing mount path",
            )

        arr_entry: dict[str, Any] = {
            "name": arr_name,
            "type": arr_type,
            "label": arr_label,
            "mount": arr_mount,
            "expected_disks": expected_disks,
            "detected_disks_count": len(matched_disks),
            "mounted": arr_mount_info["mounted"],
            "fstype": arr_mount_info["fstype"],
            "detected_disks": matched_disks,
        }
        if day1_mode:
            arr_entry["btrfs_device_stats"] = btrfs_stats
        usb_raid_arrays[arr_id] = arr_entry

        if with_raid:
            raid_mount_checks.append((arr_name, arr_mount, arr_mount_info, btrfs_stats))

        chk_id = f"ORT-{idx:02d}_{re.sub(r'[^A-Z0-9]', '_', arr_name.upper())}_ARRAY_JBOD"
        raid_ort_checks.append(
            {
                "id": chk_id,
                "description": (
                    f"{arr_name} ({arr_type}): {expected_disks}x Rotational Disks "
                    f"Enumerated ({arr_label})"
                ),
                "expected": expected_disks,
                "actual": len(matched_disks),
                "status": "PASS" if len(matched_disks) == expected_disks else "WARN",
            }
        )

    lsusb_tree = probe.run_cmd(["lsusb", "-t"]).stdout
    usb_superspeed_5000m = "5000M" in lsusb_tree
    if raid_arrays_cfg:
        usb_ort_idx = 4 + len(raid_ort_checks)
        raid_ort_checks.append(
            {
                "id": f"ORT-{usb_ort_idx:02d}_USB3_SUPERSPEED",
                "description": profile.usb_desc,
                "expected": "5000M SuperSpeed present",
                "actual": "5000M detected" if usb_superspeed_5000m else "No 5000M devices detected",
                "status": "PASS" if usb_superspeed_5000m else "WARN",
            }
        )

    pci_raw = probe.run_cmd(["lspci", "-nn"]).stdout
    pci_lines = [line for line in pci_raw.splitlines() if line.strip()]
    pcie_accelerators = detect_pcie_accelerators(pci_lines, probe)

    ip_addr_res = probe.run_cmd(["ip", "-j", "addr", "show"])
    ip_route_res = probe.run_cmd(["ip", "-j", "route", "show"])
    net_ifaces: list[dict[str, Any]] = []
    net_routes: list[dict[str, Any]] = []
    if ip_addr_res.ok and ip_addr_res.stdout:
        try:
            parsed_ifaces: Any = json.loads(ip_addr_res.stdout)
            if isinstance(parsed_ifaces, list):
                net_ifaces = [i for i in parsed_ifaces if isinstance(i, dict)]
        except json.JSONDecodeError:
            pass
    if ip_route_res.ok and ip_route_res.stdout:
        try:
            parsed_routes: Any = json.loads(ip_route_res.stdout)
            if isinstance(parsed_routes, list):
                net_routes = [r for r in parsed_routes if isinstance(r, dict)]
        except json.JSONDecodeError:
            pass

    primary_nic = detect_primary_nic(net_ifaces, net_routes, resolved_kit)

    dmesg_res = probe.run_cmd(["dmesg"], use_sudo=True)
    bus_errors: list[str] = []
    if dmesg_res.ok and dmesg_res.stdout:
        for line in dmesg_res.stdout.splitlines():
            if _BUS_ERROR_RE.search(line):
                bus_errors.append(line)

    human_users, system_users_count, total_groups_count = _collect_local_users()

    ps_res = probe.run_cmd(
        ["ps", "-eo", "pid,ppid,user,stat,pcpu,pmem,rss,comm,args", "--sort=-rss"]
    )
    ps_lines = ps_res.stdout.splitlines() if ps_res.ok and ps_res.stdout else []
    top_processes: list[dict[str, Any]] = []
    for line in ps_lines[1:36]:
        parts = line.split(None, 8)
        if len(parts) >= 9:
            try:
                top_processes.append(
                    {
                        "pid": int(parts[0]),
                        "ppid": int(parts[1]),
                        "user": parts[2],
                        "stat": parts[3],
                        "cpu_pct": float(parts[4]),
                        "mem_pct": float(parts[5]),
                        "rss_kb": int(parts[6]),
                        "comm": parts[7],
                        "args": parts[8],
                    }
                )
            except ValueError:
                continue

    dpkg_res = probe.run_cmd(
        ["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\t${Status}\n"]
    )
    dpkg_raw = dpkg_res.stdout if dpkg_res.ok else ""
    packages: list[dict[str, str]] = []
    for line in dpkg_raw.splitlines():
        cols = line.split("\t")
        if len(cols) >= 4 and "install ok installed" in cols[3]:
            packages.append({"name": cols[0], "version": cols[1], "arch": cols[2]})
    pkg_hash = hashlib.sha256(dpkg_raw.encode("utf-8")).hexdigest()

    postgres_state = inspect_postgres_state(probe)
    broker_services_state = inspect_databroker_services(resolved_node_env, probe)
    sysctl_baseline = read_sysctl_baseline(probe)

    def _first_line(cmd: Sequence[str], default: str = "not_installed") -> str:
        res = probe.run_cmd(cmd)
        if not res.ok or not res.stdout:
            return default
        lines = res.stdout.splitlines()
        return lines[0] if lines else default

    toolchains = {
        "linux_kernel": probe.get_kernel_release(),
        "glibc_ldd": _first_line(["ldd", "--version"], ""),
        "systemd": _first_line(["systemctl", "--version"], ""),
        "python3": _first_line(["python3", "--version"]),
        "gcc": _first_line(["gcc", "--version"]),
        "git": _first_line(["git", "--version"]),
        "go": _first_line(["go", "version"]),
        "openssl": _first_line(["openssl", "version"]),
        "postgres_psql": postgres_state["psql_client_version"],
        "nvme_cli": _first_line(["nvme", "--version"]),
        "mdadm": _first_line(["mdadm", "--version"]),
    }

    accelerator_runtime = (
        inspect_accelerator_runtime(pcie_accelerators, probe) if day1_mode else {}
    )
    nvme_mount_info = inspect_mount_fstype(mount_point, probe) if day1_mode else None

    total_ram_kb = probe.get_total_ram_kb()
    soc_peak_c = resolve_soc_peak_temp(quiescent["thermal_zones_celsius"])
    ort_checks = evaluate_assertions(
        profile=profile,
        stage=stage,
        node_role=node_role,
        node_env=resolved_node_env,
        harts=harts,
        total_ram_kb=total_ram_kb,
        nvme_present=nvme_present,
        nvme_info=nvme_info,
        pcie_accelerators=pcie_accelerators,
        raid_ort_checks=raid_ort_checks,
        primary_nic=primary_nic,
        soc_peak_c=soc_peak_c,
        bus_errors=bus_errors,
        postgres_state=postgres_state,
        broker_services_state=broker_services_state,
        sysctl_baseline=sysctl_baseline,
        env=active_env,
        accelerator_runtime=accelerator_runtime,
        nvme_mount_info=nvme_mount_info,
        raid_mount_checks=raid_mount_checks,
        with_raid=with_raid,
        mount_point=mount_point,
    )
    overall_status = compute_overall_status(ort_checks)

    uptime_raw = probe.read_text("/proc/uptime") or "0 0"
    uptime_token = (uptime_raw.split() or ["0"])[0]
    try:
        uptime_seconds = float(uptime_token)
    except ValueError:
        uptime_seconds = 0.0

    storage_mounts: dict[str, Any] = {}
    if nvme_mount_info is not None:
        storage_mounts[mount_point] = nvme_mount_info

    hostname = probe.get_hostname()
    snapshot_payload: dict[str, Any] = {
        "schema_version": "drewv-ctd-manifest/v1.1",
        "artifact": {
            "id": hostname,
            "node_group": "brakerrak-nodes",
            "target_designation": f"{soc_slug} ({node_role})",
            "kind": "hardware_node_baseline_snapshot",
            "stage": stage,
            "captured_at_utc": iso_full,
            "captured_at_epoch": epoch_sec,
        },
        "operational_readiness_test": {
            "overall_status": overall_status,
            "assertions": ort_checks,
        },
        "quiescent_profile": quiescent,
        "hardware_inventory": {
            "device_tree_model": dt_model,
            "architecture": probe.get_architecture(),
            "cpu_harts_count": len(harts),
            "isa_string": harts[0].get("isa") if harts else None,
            "mmu_type": harts[0].get("mmu") if harts else None,
            "cpu_harts": harts,
            "cache_hierarchy": caches,
            "nvme_primary": nvme_info,
            "pcie_accelerators": pcie_accelerators,
            "accelerator_runtime": accelerator_runtime,
            "usb_raid_arrays": usb_raid_arrays,
            "storage_mounts": storage_mounts,
            "usb_topology_tree": lsusb_tree.splitlines(),
            "pci_devices": pci_lines,
            "block_devices": block_devices,
        },
        "os_and_kernel_state": {
            "uname": probe.get_uname(),
            "os_release": probe.read_text("/etc/os-release"),
            "proc_cmdline": probe.read_text("/proc/cmdline"),
            "uptime_seconds": uptime_seconds,
            "systemd_default_target": probe.run_cmd(["systemctl", "get-default"]).stdout,
            "cpufreq_governors": {
                os.path.basename(os.path.dirname(os.path.dirname(p))): probe.read_text(p)
                for p in probe.glob_paths(
                    "/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor"
                )
            },
            "sysctl_baseline": sysctl_baseline,
            "dmesg_bus_events": bus_errors[-25:],
        },
        "postgresql_broker_state": postgres_state,
        "databroker_services_state": broker_services_state,
        "network_topology": {
            "hostname": hostname,
            "fqdn": probe.get_fqdn(),
            "primary_nic": primary_nic.name,
            "primary_nic_operstate": primary_nic.operstate,
            "primary_nic_has_ipv4": primary_nic.has_global_ipv4,
            "interfaces": net_ifaces,
            "routes": net_routes,
            "resolv_conf": probe.read_text("/etc/resolv.conf"),
        },
        "security_and_users": {
            "human_and_root_users": human_users,
            "system_users_count": system_users_count,
            "total_groups_count": total_groups_count,
            "sudoers_dropins": [
                os.path.basename(p) for p in probe.glob_paths("/etc/sudoers.d/*")
            ],
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

    sign_snapshot(snapshot_payload, redacted=False)
    return snapshot_payload, primary_nic, soc_slug, node_role


def write_json_atomic(
    path: Path,
    payload: Mapping[str, Any],
    *,
    mode: int,
    owner: UserIdentity | None = None,
) -> None:
    """Write a JSON document atomically with strict file permissions and optional root chown."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        if (
            owner is not None
            and owner.uid is not None
            and owner.gid is not None
            and os.geteuid() == 0
        ):
            try:
                os.chown(tmp_path, owner.uid, owner.gid)
            except OSError:
                pass
        os.replace(tmp_path, path)
    except BaseException:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def build_snapshot_stem(node_role: str, stage: str, now_utc: datetime.datetime) -> str:
    """Construct persona-aligned snapshot filename stem across all SoCs."""
    stem_prefix = ROLE_STEM_MAP.get(node_role.strip().lower(), "brakerrak")
    safe_stage = re.sub(r"[^a-zA-Z0-9_-]", "-", stage)
    epoch_sec = int(now_utc.timestamp())
    iso_compact = now_utc.strftime("%Y%m%dT%H%M%SZ")
    return f"{stem_prefix}-snapshot-{safe_stage}-{iso_compact}-{epoch_sec}"


def write_snapshot_pair(
    raw_payload: Mapping[str, Any],
    *,
    out_dir: str | Path,
    base_stem: str,
    primary_nic: PrimaryNicStatus,
    write_public: bool = True,
    owner: UserIdentity | None = None,
) -> SnapshotOutputs:
    """Persist private (0600) and optional public redacted (0644) snapshots atomically."""
    out_root = Path(out_dir)
    out_root.mkdir(parents=True, exist_ok=True)
    if (
        owner is not None
        and owner.uid is not None
        and owner.gid is not None
        and os.geteuid() == 0
    ):
        try:
            os.chown(out_root, owner.uid, owner.gid)
        except OSError:
            pass

    sig = raw_payload.get("provenance_signature")
    raw_sha256 = (
        str(sig["canonical_payload_sha256"])
        if isinstance(sig, Mapping) and "canonical_payload_sha256" in sig
        else ""
    )

    private_path = out_root / f"{base_stem}.json"
    write_json_atomic(private_path, raw_payload, mode=0o600, owner=owner)

    public_path: Path | None = None
    public_payload: dict[str, Any] | None = None
    public_sha256: str | None = None
    if write_public:
        extra_users = (owner.username,) if owner is not None else ()
        public_payload = build_public_snapshot(
            raw_payload,
            raw_sha256,
            primary_nic.name,
            primary_nic.operstate == "UP",
            nic_has_ipv4=primary_nic.has_global_ipv4,
            extra_usernames=extra_users,
        )
        pub_sig = public_payload.get("provenance_signature")
        if isinstance(pub_sig, Mapping) and "canonical_payload_sha256" in pub_sig:
            public_sha256 = str(pub_sig["canonical_payload_sha256"])
        public_path = out_root / f"{base_stem}.public.json"
        write_json_atomic(public_path, public_payload, mode=0o644, owner=owner)

    ort_block = raw_payload.get("operational_readiness_test")
    raw_status = ort_block.get("overall_status") if isinstance(ort_block, Mapping) else "FAIL"
    overall_status: AssertionStatus
    if raw_status == "PASS":
        overall_status = "PASS"
    elif raw_status == "WARN":
        overall_status = "WARN"
    else:
        overall_status = "FAIL"

    return SnapshotOutputs(
        private_path=private_path,
        public_path=public_path,
        private_sha256=raw_sha256,
        public_sha256=public_sha256,
        overall_status=overall_status,
        private_payload=dict(raw_payload),
        public_payload=public_payload,
    )


def print_summary(
    outputs: SnapshotOutputs,
    *,
    soc_slug: str,
    node_role: str,
    stage: str,
    window_sec: float,
) -> None:
    """Render concise human-readable ORT summary and provenance SHA-256 digests to stdout."""
    payload = outputs.private_payload
    artifact = payload.get("artifact", {})
    ort = payload.get("operational_readiness_test", {})
    quiescent = payload.get("quiescent_profile", {})
    hw = payload.get("hardware_inventory", {})

    print(f"{C_CYAN}======================================================================{C_RESET}")
    print(f"{C_CYAN} DREW-V Labs // Operational Readiness Test (ORT) & CTD Snapshot{C_RESET}")
    print(f" Silicon   : {soc_slug} (Role: {node_role})")
    print(f" Stage     : {stage}")
    print(
        f" Timestamp : {artifact.get('captured_at_utc')} "
        f"(Epoch: {artifact.get('captured_at_epoch')})"
    )
    print(f" Target    : {artifact.get('id')} ({hw.get('architecture')})")
    print(f"{C_CYAN}======================================================================{C_RESET}")

    print(f"\n{C_CYAN}--- Operational Readiness Test (ORT) Assertions ---{C_RESET}")
    for chk in ort.get("assertions", []):
        st = chk["status"]
        color = C_GREEN if st == "PASS" else (C_YELLOW if st == "WARN" else C_RED)
        print(
            f"  [{color}{st:4s}{C_RESET}] {chk['id']:28s} : "
            f"{chk['actual']} (Expected: {chk['expected']})"
        )

    print(f"\n{C_CYAN}--- {window_sec:.0f}-Second Quiescent Hardware Baseline Summary ---{C_RESET}")
    for tz_name, stats in quiescent.get("thermal_zones_celsius", {}).items():
        print(
            f"  Thermal ({tz_name:12s}) : "
            f"min={stats['min']}C | mean={stats['mean']}C | max={stats['max']}C"
        )
    for cpu_id, stats in quiescent.get("cpu_frequency_mhz", {}).items():
        print(
            f"  Clock   ({cpu_id:12s}) : "
            f"min={stats['min']}MHz | mean={stats['mean']}MHz | max={stats['max']}MHz"
        )
    fan_stats = quiescent.get("som_fan_rpm", {})
    if fan_stats.get("samples", 0) > 0:
        print(
            "  Cooler  (SOM Fan     ) : "
            f"min={fan_stats['min']} RPM | mean={fan_stats['mean']} RPM "
            f"| max={fan_stats['max']} RPM"
        )

    priv_kb = outputs.private_path.stat().st_size // 1024
    print(f"\n{C_GREEN}[OK] Wrote Unredacted CTD Snapshot ({priv_kb} KB, mode 0600):{C_RESET}")
    print(f"     Path   : {outputs.private_path}")
    print(f"     SHA256 : {outputs.private_sha256}")
    if outputs.public_path is not None and outputs.public_sha256 is not None:
        pub_kb = outputs.public_path.stat().st_size // 1024
        print(f"{C_GREEN}[OK] Wrote Redacted Public Snapshot ({pub_kb} KB, mode 0644):{C_RESET}")
        print(f"     Path   : {outputs.public_path}")
        print(f"     SHA256 : {outputs.public_sha256}")
    print(f"{C_CYAN}======================================================================{C_RESET}")


def run_ort_collection(
    *,
    soc: str | None = None,
    stage: str = "day0-pre-forge",
    out_dir: str | Path | None = None,
    config_path: str | None = None,
    window_sec: float = 5.0,
    interval_sec: float = 0.5,
    write_public: bool = True,
    quiet: bool = False,
    probe: SystemProbe | None = None,
    now_utc: datetime.datetime | None = None,
    env: Mapping[str, str] | None = None,
) -> SnapshotOutputs:
    """Execute ORT collection, redaction, signing, and atomic snapshot persistence."""
    active_env = os.environ if env is None else env
    owner = resolve_real_user(active_env)
    resolved_out_dir = (
        Path(out_dir) if out_dir is not None else Path(owner.home) / ".brakerrak" / "snapshots"
    )
    node_env = load_node_env(config_path, real_home=owner.home, env=active_env)
    kit_env = load_kv_file(SYSTEM_KIT_ENV_PATH)
    active_probe: SystemProbe = LocalSystemProbe() if probe is None else probe
    ts = now_utc or datetime.datetime.now(datetime.UTC)

    payload, primary_nic, soc_slug, node_role = collect_snapshot(
        active_probe,
        soc=soc,
        stage=stage,
        node_env=node_env,
        kit_env=kit_env,
        window_sec=window_sec,
        interval_sec=interval_sec,
        now_utc=ts,
        env=active_env,
    )
    base_stem = build_snapshot_stem(node_role, stage, ts)
    outputs = write_snapshot_pair(
        payload,
        out_dir=resolved_out_dir,
        base_stem=base_stem,
        primary_nic=primary_nic,
        write_public=write_public,
        owner=owner,
    )
    if not quiet:
        print_summary(
            outputs,
            soc_slug=soc_slug,
            node_role=node_role,
            stage=stage,
            window_sec=window_sec,
        )
    return outputs
