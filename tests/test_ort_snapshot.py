"""Unit tests for the unified stdlib-only brakerrak_ort package."""

from __future__ import annotations

import ast
import datetime
import fnmatch
import json
import stat
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import pytest

from brakerrak_ort import (
    SOC_PROFILES,
    CommandResult,
    SystemProbe,
    UserIdentity,
    build_public_snapshot,
    build_snapshot_stem,
    collect_snapshot,
    compute_canonical_sha256,
    detect_primary_nic,
    detect_soc_from_dt_model,
    evaluate_assertions,
    get_soc_profile,
    inspect_databroker_services,
    inspect_postgres_state,
    main,
    parse_cpuinfo_harts,
    parse_ganesha_exports,
    parse_kv_content,
    read_sysctl_baseline,
    sign_snapshot,
    verify_snapshot_signature,
    write_snapshot_pair,
)


class FakeSystemProbe:
    """In-memory SystemProbe test double for deterministic ORT validation."""

    def __init__(
        self,
        *,
        files: dict[str, str] | None = None,
        existing_paths: set[str] | None = None,
        mounts: set[str] | None = None,
        commands: dict[tuple[str, ...], CommandResult] | None = None,
        total_ram_kb: int = 32_000_000,
        hostname: str = "brakerbench-test",
        fqdn: str = "brakerbench-test.local",
        architecture: str = "riscv64",
        kernel_release: str = "6.12.0-riscv64",
        loadavg: tuple[float, float, float] | None = (0.12, 0.10, 0.08),
    ) -> None:
        self.files: dict[str, str] = dict(files or {})
        self.existing_paths: set[str] = set(existing_paths or set()) | set(self.files.keys())
        self.mounts: set[str] = set(mounts or set())
        self.commands: dict[tuple[str, ...], CommandResult] = dict(commands or {})
        self.total_ram_kb = total_ram_kb
        self.hostname = hostname
        self.fqdn = fqdn
        self.architecture = architecture
        self.kernel_release = kernel_release
        self.loadavg = loadavg
        self.cmd_log: list[tuple[str, ...]] = []

    def read_text(self, path: str) -> str | None:
        val = self.files.get(path)
        return val.strip() if val is not None else None

    def path_exists(self, path: str) -> bool:
        return path in self.existing_paths or path in self.files

    def is_mount(self, path: str) -> bool:
        return path in self.mounts

    def glob_paths(self, pattern: str) -> list[str]:
        candidates = self.existing_paths | set(self.files.keys())
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
        self.cmd_log.append(key)
        if key in self.commands:
            return self.commands[key]
        # Match by prefix for commands such as psql -X -tAc <SQL>
        for registered, result in self.commands.items():
            if len(key) >= len(registered) and key[: len(registered)] == registered:
                return result
        return CommandResult(stdout="", stderr="", returncode=1)

    def get_loadavg(self) -> tuple[float, float, float] | None:
        return self.loadavg

    def get_total_ram_kb(self) -> int:
        return self.total_ram_kb

    def get_hostname(self) -> str:
        return self.hostname

    def get_fqdn(self) -> str:
        return self.fqdn

    def get_architecture(self) -> str:
        return self.architecture

    def get_kernel_release(self) -> str:
        return self.kernel_release

    def get_uname(self) -> dict[str, str]:
        return {
            "system": "Linux",
            "node": self.hostname,
            "release": self.kernel_release,
            "version": "#1 SMP PREEMPT",
            "machine": self.architecture,
        }

    def sleep(self, seconds: float) -> None:
        del seconds


def _make_cpuinfo(hart_count: int, *, include_trailing_metadata: bool = True) -> str:
    stanzas = [
        "\n".join(
            [
                f"processor\t: {idx}",
                f"hart\t\t: {idx}",
                "isa\t\t: rv64imafdc_zba_zbb",
                "mmu\t\t: sv39",
            ]
        )
        for idx in range(hart_count)
    ]
    if include_trailing_metadata:
        stanzas.append(
            "\n".join(
                [
                    "Hardware\t: SiFive HiFive Premier P550",
                    "Serial\t\t: SN-BOARD-0001",
                    "Model\t\t: Synthetic Test Board Rev B",
                ]
            )
        )
    return "\n\n".join(stanzas) + "\n"


def _make_probe(
    *,
    dt_model: str = "SiFive HiFive Premier P550",
    harts: int = 4,
    total_ram_kb: int = 32_000_000,
    nvme_present: bool = True,
    nvme_speed: str = "8.0 GT/s PCIe",
    nvme_width: str = "4",
    nvme_logical_bs: str = "4096",
    lspci_output: str = "",
    pci_sysfs: dict[str, str] | None = None,
    nic_name: str = "end0",
    nic_up: bool = True,
    nic_ipv4: str | None = "198.51.100.25",
    pg_active: bool = True,
    pg_io_method: str = "io_uring",
    nr_hugepages: str = "2048",
    mqtt_active: bool = True,
    nfs_ganesha_active: bool = True,
    nfs_kernel_active: bool = False,
    ganesha_conf: str | None = None,
    proc_cmdline: str = "console=ttyS0 root=PARTUUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    dmesg_output: str = "",
) -> FakeSystemProbe:
    files: dict[str, str] = {
        "/proc/device-tree/model": dt_model + "\x00",
        "/proc/cpuinfo": _make_cpuinfo(harts),
        "/proc/meminfo": (
            f"MemTotal:       {total_ram_kb} kB\n"
            f"MemAvailable:   {total_ram_kb - 1024} kB\n"
        ),
        "/proc/uptime": "12345.67 45678.90\n",
        "/proc/cmdline": proc_cmdline,
        "/etc/os-release": 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\n',
        "/etc/resolv.conf": "nameserver 198.51.100.1\n",
        "/sys/class/thermal/thermal_zone0/type": "soc-thermal",
        "/sys/class/thermal/thermal_zone0/temp": "41500",
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq": "1400000",
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor": "performance",
        "/proc/sys/kernel/perf_event_paranoid": "-1",
        "/proc/sys/kernel/kptr_restrict": "1",
        "/proc/sys/kernel/io_uring_disabled": "0",
        "/proc/sys/vm/nr_hugepages": nr_hugepages,
        "/proc/sys/vm/swappiness": "10",
        "/proc/sys/vm/dirty_background_bytes": "67108864",
        "/proc/sys/vm/dirty_bytes": "268435456",
    }
    existing: set[str] = {"/sys/class/thermal/thermal_zone0"}

    if nvme_present:
        existing.add("/sys/block/nvme0n1")
        files.update(
            {
                "/sys/block/nvme0n1/size": "3907029168",
                "/sys/block/nvme0n1/device/model": "SYNTHETIC NVMe 2TB",
                "/sys/block/nvme0n1/device/serial": "SN-NVME-TEST-0001",
                "/sys/block/nvme0n1/device/firmware_rev": "1.0.0",
                "/sys/block/nvme0n1/queue/logical_block_size": nvme_logical_bs,
                "/sys/block/nvme0n1/queue/physical_block_size": nvme_logical_bs,
                "/sys/class/nvme/nvme0/device/current_link_speed": nvme_speed,
                "/sys/class/nvme/nvme0/device/current_link_width": nvme_width,
                "/sys/class/nvme/nvme0/device/max_link_speed": nvme_speed,
                "/sys/class/nvme/nvme0/device/max_link_width": nvme_width,
            }
        )

    if pci_sysfs:
        files.update(pci_sysfs)

    if ganesha_conf is not None:
        files["/etc/ganesha/ganesha.conf"] = ganesha_conf
    elif nfs_ganesha_active:
        files["/etc/ganesha/ganesha.conf"] = (
            'EXPORT {\n'
            '  Export_Id = 10;\n'
            '  Path = "/mnt/vault";\n'
            '  Pseudo = "/vault";\n'
            '  CLIENT { Clients = 198.51.100.0/24; Access_Type = RW; }\n'
            '}\n'
        )

    addr_info: list[dict[str, Any]] = []
    if nic_ipv4:
        addr_info.append({"family": "inet", "local": nic_ipv4, "scope": "global"})
    ip_ifaces = [
        {
            "ifname": nic_name,
            "operstate": "UP" if nic_up else "DOWN",
            "addr_info": addr_info,
        }
    ]
    ip_routes = [{"dst": "default", "dev": nic_name}]

    lsblk_doc = {
        "blockdevices": [
            {
                "name": "nvme0n1",
                "path": "/dev/nvme0n1",
                "size": 2_000_398_934_016,
                "type": "disk",
                "tran": "nvme",
                "serial": "SN-NVME-TEST-0001",
                "uuid": "11111111-2222-3333-4444-555555555555",
                "partuuid": None,
                "mountpoint": None,
                "children": [
                    {
                        "name": "nvme0n1p1",
                        "path": "/dev/nvme0n1p1",
                        "size": 1_000_000_000_000,
                        "type": "part",
                        "serial": None,
                        "uuid": "22222222-3333-4444-5555-666666666666",
                        "partuuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                        "mountpoint": "/home/benchuser/mnt",
                    }
                ],
            }
        ]
    }

    pg_json = json.dumps(
        {
            "settings": {
                "server_version": "18.6",
                "data_directory": "/mnt/pgdata/18/main",
                "io_method": pg_io_method,
                "io_workers": "4",
                "io_combine_limit": "128kB",
                "io_max_combine_limit": "1MB",
                "io_max_concurrency": "64",
                "effective_io_concurrency": "32",
                "maintenance_io_concurrency": "32",
                "track_io_timing": "on",
                "shared_buffers": "8GB",
                "huge_pages": "try",
                "huge_pages_status": "on",
                "effective_cache_size": "24GB",
                "work_mem": "64MB",
                "maintenance_work_mem": "1GB",
                "wal_compression": "zstd",
                "random_page_cost": "1.1",
            },
            "tablespaces": ["ts_warm_vault"],
        }
    )

    commands: dict[tuple[str, ...], CommandResult] = {
        ("lsblk", "-J"): CommandResult(stdout=json.dumps(lsblk_doc)),
        ("lsusb", "-t"): CommandResult(stdout="/:  Bus 02.Port 1: Dev 1, 5000M\n"),
        ("lspci", "-nn"): CommandResult(stdout=lspci_output),
        ("ip", "-j", "addr", "show"): CommandResult(stdout=json.dumps(ip_ifaces)),
        ("ip", "-j", "route", "show"): CommandResult(stdout=json.dumps(ip_routes)),
        ("dmesg",): CommandResult(stdout=dmesg_output),
        ("ps", "-eo"): CommandResult(
            stdout="PID PPID USER STAT %CPU %MEM RSS COMMAND COMMAND\n"
            "1 0 root Ss 0.0 0.1 12000 systemd /sbin/init\n"
        ),
        ("dpkg-query", "-W"): CommandResult(
            stdout="postgresql-18\t18.6-1\triscv64\tinstall ok installed\n"
        ),
        ("psql", "--version"): CommandResult(stdout="psql (PostgreSQL) 18.6"),
        ("systemctl", "is-active", "postgresql"): CommandResult(
            stdout="active" if pg_active else "inactive",
            returncode=0 if pg_active else 3,
        ),
        ("sudo", "-n", "-u", "postgres", "psql", "-X", "-tAc"): CommandResult(stdout=pg_json),
        ("systemctl", "is-active", "mosquitto"): CommandResult(
            stdout="active" if mqtt_active else "inactive",
            returncode=0 if mqtt_active else 3,
        ),
        ("systemctl", "is-active", "nfs-server.service"): CommandResult(
            stdout="active" if nfs_kernel_active else "inactive",
            returncode=0 if nfs_kernel_active else 3,
        ),
        ("systemctl", "is-active", "nfs-ganesha.service"): CommandResult(
            stdout="active" if nfs_ganesha_active else "inactive",
            returncode=0 if nfs_ganesha_active else 3,
        ),
        ("systemctl", "get-default"): CommandResult(stdout="multi-user.target"),
        ("python3", "--version"): CommandResult(stdout="Python 3.12.14"),
    }

    return FakeSystemProbe(
        files=files,
        existing_paths=existing,
        commands=commands,
        total_ram_kb=total_ram_kb,
    )


def _assertions_by_id(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    assertions = payload["operational_readiness_test"]["assertions"]
    return {str(item["id"]): item for item in assertions}


def test_hart_counting_ignores_trailing_non_hart_stanzas() -> None:
    cpuinfo = _make_cpuinfo(4, include_trailing_metadata=True)
    harts = parse_cpuinfo_harts(cpuinfo)
    assert len(harts) == 4
    assert [h["hart"] for h in harts] == ["0", "1", "2", "3"]

    # Also handle stanzas with only 'processor' or only 'hart' plus trailing SoC summary
    mixed = (
        "processor : 0\nisa : rv64gc\n\n"
        "hart : 1\nisa : rv64gc\n\n"
        "uarch : sifive,u74-mc\n"
        "Hardware : StarFive VisionFive 2\n"
    )
    mixed_harts = parse_cpuinfo_harts(mixed)
    assert len(mixed_harts) == 2


def test_soc_profile_matrix_and_dt_vendor_qualification() -> None:
    expected_slugs = {
        "eswin-eic7700x",
        "starfive-jh7110",
        "spacemit-k1",
        "spacemit-k3",
        "ultrarisc-dp1000",
        "sifive-fu740",
        "tenstorrent-atlantis",
        "generic-riscv64",
    }
    assert set(SOC_PROFILES.keys()) == expected_slugs

    # Bare K1/K3/M1 revision strings must NOT falsely match SpacemiT profiles
    assert detect_soc_from_dt_model("Generic Dev Board Rev K1-M1-K3") is None
    assert detect_soc_from_dt_model("Milk-V Jupiter SpacemiT K1") == "spacemit-k1"
    assert detect_soc_from_dt_model("Milk-V Jupiter 2") == "spacemit-k3"
    assert detect_soc_from_dt_model("SiFive HiFive Premier P550") == "eswin-eic7700x"
    assert detect_soc_from_dt_model("StarFive VisionFive 2 v1.3B") == "starfive-jh7110"


@pytest.mark.parametrize(
    ("ram_kb", "expected_status"),
    [
        (3_900_000, "PASS"),  # 4GB VF2 variant
        (7_900_000, "PASS"),  # 8GB VF2 variant
        (1_900_000, "FAIL"),  # Below 3.5 GiB floor
    ],
)
def test_jh7110_4gb_and_8gb_variants(ram_kb: int, expected_status: str) -> None:
    probe = _make_probe(
        dt_model="StarFive VisionFive 2 v1.3B",
        harts=4,
        total_ram_kb=ram_kb,
        nvme_speed="5.0 GT/s PCIe",
        nvme_width="1",
    )
    assert isinstance(probe, SystemProbe)
    payload, _, soc_slug, node_role = collect_snapshot(
        probe,
        soc="starfive-jh7110",
        stage="day0-pre-forge",
        node_env={"NODE_ROLE": "databench"},
        kit_env={},
        window_sec=0.0,
        env={},
    )
    assert soc_slug == "starfive-jh7110"
    assert node_role == "databench"
    assert payload["artifact"]["target_designation"] == "starfive-jh7110 (databench)"
    checks = _assertions_by_id(payload)
    assert checks["ORT-01_CPU_HARTS"]["status"] == "PASS"
    assert checks["ORT-02_LPDDR4_CAPACITY"]["status"] == expected_status
    assert checks["ORT-03_PCIE_NVME_LINK"]["status"] == "PASS"

    ts = datetime.datetime(2026, 11, 24, 0, 0, 0, tzinfo=datetime.UTC)
    bench_stem = build_snapshot_stem("databench", "day0-pre-forge", ts)
    broker_stem = build_snapshot_stem("databroker", "day0-pre-forge", ts)
    assert bench_stem.startswith("brakerbench-snapshot-")
    assert broker_stem.startswith("brakerbox-snapshot-")


@pytest.mark.parametrize(
    ("ram_kb", "expected_status"),
    [
        (15_600_000, "PASS"),  # 16GB EIC7700X variant
        (31_800_000, "PASS"),  # 32GB EIC7700X variant
        (8_000_000, "FAIL"),  # Below 14 GiB floor
    ],
)
def test_eic7700x_16gb_and_32gb_variants(ram_kb: int, expected_status: str) -> None:
    probe = _make_probe(
        dt_model="SiFive HiFive Premier P550",
        harts=4,
        total_ram_kb=ram_kb,
        nvme_speed="8.0 GT/s PCIe",
        nvme_width="4",
    )
    payload, _, soc_slug, node_role = collect_snapshot(
        probe,
        soc="eswin-eic7700x",
        stage="day0-pre-forge",
        node_env={"NODE_ROLE": "databroker"},
        kit_env={},
        window_sec=0.0,
        env={},
    )
    assert soc_slug == "eswin-eic7700x"
    assert node_role == "databroker"
    assert payload["artifact"]["target_designation"] == "eswin-eic7700x (databroker)"
    checks = _assertions_by_id(payload)
    assert checks["ORT-02_LPDDR5_CAPACITY"]["status"] == expected_status
    assert checks["ORT-03_PCIE_NVME_LINK"]["status"] == "PASS"


@pytest.mark.parametrize(
    ("lspci_line", "pci_addr", "expected_vendor"),
    [
        (
            "0000:01:00.0 Co-processor [0b40]: "
            "Hailo Technologies Ltd. Hailo-8 [1e60:2864] (rev 01)",
            "0000:01:00.0",
            "1e60",
        ),
        (
            "0000:02:00.0 Processing accelerators [1200]: Tenstorrent Inc Blackhole [1e52:401e]",
            "0000:02:00.0",
            "1e52",
        ),
    ],
)
def test_npu_only_visionbench_passes_without_nvme(
    lspci_line: str,
    pci_addr: str,
    expected_vendor: str,
) -> None:
    probe = _make_probe(
        dt_model="StarFive VisionFive 2 v1.3B",
        harts=4,
        total_ram_kb=7_900_000,
        nvme_present=False,
        lspci_output=lspci_line,
        pci_sysfs={
            f"/sys/bus/pci/devices/{pci_addr}/current_link_speed": "5.0 GT/s PCIe",
            f"/sys/bus/pci/devices/{pci_addr}/current_link_width": "1",
        },
        pg_active=False,
        mqtt_active=False,
        nfs_ganesha_active=False,
    )
    payload, _, _, node_role = collect_snapshot(
        probe,
        soc="starfive-jh7110",
        stage="day1-post-forge",
        node_env={"NODE_ROLE": "visionbench", "ENABLE_POSTGRES": "false"},
        kit_env={},
        window_sec=0.0,
        env={},
    )
    assert node_role == "visionbench"
    checks = _assertions_by_id(payload)
    assert "ORT-03_PCIE_ACCELERATOR_LINK" in checks
    assert "ORT-03_PCIE_NVME_LINK" not in checks
    assert checks["ORT-03_PCIE_ACCELERATOR_LINK"]["status"] == "PASS"
    assert expected_vendor in str(checks["ORT-03_PCIE_ACCELERATOR_LINK"]["actual"])
    assert payload["operational_readiness_test"]["overall_status"] == "PASS"

    # When NEITHER NVMe nor PCIe accelerator is present, visionbench must FAIL ORT-03
    empty_probe = _make_probe(
        dt_model="StarFive VisionFive 2 v1.3B",
        harts=4,
        total_ram_kb=7_900_000,
        nvme_present=False,
        lspci_output="",
    )
    empty_payload, _, _, _ = collect_snapshot(
        empty_probe,
        soc="starfive-jh7110",
        stage="day0-pre-forge",
        node_env={"NODE_ROLE": "visionbench", "ENABLE_POSTGRES": "false"},
        kit_env={},
        window_sec=0.0,
        env={},
    )
    empty_checks = _assertions_by_id(empty_payload)
    assert empty_checks["ORT-03_PCIE_ACCELERATOR_LINK"]["status"] == "FAIL"
    assert empty_payload["operational_readiness_test"]["overall_status"] == "FAIL"


def test_generic_riscv64_profile_passes_with_flexible_harts() -> None:
    probe = _make_probe(
        dt_model="Synthetic Generic RISC-V Board",
        harts=16,
        total_ram_kb=16_000_000,
        nvme_speed="8.0 GT/s PCIe",
        nvme_width="2",
    )
    payload, _, soc_slug, _ = collect_snapshot(
        probe,
        soc="generic-riscv64",
        stage="day0-pre-forge",
        node_env={"NODE_ROLE": "devbench"},
        kit_env={},
        window_sec=0.0,
        env={},
    )
    assert soc_slug == "generic-riscv64"
    checks = _assertions_by_id(payload)
    assert checks["ORT-01_CPU_HARTS"]["status"] == "PASS"
    assert checks["ORT-01_CPU_HARTS"]["actual"] == 16
    assert checks["ORT-03_PCIE_NVME_LINK"]["status"] == "PASS"
    assert payload["operational_readiness_test"]["overall_status"] == "PASS"


def test_day0_vs_day1_assertions_single_shot_psql_and_cli_exit_codes(tmp_path: Path) -> None:
    # Unconverged host: 512B NVMe, PG worker mode, 0 hugepages, MQTT/NFS down
    unconverged_probe = _make_probe(
        nvme_logical_bs="512",
        pg_active=True,
        pg_io_method="worker",
        nr_hugepages="0",
        mqtt_active=False,
        nfs_ganesha_active=False,
    )

    # Day-0 pre-forge should NOT enforce Day-1 service/4Kn/io_uring assertions
    day0_payload, _, _, _ = collect_snapshot(
        unconverged_probe,
        soc="eswin-eic7700x",
        stage="day0-pre-forge",
        node_env={
            "NODE_ROLE": "databroker",
            "ENABLE_POSTGRES": "true",
            "ENABLE_MQTT_BROKER": "true",
            "ENABLE_NFS_SERVER": "true",
        },
        kit_env={},
        window_sec=0.0,
        env={},
    )
    day0_checks = _assertions_by_id(day0_payload)
    assert "ORT-D1_NVME_4KN" not in day0_checks
    assert day0_payload["operational_readiness_test"]["overall_status"] == "PASS"

    # Verify single-shot psql and zero sysctl subprocess invocations
    psql_queries = [c for c in unconverged_probe.cmd_log if "psql" in c and "-tAc" in c]
    assert len(psql_queries) == 1
    assert not any(c and c[0] == "sysctl" for c in unconverged_probe.cmd_log)

    # Day-1 on unconverged host MUST fail all Day-1 assertions and exit 1 via CLI
    cfg = tmp_path / "node.env"
    cfg.write_text(
        'NODE_ROLE="databroker"\n'
        'ENABLE_POSTGRES="true"\n'
        'ENABLE_MQTT_BROKER="true"\n'
        'ENABLE_NFS_SERVER="true"\n',
        encoding="utf-8",
    )
    out_fail = tmp_path / "out_fail"
    rc_fail = main(
        [
            "--soc",
            "eswin-eic7700x",
            "--stage",
            "day1-post-forge",
            "--config",
            str(cfg),
            "--out-dir",
            str(out_fail),
            "--window",
            "0",
            "--quiet",
        ],
        probe=unconverged_probe,
    )
    assert rc_fail == 1

    # Same failing Day-1 run with --no-fail-exit must exit 0
    rc_override = main(
        [
            "--soc",
            "eswin-eic7700x",
            "--stage",
            "day1-post-forge",
            "--config",
            str(cfg),
            "--out-dir",
            str(out_fail),
            "--window",
            "0",
            "--no-fail-exit",
            "--quiet",
        ],
        probe=unconverged_probe,
    )
    assert rc_override == 0

    # Converged Day-1 host MUST pass all Day-1 assertions and exit 0
    converged_probe = _make_probe(
        nvme_logical_bs="4096",
        pg_active=True,
        pg_io_method="io_uring",
        nr_hugepages="2048",
        mqtt_active=True,
        nfs_ganesha_active=True,
    )
    out_pass = tmp_path / "out_pass"
    rc_pass = main(
        [
            "--soc",
            "eswin-eic7700x",
            "--stage",
            "converged-idempotent",
            "--config",
            str(cfg),
            "--out-dir",
            str(out_pass),
            "--window",
            "0",
            "--quiet",
        ],
        probe=converged_probe,
    )
    assert rc_pass == 0

    priv_files = [p for p in out_pass.glob("*.json") if not p.name.endswith(".public.json")]
    assert len(priv_files) == 1
    converged_doc = json.loads(priv_files[0].read_text(encoding="utf-8"))
    d1_checks = _assertions_by_id(converged_doc)
    for req_id in (
        "ORT-D1_NVME_4KN",
        "ORT-D1_POSTGRES_ACTIVE",
        "ORT-D1_POSTGRES_IO_URING",
        "ORT-D1_VM_HUGEPAGES",
        "ORT-D1_MQTT_ACTIVE",
        "ORT-D1_NFS_ACTIVE",
    ):
        assert d1_checks[req_id]["status"] == "PASS"


def test_nic_requires_global_ipv4_and_ganesha_exports_parsed() -> None:
    ifaces_no_ip = [{"ifname": "end0", "operstate": "UP", "addr_info": []}]
    routes = [{"dst": "default", "dev": "end0"}]
    nic_down_ip = detect_primary_nic(ifaces_no_ip, routes, {})
    assert nic_down_ip.operstate == "UP"
    assert not nic_down_ip.has_global_ipv4
    assert not nic_down_ip.healthy

    checks = evaluate_assertions(
        profile=get_soc_profile("eswin-eic7700x"),
        stage="day0-pre-forge",
        node_role="databench",
        node_env={},
        harts=[{"hart": str(i)} for i in range(4)],
        total_ram_kb=32_000_000,
        nvme_present=True,
        nvme_info={"pcie_link_speed": "8.0 GT/s PCIe", "pcie_link_width": "4"},
        pcie_accelerators=[],
        raid_ort_checks=[],
        primary_nic=nic_down_ip,
        soc_peak_c=40.0,
        bus_errors=[],
        postgres_state={},
        broker_services_state={},
        sysctl_baseline={},
        env={},
    )
    nic_chk = next(c for c in checks if "PRIMARY_NIC" in c["id"])
    assert nic_chk["status"] == "FAIL"

    ganesha_text = """
    # NFS-Ganesha synthetic config
    EXPORT {
        Export_Id = 42;
        Path = "/mnt/warm_vault";
        Pseudo = "/warm_vault";
        CLIENT {
            Clients = 198.51.100.0/24;
            Access_Type = RW;
        }
    }
    """
    exports = parse_ganesha_exports(ganesha_text)
    assert len(exports) == 1
    assert "/mnt/warm_vault" in exports[0]
    assert "198.51.100.0/24" in exports[0]

    probe = _make_probe(nfs_ganesha_active=True, ganesha_conf=ganesha_text)
    svc = inspect_databroker_services({"MQTT_PORT": "1883"}, probe)
    assert svc["nfs_v4_server"]["backend"] == "nfs-ganesha"
    assert svc["nfs_v4_server"]["configured_exports"] == exports

    pg_state = inspect_postgres_state(probe)
    assert pg_state["active_runtime_parameters"]["io_method"] == "io_uring"
    assert pg_state["custom_tablespaces"] == ["ts_warm_vault"]

    sysctls = read_sysctl_baseline(probe)
    assert sysctls["vm.nr_hugepages"] == "2048"


def test_public_redaction_provenance_signing_and_atomic_permissions(tmp_path: Path) -> None:
    secret_nvme_serial = "SN-NVME-TEST-0001"
    secret_dmesg_serial = "SN-DMESG-TEST-9999"
    secret_uuid = "11111111-2222-3333-4444-555555555555"
    secret_partuuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    secret_mac = "02:42:ac:11:00:09"
    secret_tskey = "tskey-auth-kTestSynthetic99999"
    secret_cidr = "198.51.100.0/24"
    secret_user = "benchuser"
    secret_home = f"/home/{secret_user}"

    probe = _make_probe(
        proc_cmdline=(
            f"console=ttyS0 root=UUID={secret_uuid} resume=PARTUUID={secret_partuuid} "
            f"mac={secret_mac} auth={secret_tskey} home={secret_home} user={secret_user}"
        ),
        dmesg_output=(
            f"[   12.34] pcieport 0000:00:00.0: AER: Corrected error "
            f"SerialNumber={secret_dmesg_serial} mac={secret_mac} uuid={secret_uuid} "
            f"key={secret_tskey} path={secret_home}/data\n"
        ),
        nfs_ganesha_active=True,
        ganesha_conf=(
            'EXPORT {\n'
            '  Export_Id = 1;\n'
            '  Path = "/mnt/vault";\n'
            f'  CLIENT {{ Clients = {secret_cidr}; Access_Type = RW; }}\n'
            '}\n'
        ),
    )

    payload, primary_nic, _, _ = collect_snapshot(
        probe,
        soc="eswin-eic7700x",
        stage="day1-post-forge",
        node_env={"NODE_ROLE": "databroker"},
        kit_env={},
        window_sec=0.0,
        env={},
    )
    # Inject synthetic human operator record to validate security_and_users stripping + scrubbing
    payload["security_and_users"]["human_and_root_users"].append(
        {
            "username": secret_user,
            "uid": 1001,
            "gid": 1001,
            "primary_group": secret_user,
            "supplementary_groups": ["sudo"],
            "home": secret_home,
            "shell": "/bin/bash",
        }
    )

    # Re-sign after test fixture mutation so private digest matches payload
    sign_snapshot(payload, redacted=False)
    assert verify_snapshot_signature(payload)

    owner = UserIdentity(
        username=secret_user,
        groupname=secret_user,
        home=secret_home,
        uid=None,
        gid=None,
    )
    outputs = write_snapshot_pair(
        payload,
        out_dir=tmp_path / "snaps",
        base_stem="brakerbox-snapshot-day1-test",
        primary_nic=primary_nic,
        write_public=True,
        owner=owner,
    )

    assert outputs.private_path.is_file()
    assert outputs.public_path is not None and outputs.public_path.is_file()
    assert stat.S_IMODE(outputs.private_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(outputs.public_path.stat().st_mode) == 0o644

    priv_loaded = json.loads(outputs.private_path.read_text(encoding="utf-8"))
    pub_loaded = json.loads(outputs.public_path.read_text(encoding="utf-8"))

    # Canonical SHA-256 verification on both manifests + tamper detection
    assert verify_snapshot_signature(priv_loaded)
    assert verify_snapshot_signature(pub_loaded)
    assert (
        pub_loaded["provenance_signature"]["unredacted_vault_sha256"]
        == priv_loaded["provenance_signature"]["canonical_payload_sha256"]
    )
    assert compute_canonical_sha256(pub_loaded) == outputs.public_sha256

    tampered = dict(pub_loaded)
    tampered["artifact"] = dict(pub_loaded["artifact"], stage="tampered")
    assert not verify_snapshot_signature(tampered)

    # Strict .public.json redaction completeness
    pub_text = json.dumps(pub_loaded)
    for forbidden_secret in (
        secret_nvme_serial,
        secret_dmesg_serial,
        secret_uuid,
        secret_partuuid,
        secret_mac,
        secret_tskey,
        secret_cidr,
        secret_user,
        secret_home,
    ):
        assert forbidden_secret not in pub_text, (
            f"Leaked secret in .public.json: {forbidden_secret}"
        )

    assert "security_and_users" not in pub_loaded
    assert "installed_apt_packages" not in pub_loaded["software_provenance"]
    assert pub_loaded["network_topology"]["primary_nic"] == "end0"
    assert pub_loaded["network_topology"]["primary_nic_operstate"] == "UP"
    assert pub_loaded["network_topology"]["primary_nic_has_ipv4"] is True
    assert "interfaces" not in pub_loaded["network_topology"]
    assert "routes" not in pub_loaded["network_topology"]

    # Direct build_public_snapshot also handles kernel /etc/exports CIDR redaction
    direct_pub = build_public_snapshot(
        priv_loaded,
        outputs.private_sha256,
        "end0",
        True,
        nic_has_ipv4=True,
        extra_usernames=(secret_user,),
    )
    assert verify_snapshot_signature(direct_pub)
    exports_redacted = direct_pub["databroker_services_state"]["nfs_v4_server"][
        "configured_exports"
    ]
    assert exports_redacted and all("REDACTED_SUBNET" in e for e in exports_redacted)


def test_parse_kv_content_multiline_raid_json_and_empty_subnet() -> None:
    raw = (
        'NODE_ROLE="databroker"\n'
        'LAB_SUBNET=""\n'
        'WITH_RAID="true"\n'
        "RAID_ARRAYS_JSON='[\n"
        '  {"name": "WarmVault", "disks": 4, "mount": "/mnt/warm_vault"}\n'
        "]'\n"
    )
    parsed = parse_kv_content(raw)
    assert parsed["NODE_ROLE"] == "databroker"
    assert parsed["LAB_SUBNET"] == ""
    arrays = json.loads(parsed["RAID_ARRAYS_JSON"])
    assert len(arrays) == 1
    assert arrays[0]["name"] == "WarmVault"


def test_brakerrak_ort_is_strictly_stdlib_only() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    ort_dir = repo_root / "brakerrak_ort"
    stdlib_names = sys.stdlib_module_names
    for py_file in sorted(ort_dir.glob("*.py")):
        tree = ast.parse(py_file.read_text(encoding="utf-8"), filename=str(py_file))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    top = alias.name.split(".", 1)[0]
                    assert top == "brakerrak_ort" or top in stdlib_names, (
                        f"Non-stdlib import {alias.name!r} in {py_file.name}"
                    )
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                top = node.module.split(".", 1)[0]
                assert top == "brakerrak_ort" or top in stdlib_names, (
                    f"Non-stdlib import {node.module!r} in {py_file.name}"
                )
