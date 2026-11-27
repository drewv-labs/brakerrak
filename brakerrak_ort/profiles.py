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
    arch: str = "riscv64"
    has_mmu: bool = True
    has_pcie: bool = True
    storage_bus: str = "nvme"
    supported_tunes: tuple[str, ...] = ("data", "ai", "iot")
    accel_max_gt_s: float | None = None
    accel_max_width: int | None = None


@dataclass(frozen=True)
class RoleDefaults:
    """Default service enablement flags for each BrakerRak node persona."""

    stem: str
    enable_postgres: bool
    enable_mqtt_broker: bool
    enable_nfs_server: bool


@dataclass(frozen=True)
class AcceleratorLinkSpec:
    """Expected PCIe link speed (GT/s) and minimum lane width for an accelerator vendor."""

    min_gt_s: float
    min_width: int


ACCELERATOR_PERSONAS: frozenset[str] = frozenset(
    {"visionbox", "visionbench", "babbagebox", "babbagebench"}
)


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
        pcie_desc="Primary NVMe Seated at PCIe Gen3+ (>= 8.0 GT/s, Width x2)",
        min_gt_s=8.0,
        min_width=2,
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
        pcie_desc="Primary NVMe Seated at PCIe Gen3/Gen4 (>= 8.0 GT/s, Width x4)",
        min_gt_s=8.0,
        min_width=4,
        thermal_ceiling_c=60.0,
        accel_max_gt_s=16.0,
        accel_max_width=16,
    ),
    "sifive-fu740": SocProfile(
        slug="sifive-fu740",
        expected_harts=4,
        cpu_desc="4x SiFive U74 Application Harts Online (RV64GC)",
        ram_check_id="ORT-02_MEMORY_CAPACITY",
        ram_floor_kb=14_000_000,
        ram_variants_gb=(16,),
        ram_desc="16GB DDR4 System Memory Detected (>= 14 GiB usable)",
        pcie_desc="Primary NVMe Seated at PCIe Gen3 (>= 8.0 GT/s, Width x4)",
        min_gt_s=8.0,
        min_width=4,
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
        pcie_desc="Primary NVMe Seated at PCIe Gen4/Gen5 (>= 8.0 GT/s, Width x4)",
        min_gt_s=8.0,
        min_width=4,
        thermal_ceiling_c=60.0,
        accel_max_gt_s=32.0,
        accel_max_width=16,
    ),
    "espressif-esp32p4": SocProfile(
        slug="espressif-esp32p4",
        expected_harts=2,
        cpu_desc=(
            "2x Espressif ESP32-P4 HP Harts Online "
            "(rv32imafc_zicsr_zifencei + PIE AI SIMD @ 400MHz)"
        ),
        ram_check_id="ORT-02_PSRAM_CAPACITY",
        ram_floor_kb=28_000,
        ram_variants_gb=(),
        ram_desc="32MB On-Package PSRAM Detected (>= 28,000 kB usable)",
        pcie_desc="Primary MicroSD Media Present on 4-Bit SDMMC Bus (No PCIe/NVMe on ESP32-P4)",
        min_gt_s=0.0,
        min_width=0,
        thermal_ceiling_c=65.0,
        usb_desc="USB 2.0 OTG / USB-Serial-JTAG Debug Bridge Active",
        arch="riscv32",
        has_mmu=False,
        has_pcie=False,
        storage_bus="sdmmc",
        supported_tunes=("ai", "iot"),
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
    # eswin-eic7700x
    "eswin-eic7700x": "eswin-eic7700x",
    "eswin/eic7700x": "eswin-eic7700x",
    "sifive-p550": "eswin-eic7700x",
    "sifive/p550": "eswin-eic7700x",
    "p550": "eswin-eic7700x",
    "premier-p550": "eswin-eic7700x",
    "milkv-megrez": "eswin-eic7700x",
    "milkv/megrez": "eswin-eic7700x",
    "megrez": "eswin-eic7700x",
    "pine64-starpro64": "eswin-eic7700x",
    "pine64/starpro64": "eswin-eic7700x",
    "starpro64": "eswin-eic7700x",
    # sifive-fu740
    "sifive-fu740": "sifive-fu740",
    "sifive/fu740": "sifive-fu740",
    "sifive-unmatched": "sifive-fu740",
    "sifive/unmatched": "sifive-fu740",
    "unmatched": "sifive-fu740",
    "fu740": "sifive-fu740",
    # starfive-jh7110
    "starfive-vf2-lite": "starfive-jh7110",
    "starfive/vf2-lite": "starfive-jh7110",
    "vf2-lite": "starfive-jh7110",
    "vf2lite": "starfive-jh7110",
    "milkv-mars": "starfive-jh7110",
    "milkv/mars": "starfive-jh7110",
    "mars": "starfive-jh7110",
    "pine64-star64": "starfive-jh7110",
    "pine64/star64": "starfive-jh7110",
    "star64": "starfive-jh7110",
    "orangepi-rv": "starfive-jh7110",
    "orangepi/rv": "starfive-jh7110",
    "opirv": "starfive-jh7110",
    "starfive-jh7110": "starfive-jh7110",
    "starfive/jh7110": "starfive-jh7110",
    "starfive-vf2": "starfive-jh7110",
    "starfive/vf2": "starfive-jh7110",
    "vf2": "starfive-jh7110",
    "visionfive2": "starfive-jh7110",
    # spacemit-k1
    "orangepi-rv2": "spacemit-k1",
    "orangepi/rv2": "spacemit-k1",
    "rv2": "spacemit-k1",
    "orangepi-r2s": "spacemit-k1",
    "orangepi/r2s": "spacemit-k1",
    "r2s": "spacemit-k1",
    "bananapi-f3": "spacemit-k1",
    "bananapi/f3": "spacemit-k1",
    "bpi-f3": "spacemit-k1",
    "bpif3": "spacemit-k1",
    "bananapi-cm6": "spacemit-k1",
    "bananapi/cm6": "spacemit-k1",
    "bpi-cm6": "spacemit-k1",
    "bpicm6": "spacemit-k1",
    "spacemit-k1": "spacemit-k1",
    "spacemit/k1": "spacemit-k1",
    "milkv-jupiter": "spacemit-k1",
    "milkv/jupiter": "spacemit-k1",
    "jupiter": "spacemit-k1",
    "jptr1": "spacemit-k1",
    "muse-pi": "spacemit-k1",
    "musepi": "spacemit-k1",
    # spacemit-k3
    "firefly-aibox-k3": "spacemit-k3",
    "firefly/aibox-k3": "spacemit-k3",
    "aibox-k3": "spacemit-k3",
    "aiboxk3": "spacemit-k3",
    "spacemit-k3": "spacemit-k3",
    "spacemit/k3": "spacemit-k3",
    "milkv-jupiter2": "spacemit-k3",
    "milkv/jupiter2": "spacemit-k3",
    "jupiter2": "spacemit-k3",
    "jptr2": "spacemit-k3",
    # ultrarisc-dp1000
    "ultrarisc-dp1000": "ultrarisc-dp1000",
    "ultrarisc/dp1000": "ultrarisc-dp1000",
    "milkv-titan": "ultrarisc-dp1000",
    "milkv/titan": "ultrarisc-dp1000",
    "titan": "ultrarisc-dp1000",
    "dp1000": "ultrarisc-dp1000",
    # tenstorrent-atlantis
    "tenstorrent-atlantis": "tenstorrent-atlantis",
    "tenstorrent/atlantis": "tenstorrent-atlantis",
    "atlantis": "tenstorrent-atlantis",
    "ascalon": "tenstorrent-atlantis",
    # espressif-esp32p4
    "espressif-esp32p4": "espressif-esp32p4",
    "espressif/esp32p4": "espressif-esp32p4",
    "waveshare-esp32-p4-wifi6": "espressif-esp32p4",
    "waveshare/esp32-p4-wifi6": "espressif-esp32p4",
    "waveshare-esp32-p4": "espressif-esp32p4",
    "waveshare/esp32-p4": "espressif-esp32p4",
    "waveshare-p4": "espressif-esp32p4",
    "waveshare/p4": "espressif-esp32p4",
    "esp32-p4-wifi6": "espressif-esp32p4",
    "esp32-p4-wifi6-dev-kit": "espressif-esp32p4",
    "esp32-p4": "espressif-esp32p4",
    "esp32p4": "espressif-esp32p4",
    "p4": "espressif-esp32p4",
    # generic-riscv64
    "generic-riscv64": "generic-riscv64",
    "generic": "generic-riscv64",
    "riscv64": "generic-riscv64",
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
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
    "snitchbench": RoleDefaults(
        stem="snitchbench",
        enable_postgres=False,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
    "lilsnitch": RoleDefaults(
        stem="lilsnitch",
        enable_postgres=False,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    ),
}

ROLE_STEM_MAP: dict[str, str] = {role: defaults.stem for role, defaults in ROLE_DEFAULTS.items()}

ROLE_ALIASES: dict[str, str] = {
    "prod": "databroker",
    "broker": "databroker",
    "databroker": "databroker",
    "brakerbox": "databroker",
    "brakbox": "databroker",
    "brx": "databroker",
    "bench": "databench",
    "databench": "databench",
    "brakerbench": "databench",
    "brakbnch": "databench",
    "brh": "databench",
    "babbagebox": "babbagebox",
    "babbox": "babbagebox",
    "bab": "babbagebox",
    "gpuprod": "babbagebox",
    "babbagebench": "babbagebench",
    "babbnch": "babbagebench",
    "bah": "babbagebench",
    "gpubench": "babbagebench",
    "visionbox": "visionbox",
    "visbox": "visionbox",
    "vx": "visionbox",
    "npuprod": "visionbox",
    "visionbench": "visionbench",
    "visbnch": "visionbench",
    "vh": "visionbench",
    "npubench": "visionbench",
    "visionferret": "visionbench",
    "vferret": "visionbench",
    "mlbench": "visionbench",
    "devbench": "devbench",
    "devbnch": "devbench",
    "dev": "devbench",
    "snitchbench": "snitchbench",
    "snitchbnch": "snitchbench",
    "sb": "snitchbench",
    "lilsnitch": "lilsnitch",
    "lsp4": "lilsnitch",
    "snitch": "lilsnitch",
}

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

# Expected native PCIe link floors per accelerator vendor (capped by board bus capability).
ACCELERATOR_LINK_SPECS: dict[str, AcceleratorLinkSpec] = {
    "1e60": AcceleratorLinkSpec(min_gt_s=8.0, min_width=4),
    "1e52": AcceleratorLinkSpec(min_gt_s=16.0, min_width=8),
    "1ac1": AcceleratorLinkSpec(min_gt_s=5.0, min_width=1),
    "1002": AcceleratorLinkSpec(min_gt_s=8.0, min_width=4),
    "10de": AcceleratorLinkSpec(min_gt_s=8.0, min_width=4),
}


def get_accelerator_link_floor(vendor_id: str, profile: SocProfile) -> tuple[float, int]:
    """Return expected (min_gt_s, min_width) for an accelerator capped by board bus capability."""
    if not profile.has_pcie:
        return (0.0, 0)
    spec = ACCELERATOR_LINK_SPECS.get(vendor_id.strip().lower())
    if spec is None:
        return (profile.min_gt_s, profile.min_width)
    cap_gt_s = (
        profile.accel_max_gt_s if profile.accel_max_gt_s is not None else profile.min_gt_s
    )
    cap_width = (
        profile.accel_max_width if profile.accel_max_width is not None else profile.min_width
    )
    return (
        min(spec.min_gt_s, cap_gt_s),
        min(spec.min_width, cap_width),
    )


def normalize_soc_slug(raw_slug: str | None) -> str:
    """Normalize a SoC or board alias to one of the 9 canonical SoC slugs."""
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
            "orangepi-rv2",
            "orangepi rv2",
            "orange pi rv2",
            "orangepi-r2s",
            "orangepi r2s",
            "orange pi r2s",
            "bpi-f3",
            "banana pi f3",
            "bananapi-f3",
            "bpi-cm6",
            "banana pi cm6",
            "bananapi-cm6",
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
            "milkv-mars",
            "milkv mars",
            "star64",
            "orangepi-rv",
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
            "milkv-jupiter",
            "milkv jupiter",
            "spacemit k1",
            "spacemit-k1",
            "spacemit m1",
            "spacemit-m1",
            "spacemit x60",
            "ky x1",
            "ky-x1",
            "muse pi",
            "muse book",
        )
    ):
        return "spacemit-k1"
    if any(
        tok in lower
        for tok in ("milk-v titan", "milkv-titan", "milkv titan", "ultrarisc", "dp1000")
    ):
        return "ultrarisc-dp1000"
    if any(tok in lower for tok in ("atlantis", "ascalon")):
        return "tenstorrent-atlantis"
    if any(tok in lower for tok in ("esp32-p4-wifi6", "waveshare esp32-p4", "esp32-p4", "esp32p4")):
        return "espressif-esp32p4"
    return None


def resolve_profile(identifier: str | None = None, *, dt_model: str | None = None) -> SocProfile:
    """Resolve CLI alias/slug first, then fall back to DT model detection, then generic-riscv64."""
    if identifier:
        cleaned = identifier.strip().lower()
        if cleaned in SOC_ALIASES:
            return SOC_PROFILES[SOC_ALIASES[cleaned]]
        if cleaned in SOC_PROFILES:
            return SOC_PROFILES[cleaned]

    detected = detect_soc_from_dt_model(dt_model or identifier)
    if detected and detected in SOC_PROFILES:
        return SOC_PROFILES[detected]
    return SOC_PROFILES["generic-riscv64"]


def get_soc_profile(soc_slug: str) -> SocProfile:
    """Return the declarative SocProfile for a canonical or aliased SoC slug."""
    return SOC_PROFILES[normalize_soc_slug(soc_slug)]


def normalize_role(raw_role: str | None) -> str | None:
    """Normalize a BrakerRak role or alias to a canonical role slug, or None if unrecognized."""
    if not raw_role:
        return None
    cleaned = raw_role.strip().lower()
    if cleaned in ROLE_ALIASES:
        return ROLE_ALIASES[cleaned]
    if cleaned in ROLE_DEFAULTS:
        return cleaned
    return None


def get_role_defaults(node_role: str) -> RoleDefaults:
    """Return service enablement and stem defaults for a node role."""
    cleaned = normalize_role(node_role) or node_role.strip().lower()
    if cleaned in ROLE_DEFAULTS:
        return ROLE_DEFAULTS[cleaned]
    return RoleDefaults(
        stem="brakerrak",
        enable_postgres=True,
        enable_mqtt_broker=False,
        enable_nfs_server=False,
    )
