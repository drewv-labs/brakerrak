"""Declarative RISC-V SoC profiles, role taxonomy, and PCIe accelerator tables."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SocProfile:
    """Declarative hardware validation thresholds for a target RISC-V SoC."""

    slug: str
    expected_harts: int | None
    cpu_desc: str
    ram_check_id: str
    ram_floor_kb: int
    ram_variants_gb: tuple[int, ...]
    ram_desc: str
    pcie_desc: str
    min_gt_s: float
    min_width: int
    thermal_ceiling_c: float
    usb_desc: str = "Rear USB 3.0 Ports Negotiated at 5000M SuperSpeed"


@dataclass(frozen=True)
class RoleDefaults:
    """Default service enablement flags for each BrakerRak node persona."""

    stem: str
    enable_postgres: bool
    enable_mqtt_broker: bool
    enable_nfs_server: bool


SOC_PROFILES: dict[str, SocProfile] = {
    "eswin-eic7700x": SocProfile(
        slug="eswin-eic7700x",
        expected_harts=4,
        cpu_desc="4x SiFive P550 Harts Online (rv64imafdc_zba_zbb)",
        ram_check_id="ORT-02_LPDDR5_CAPACITY",
        ram_floor_kb=14_000_000,
        ram_variants_gb=(16, 32),
        ram_desc="16GB/32GB LPDDR5 System Memory Detected (>= 14 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen3 x4 (>= 8.0 GT/s, Width x4)",
        min_gt_s=8.0,
        min_width=4,
        thermal_ceiling_c=55.0,
        usb_desc="Rear Teal USB 3.2 Gen1 Ports Negotiated at 5000M SuperSpeed",
    ),
    "starfive-jh7110": SocProfile(
        slug="starfive-jh7110",
        expected_harts=4,
        cpu_desc="4x SiFive U74 Harts Online (rv64imafdc_zba_zbb)",
        ram_check_id="ORT-02_LPDDR4_CAPACITY",
        ram_floor_kb=3_500_000,
        ram_variants_gb=(4, 8),
        ram_desc="4GB/8GB LPDDR4 System Memory Detected (>= 3.5 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen2 x1 (>= 5.0 GT/s, Width x1)",
        min_gt_s=5.0,
        min_width=1,
        thermal_ceiling_c=55.0,
    ),
    "spacemit-k1": SocProfile(
        slug="spacemit-k1",
        expected_harts=8,
        cpu_desc="8x SpacemiT X60 Harts Online (RVA22 + 256-bit RVV 1.0)",
        ram_check_id="ORT-02_MEMORY_CAPACITY",
        ram_floor_kb=3_500_000,
        ram_variants_gb=(4, 8, 16),
        ram_desc="LPDDR4X System Memory Detected (>= 3.5 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen2+ (>= 5.0 GT/s)",
        min_gt_s=5.0,
        min_width=1,
        thermal_ceiling_c=60.0,
    ),
    "spacemit-k3": SocProfile(
        slug="spacemit-k3",
        expected_harts=8,
        cpu_desc="8x SpacemiT X100 Harts Online (RVA23 + 1024-bit RVV 1.0)",
        ram_check_id="ORT-02_MEMORY_CAPACITY",
        ram_floor_kb=14_000_000,
        ram_variants_gb=(16, 32),
        ram_desc="LPDDR5 System Memory Detected (>= 14 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen3+ (>= 8.0 GT/s)",
        min_gt_s=8.0,
        min_width=1,
        thermal_ceiling_c=60.0,
    ),
    "ultrarisc-dp1000": SocProfile(
        slug="ultrarisc-dp1000",
        expected_harts=8,
        cpu_desc="8x UltraRISC UR-CP100 Harts Online (RVA22 + H-Ext 1.0)",
        ram_check_id="ORT-02_MEMORY_CAPACITY",
        ram_floor_kb=14_000_000,
        ram_variants_gb=(16, 32, 64),
        ram_desc="DDR4 System Memory Detected (>= 14 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen3/Gen4 (>= 8.0 GT/s)",
        min_gt_s=8.0,
        min_width=1,
        thermal_ceiling_c=60.0,
    ),
    "sifive-fu740": SocProfile(
        slug="sifive-fu740",
        expected_harts=4,
        cpu_desc="4x SiFive U74 Application Harts Online (RV64GC)",
        ram_check_id="ORT-02_MEMORY_CAPACITY",
        ram_floor_kb=14_000_000,
        ram_variants_gb=(16,),
        ram_desc="16GB DDR4 System Memory Detected (>= 14 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen3 (>= 8.0 GT/s)",
        min_gt_s=8.0,
        min_width=1,
        thermal_ceiling_c=60.0,
    ),
    "tenstorrent-atlantis": SocProfile(
        slug="tenstorrent-atlantis",
        expected_harts=8,
        cpu_desc="8x Tenstorrent Ascalon-X Harts Online (RVA23 + 256-bit RVV 1.0)",
        ram_check_id="ORT-02_MEMORY_CAPACITY",
        ram_floor_kb=30_000_000,
        ram_variants_gb=(32, 64, 128),
        ram_desc="High-Bandwidth System Memory Detected (>= 30 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen4/Gen5 (>= 8.0 GT/s)",
        min_gt_s=8.0,
        min_width=1,
        thermal_ceiling_c=60.0,
    ),
    "generic-riscv64": SocProfile(
        slug="generic-riscv64",
        expected_harts=None,
        cpu_desc="RISC-V Application Harts Online",
        ram_check_id="ORT-02_MEMORY_CAPACITY",
        ram_floor_kb=3_500_000,
        ram_variants_gb=(4, 8, 16, 32, 64),
        ram_desc="System Memory Detected (>= 3.5 GiB usable)",
        pcie_desc="Primary NVMe Seated over PCIe (>= 5.0 GT/s)",
        min_gt_s=5.0,
        min_width=1,
        thermal_ceiling_c=60.0,
    ),
}

SOC_ALIASES: dict[str, str] = {
    "eswin-eic7700x": "eswin-eic7700x",
    "sifive-p550": "eswin-eic7700x",
    "milkv-megrez": "eswin-eic7700x",
    "starpro64": "eswin-eic7700x",
    "sifive-fu740": "sifive-fu740",
    "sifive-unmatched": "sifive-fu740",
    "starfive-jh7110": "starfive-jh7110",
    "starfive-vf2": "starfive-jh7110",
    "starfive-vf2-lite": "starfive-jh7110",
    "milkv-mars": "starfive-jh7110",
    "orangepi-rv": "starfive-jh7110",
    "star64": "starfive-jh7110",
    "spacemit-k1": "spacemit-k1",
    "milkv-jupiter": "spacemit-k1",
    "orangepi-rv2": "spacemit-k1",
    "orangepi-r2s": "spacemit-k1",
    "bananapi-f3": "spacemit-k1",
    "bananapi-cm6": "spacemit-k1",
    "spacemit-k3": "spacemit-k3",
    "milkv-jupiter2": "spacemit-k3",
    "firefly-aibox-k3": "spacemit-k3",
    "ultrarisc-dp1000": "ultrarisc-dp1000",
    "milkv-titan": "ultrarisc-dp1000",
    "tenstorrent-atlantis": "tenstorrent-atlantis",
    "generic-riscv64": "generic-riscv64",
}

ROLE_DEFAULTS: dict[str, RoleDefaults] = {
    "databroker": RoleDefaults(
        stem="brakerbox",
        enable_postgres=True,
        enable_mqtt_broker=True,
        enable_nfs_server=True,
    ),
    "databench": RoleDefaults(
        stem="brakerbench",
        enable_postgres=True,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
    "babbagebox": RoleDefaults(
        stem="babbagebox",
        enable_postgres=False,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
    "babbagebench": RoleDefaults(
        stem="babbagebench",
        enable_postgres=False,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
    "visionbox": RoleDefaults(
        stem="visionbox",
        enable_postgres=False,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
    "visionbench": RoleDefaults(
        stem="visionbench",
        enable_postgres=False,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
    "devbench": RoleDefaults(
        stem="devbench",
        enable_postgres=True,
        enable_mqtt_broker=True,
        enable_nfs_server=False,
    ),
}

ROLE_STEM_MAP: dict[str, str] = {role: defaults.stem for role, defaults in ROLE_DEFAULTS.items()}

# Dedicated AI/NPU PCI vendor IDs always treated as PCIe accelerators.
DEDICATED_ACCELERATOR_VENDORS: dict[str, str] = {
    "1e60": "Hailo NPU",
    "1e52": "Tenstorrent AI Accelerator",
    "1ac1": "Coral Edge TPU",
}

# Discrete GPU vendor IDs treated as accelerators when exposed with GPU/compute class codes.
GPU_ACCELERATOR_VENDORS: dict[str, str] = {
    "1002": "AMD GPU",
    "10de": "NVIDIA GPU",
}

ACCELERATOR_PCI_CLASSES: frozenset[str] = frozenset({"0300", "0302", "0380", "0b40", "1200"})


def normalize_soc_slug(raw_slug: str | None) -> str:
    """Normalize a SoC or board alias to one of the 8 canonical SoC slugs."""
    if not raw_slug:
        return "generic-riscv64"
    cleaned = raw_slug.strip().lower()
    if cleaned in SOC_ALIASES:
        return SOC_ALIASES[cleaned]
    if cleaned in SOC_PROFILES:
        return cleaned
    return "generic-riscv64"


def detect_soc_from_dt_model(dt_model: str | None) -> str | None:
    """Infer canonical SoC slug from /proc/device-tree/model using vendor-qualified patterns."""
    if not dt_model:
        return None
    model = dt_model.strip()
    lower = model.lower()

    if any(tok in lower for tok in ("premier p550", "megrez", "starpro64", "eic7700")):
        return "eswin-eic7700x"
    if any(tok in lower for tok in ("unmatched", "fu740")):
        return "sifive-fu740"
    if any(
        tok in lower
        for tok in (
            "orangepi rv2",
            "orange pi rv2",
            "orangepi r2s",
            "orange pi r2s",
            "bpi-f3",
            "bpi-cm6",
        )
    ):
        return "spacemit-k1"
    if any(
        tok in lower
        for tok in (
            "visionfive 2",
            "vf2",
            "jh7110",
            "jh-7110",
            "milk-v mars",
            "milkv mars",
            "star64",
            "orangepi rv",
            "orange pi rv",
        )
    ):
        return "starfive-jh7110"
    if any(
        tok in lower
        for tok in (
            "aibox-k3",
            "firefly-k3",
            "firefly k3",
            "jupiter 2",
            "jupiter2",
            "spacemit k3",
            "spacemit-k3",
        )
    ):
        return "spacemit-k3"
    if any(
        tok in lower
        for tok in (
            "milk-v jupiter",
            "milkv jupiter",
            "spacemit k1",
            "spacemit-k1",
            "spacemit m1",
            "spacemit-m1",
            "spacemit x60",
            "ky x1",
            "ky-x1",
        )
    ):
        return "spacemit-k1"
    if any(tok in lower for tok in ("milk-v titan", "milkv titan", "ultrarisc", "dp1000")):
        return "ultrarisc-dp1000"
    if any(tok in lower for tok in ("atlantis", "ascalon")):
        return "tenstorrent-atlantis"
    return None


def get_soc_profile(soc_slug: str) -> SocProfile:
    """Return the declarative SocProfile for a canonical or aliased SoC slug."""
    return SOC_PROFILES[normalize_soc_slug(soc_slug)]


def get_role_defaults(node_role: str) -> RoleDefaults:
    """Return service enablement and stem defaults for a node role."""
    cleaned = node_role.strip().lower()
    if cleaned in ROLE_DEFAULTS:
        return ROLE_DEFAULTS[cleaned]
    return RoleDefaults(
        stem="brakerrak",
        enable_postgres=True,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    )
