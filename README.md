<div align="center">

# BrakerRak

**Declarative, Plug-n-Play Bare-Metal RISC-V Data & Edge ML R&D Deployment Engine**  
...the Silicon is gonna Sing!  

</div>

---

`BrakerRak` (named in tribute to database pioneer [Michael Stonebraker](https://en.wikipedia.org/wiki/Michael_Stonebraker)) is a declarative, hardware-agnostic provisioning and benchmarking engine designed to converge, profile, and orchestrate **Out-of-Order (`OoO`) vs. In-Order (`InO`) [RISC-V](https://riscv.org/) silicon** across high-throughput relational data brokering and heterogeneous Edge ML workloads.

Rather than coupling provisioning logic to hardcoded hostnames or fixed disk topologies, `BrakerRak` operates as a **Two-Axis State Machine (`Targets` × `Roles`)** paired with [RVDK (riscv-data-kit)](https://github.com/drewv-labs/riscv-data-kit) and [CarrierPigeons](https://github.com/drewv-labs/carrierpigeons):

* **Native Silicon & Storage Alignment:** Hardware-formats NVMe namespaces to native **`4096B` (`4Kn`)** LBA sectors, provisions LVM (`85%VG` with instant rollback snapshot reserve) + XFS, pins **`2MB` `Sv39` HugePages**, and compiles **PostgreSQL 18.6** from source (`-O3` with silicon-specific ISA extensions and `liburing`). You read that right, PostgreSQL running `io_uring` tapping into the latest Linux concurrency features on bare-metal RISC-V silicon.  

* **Declarative Role Personas (`databroker` vs. `databench`):** Toggles any supported RISC-V board between a full **`BrakerBox` (`databroker`)** relational/messaging/NFS hub and an isolated **`BrakerBench` (`databench`)** microarchitectural testbed via `~/.brakerrak/node.env` or `--role`.  

* **Stateless & Agnostic by Default:** Runs out-of-the-box on single-NVMe boards (`WITH_RAID="false"`), while supporting arbitrary multi-enclosure USB/SATA RAID 10 topologies (`mdadm` XFS or native kernel Btrfs RAID 10 `zstd:1`) defined via an iterable `RAID_ARRAYS_JSON` manifest in `~/.brakerrak/node.env`.

---

## Two-Axis Architecture: `Targets` × `Roles`

### 1. Role Personas (`roles/`)

| Role Persona | Node Designation | PostgreSQL 18 (`io_uring`) | Mosquitto MQTT (`:1883`) | NFSv4 Vault Server | `CarrierPigeons` Daemons |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`databroker`** | `brakerbox-<tag>` | Active + Custom Warm/Cold Tablespaces | Enabled (Persisted on `4Kn` NVMe) | Exports RAID Vaults (or `/mnt/nvme_pgdata/nfs_vault` if `WITH_RAID=false`) | `PigeonCoop` + `Pigeoneer` |
| **`databench`** | `brakerbench-<tag>` | Active (Locked Planner Cost Constants) | Disabled for Benchmark Isolation | Disabled for Benchmark Isolation | `Pigeoneer` Only |

### 2. Silicon Targets (`targets/`)

| Target Directory | SoC / Board | Core Complex & Pipeline | ISA Profile & Compiler Flags | Status |
| :--- | :--- | :--- | :--- | :--- |
| **`targets/sifive-p550`** | ESWIN EIC7700X (HiFive Premier P550) | `4x SiFive P550` (`3-Wide OoO @ 1.4GHz`) | `RVA20` (`-O3 -march=rv64gc_zba_zbb -mcpu=sifive-p550`) | **Active / Verified** |
| **`targets/starfive-jh7110`** | StarFive JH7110 (VisionFive 2) | `4x SiFive U74` (`2-Wide InO @ 1.5GHz`) | `RVA20` (`-O3 -march=rv64gc -mcpu=sifive-u74`) | **Active / In Progress** |
| `targets/spacemit-k1` | SpacemiT K1/M1 (Milk-V Jupiter 1) | `8x X60` (`2-Wide InO @ 1.8GHz`) | `RVA22` + `256-bit RVV 1.0` | Planned |
| `targets/spacemit-k3` | SpacemiT K3 (Milk-V Jupiter 2) | `8x X100` (`4-Wide OoO @ 2.4GHz` + `60 TOPS`) | `RVA23` + `1024-bit RVV 1.0` | Planned |
| `targets/ultrarisc-dp1000` | UltraRISC UR-DP1000 (Milk-V Titan) | `8x UR-CP100` (`4-Wide OoO @ 2.0GHz`) | `RVA22` + `H-Ext 1.0` | Planned |

---

## Repository Structure

All user-specific configuration (`~/.brakerrak/node.env`) and generated hardware provenance manifests (`~/.brakerrak/snapshots/`) live outside the repository tree so the engine remains stateless:

```text
brakerrak/
├── README.md
├── forge.sh                             # Universal curl-to-forge auto-dispatcher & local CLI entrypoint
├── roles/
│   ├── databroker.env                   # BrakerBox persona: PG18 + Mosquitto + NFSv4 + PigeonCoop
│   └── databench.env                    # BrakerBench persona: Locked PG18 planner + Pigeoneer only
├── targets/
│   ├── sifive-p550/                     # HiFive Premier P550 (ESWIN EIC7700X, RVA20 + Zba/Zbb)
│   │   ├── forge.sh                     # Stage 1 & 2: Two-Pass idempotent convergence script
│   │   ├── ort-snapshot.py              # Stage 0 & 3: Zero-dependency ORT & CTD manifest generator
│   │   ├── reset-day0.sh                # Option A: In-place 512e NVMe & OS factory rollback
│   │   └── verify-convergence.sh        # One-shot 5-stage validation & idempotency harness
│   └── starfive-jh7110/                 # VisionFive 2 (StarFive JH7110, SiFive U74)
└── examples/
    ├── databroker-raid.env.example      # Reference multi-array databroker configuration
    └── databench.env.example            # Reference isolated databench configuration
```

---

## Zero-Touch Quickstart (`curl | sudo bash` & `brakerrak` CLI)

### 1. Remote One-Liner Bootstrap

`BrakerRak`'s root `forge.sh` inspects `/proc/device-tree/model` to auto-detect the underlying RISC-V board, syncs the framework into `~/.brakerrak/engine`, installs the `/usr/local/bin/brakerrak` CLI symlink, and executes the target convergence pipeline:

```bash
# Converge node as an isolated benchmark target (default Pass 1 behavior: databench, NVMe-only)
curl -fsSL https://brakerrak.dev/forge.sh | sudo bash

# Converge node directly as a production DataBroker (PG18 + Mosquitto MQTT + NFSv4)
curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databroker
```

### 2. Local `/usr/local/bin/brakerrak` CLI Usage

Once bootstrapped, invoke `brakerrak` directly to toggle roles, capture CTD provenance snapshots, run the 5-stage idempotency harness, or roll the node back to factory Day-0 state:

```bash
# Re-converge node using ~/.brakerrak/node.env (Pass 2) or toggle role persona
sudo brakerrak
sudo brakerrak --role databench
sudo brakerrak --role databroker

# Capture a read-only Operational Readiness Test (ORT) & signed CTD snapshot in ~/.brakerrak/snapshots/
sudo brakerrak ort --stage day1-post-forge

# Execute the full 5-stage Day-0 -> Day-1 convergence & idempotency verification harness
sudo brakerrak verify --use-pkg-cache

# Roll back NVMe to factory 512e (512B) LBA sectors and scrub OS/PG18 state (preserving compiled .debs)
sudo brakerrak reset --confirm-destroy --keep-pg-cache
```

---

## Declarative Node Configuration (`~/.brakerrak/node.env`)

On its first run (**Pass 1**), `forge.sh` converges the core OS, `4Kn` NVMe, and PostgreSQL 18 cluster using safe hardware-agnostic defaults (`WITH_RAID="false"`) and emits a template at `~/.brakerrak/node.env`.

To attach external USB/SATA RAID 10 pools or customize network services for **Pass 2**, populate `RAID_ARRAYS_JSON` in `~/.brakerrak/node.env` and re-run `sudo brakerrak`:

```bash
NODE_ROLE="databroker"
TARGET_HOSTNAME="brakerbox-p550"
ADMIN_USER="ubuntu"
LAB_SUBNET="10.0.10.0/24"

NVME_DEV="/dev/nvme0n1"
MOUNT_POINT="/mnt/nvme_pgdata"

WITH_RAID="true"
RAID_ARRAYS_JSON='[
  {
    "name": "WarmVault",
    "id": "warmvault",
    "type": "warm",
    "label": "WARM_VAULT",
    "mount": "/mnt/warm_vault",
    "md_dev": "/dev/md/warmvault",
    "disks": 4,
    "min_bytes": 11000000000000,
    "max_bytes": 13000000000000,
    "tablespace": "ts_warm_vault",
    "nfs_fsid": 10,
    "nfs_dirs": ["models", "sigmf", "fits", "pg_backups", "ctd-vault"]
  }
]'

ENABLE_MQTT_BROKER="true"
MQTT_PORT="1883"
ENABLE_NFS_SERVER="true"
```

When `WITH_RAID="true"`, `BrakerRak` dynamically iterates through `RAID_ARRAYS_JSON` to:
1. Match rotational candidate disks by byte-capacity bounds and assemble 4-drive RAID 10 volumes (`mdadm` + XFS or native kernel Btrfs RAID 10 `zstd:1`).
2. Mount each array with `nofail` protection in `/etc/fstab` and register its corresponding PostgreSQL tablespace (`ts_warm_vault`, etc.).
3. Scaffold shared directories (`nfs_dirs`) and export each tier over NFSv4 (`fsid`), or automatically fall back to exporting `${MOUNT_POINT}/nfs_vault` on the NVMe when `WITH_RAID="false"`.
4. Assert disk enumeration and mount health inside `ort-snapshot.py` while scrubbing physical drive serials to `"REDACTED"` in the companion `.public.json` manifest.

---

## Deterministic 5-Stage Lifecycle State Machine

1. **Stage 0A — Day-0 OS & Silicon Bootstrap (`RVDK`):** Strips desktop GUI/snap bloat, masks sleep/suspend targets, protects vendor U-Boot/DTB hooks, and unlocks hardware PMU counters (`kernel.perf_event_paranoid = -1`).
2. **Stage 0B — Clean-Room ORT Baseline (`brakerrak ort --stage day0-pre-forge`):** Captures a zero-mutation JSON snapshot of factory PCIe link speeds, `512e` NVMe LBA formatting, rotational JBOD enumeration, and quiescent thermal/clock baselines.
3. **Stage 1 — Cold Convergence Forge (`brakerrak forge`):** Reformats NVMe storage to native `4096B` (`4Kn`) sectors, provisions LVM + XFS and any configured `RAID_ARRAYS_JSON` pools, reserves `2MB` `Sv39` HugePages, compiles PostgreSQL 18.6 from source under `perf stat`, and converges role-specific `mosquitto` / `nfs-kernel-server` services.
4. **Stage 2 — Idempotency Verification Pass (`brakerrak forge`):** Re-executes the forge against the live node, asserting `100% [SKIP]` across all stages in ~2 seconds with zero service restarts or destructive storage mutations.
5. **Stage 3 — Post-Forge CTD Provenance (`brakerrak ort --stage day1-post-forge`):** Emits a SHA-256 signed JSON manifest (`.json` + redacted `.public.json`) to `~/.brakerrak/snapshots/` verifying `4Kn` block alignment, active `io_uring` backend configuration, HugePage consumption, and tablespace/NFS routing.


---

<div align="center">

**DREW-V LABS** // **Drew Vandagriff** — *Dallas, TX*  
`Simplicity in Architecture · Efficiency in Engineering · Purity in Science · Audacity in Art · Life in Logic`

</div>
