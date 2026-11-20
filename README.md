<div align="center">

  <img src="./.github/images/brakerrak-banner.png" alt="BrakerRak Banner" width="80%"/>

  > ‼ Please note that this project is in active development.

</div>

BrakerRak combines [RVDK (riscv-data-kit)](https://github.com/drewv-labs/rvdk) and [CarrierPigeons](https://github.com/drewv-labs/carrierpigeons) into powerful RISC-V data systems & ML engineering R&D platform.


Named in tribute to database pioneer [Michael Stonebraker](https://en.wikipedia.org/wiki/Michael_Stonebraker), BrakerRak is a framework for .

<div align="center">

<img src="./docs/assets/brakerrak-term-psql-install.png" alt="BrakerBox-P550" width="600"/>

*Idempotent bootstrapping and module management via `RVDK`*

</div>

<div align="center">

## Ecosystem Layering: `RVDK` vs. `BrakerRak`

</div>

<!-- TODO: Swap the CTD link below to the dedicated CTD architecture writeup URL once published -->
While **[RVDK](https://github.com/drewv-labs/brakerrak)** supplies the atomic provisioning primitives and prebuilt binary catalog, **[BrakerRak](https://github.com/drewv-labs/brakerrak)** builds on top of **RVDK** as a stateful execution harness—pairing declarative node personas with "**HamStak**" **[CarrierPigeons](https://github.com/drewv-labs/carrierpigeons)**-powered **[Continuous Telemetric Documentation (CTD)](https://github.com/drewv-labs/carrierpigeons)** mesh for a streamlined, plug-and-play RISC-V R&D platform.

> **Choosing Between `RVDK` and `BrakerRak`:**
> * **Use [RVDK](https://github.com/drewv-labs/brakerrak) standalone** if you want clean, unopinionated building blocks—plugging Day-0 OS de-bloating, safe vendor DTB/U-Boot upgrades, `deeptune` kernel tuning, `4Kn` NVMe formatting, or prebuilt `io_uring` PostgreSQL 18.6 directly into your own scripts, Ansible playbooks, or CI pipelines without adopting an external stack.

> * **Use [`BrakerRak`](https://github.com/drewv-labs/brakerrak) (`brakerrak`)** if you want the full turnkey R&D harness—adding `Targets × Roles` state convergence, signed ORT/CTD hardware provenance manifests, Day-0 destructive factory rollback, benchmark showdowns, and live **HamStak** telemetry orchestration & distributed mesh execution via unified TUI.

---

<div align="center">

## Two-Axis Architecture: `Targets` × `Roles`

</div>

### 1. Role Personas (`roles/` & `node.env`)

Flip any supported RISC-V node statelessly between production data brokering, discrete GPU/Blackhole AI compute, Edge NPU inference, isolated microarchitectural benchmarking, or hybrid development via `brakerrak --role <persona> --deeptune`:

| Role (`--role`) | Persona (`Short` / `LilSnitch` Tag) | Default Hostname | `RVDK` DeepTune | PostgreSQL 18.6 (`io_uring`) | Mosquitto MQTT (`:1883`) | NFSv4 Vault Server (`ganesha` / `kernel`) | Desc |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`databroker`** | **`BrakerBox`** (`BrakBox` / `brx`) | `brakerbox-<board>` | `--tune data` | Active + Warm/Cold RAID Tablespaces | Enabled (Persisted on `4Kn` NVMe) | Exports RAID Vaults (or Dedicated `lv_nfsvault` Btrfs LV when `WITH_RAID=false`) | Prod Data Broker & NFS Host |
| **`databench`** | **`BrakerBench`** (`BrakBnch` / `brh`) | `brakerbench-<board>` | `--tune data` | Active (Isolated Benchmark Target) | Disabled for Benchmark Isolation | Disabled for Benchmark Isolation | Dev Data Bench |
| **`babbagebox`** | **`BabbageBox`** (`BabBox` / `bab`) | `babbagebox-<board>` | `--tune ai` | Disabled by Default (`--with-pg` opt-in; frees RAM/HugePages for Blackhole/GPU) | Disabled | Disabled | Prod GPU / Blackhole Workhorse + `PigCan` |
| **`babbagebench`** | **`BabbageBench`** (`BabBnch` / `bah`) | `babbagebench-<board>` | `--tune ai` | Disabled by Default (`--with-pg` opt-in; pure GPU/Blackhole isolation) | Disabled for Benchmark Isolation | Disabled for Benchmark Isolation | Dev Isolated GPU / Blackhole Bench |
| **`visionbox`** | **`VisionBox`** (`VisBox` / `vx`) | `visionbox-<board>` | `--tune ai` | Disabled by Default (`--with-pg` opt-in; full Edge NPU memory headroom) | Disabled | Disabled | Prod Edge NPU Inference Node |
| **`visionbench`** | **`VisionBench`** (`VisBnch` / `vh`) | `visionbench-<board>` | `--tune ai` | Disabled by Default (`--with-pg` opt-in; pure Edge NPU isolation) | Disabled for Benchmark Isolation | Disabled for Benchmark Isolation | Dev Isolated Edge NPU Bench |
| **`devbench`** | **`DevBench`** (`DevBnch` / `dev`) | `devbench-<board>` | `--tune ai` | Active (Hybrid GPU/NPU + Data Bench) | Enabled (`:1883` + Unix Socket) | Disabled by Default | Dev Hybrid Bench (Hot-Swappable Roles & Tunes) |


### 2. Silicon Targets (`soc-drawer/`)

| SoC / Board | Core Complex & Pipeline | ISA Profile & Compiler Flags | Status |
| :--- | :--- | :--- | :--- |
| ESWIN EIC7700X (HiFive Premier P550 / Milk-V Megrez) | `4x SiFive P550` (`3-Wide OoO @ 1.4–1.8GHz`) | `RVA20` (`-O3 -march=rv64gc_zba_zbb -mcpu=sifive-p550`) | **Active / Verified** |
| StarFive JH7110 / JH7110S (VF2 / VF2 Lite / Mars / OPi RV) | `4x SiFive U74` (`2-Wide InO @ 1.25–1.5GHz`) | `RVA20` (`-O3 -march=rv64gc -mcpu=sifive-u74`) | **Active / Verified** |
| SpacemiT K1/M1 (OPi RV2 / OPi R2S / Jupiter / BPI-F3 / CM6) | `8x SpacemiT X60` (`2-Wide InO @ 1.6–1.8GHz`) | `RVA22` + `256-bit RVV 1.0` | **Active / Bring-Up** |
| UltraRISC UR-DP1000 (Milk-V Titan) | `8x UR-CP100` (`4-Wide OoO @ 2.0GHz` + `PCIe Gen4 x16`) | `RVA22` + `H-Ext 1.0` | **Active / Bring-Up** |
| SpacemiT K3 (Milk-V Jupiter 2 / Firefly AIBOX-K3) | `8x SpacemiT X100` (`4-Wide OoO @ 2.4GHz` + `60 TOPS`) | `RVA23` + `1024-bit RVV 1.0` | Planned |
| SiFive Freedom U740 (HiFive Unmatched Rev B) | `4x SiFive U74` (`2-Wide InO @ 1.2GHz` + `PCIe Gen3 x8`) | `RVA20` (`RV64GC`) | Planned |
| Tenstorrent Atlantis | `8x Tenstorrent Ascalon-X` (`Wide OoO` + `PCIe Gen5`) | `RVA23` + `256-bit RVV 1.0` | Planned |

---

<div align="center">

<img src="./docs/assets/sifive-hifive-premier-p550-sn850x-server-layout.png" alt="BrakerBox-P550" width="500"/>

*HiFive Premier P550 [BrakerBox-P550 Setup](https://github.com/drewv-labs/brakerrak/blob/main/docs/builds/brakerbox-p550.md)*

</div>

---

<div align="center">

## Quickstart (`curl | sudo bash` & `brakerrak` CLI)

</div>

### 1. Remote One-Liner Convergence

`BrakerRak`'s root `forge.sh` reads `/etc/rvdk/kit.env` (or probes `/proc/device-tree/model`), installs/updates `/usr/local/bin/brakerrak` and `/usr/local/bin/rvdk`, generates `~/.brakerrak/node.env` on Pass 1, and orchestrates the full `RVDK` convergence pipeline (formatting secondary NVMe to `4Kn` with `vg_braker` LVM, converging role-gated PostgreSQL 18.6 / MQTT / NFSv4 services, and applying workload-matched `rvdk deeptune`):

```bash
# Install the brakerrak CLI & engine without running the convergence forge
curl -fsSL https://brakerrak.dev/install-cli.sh | sudo bash

# Converge node as a BrakerBox DataBroker (default Pass 1 role: databroker, NVMe-only)
curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databroker --deeptune

# Converge node as an isolated BrakerBench testbed, BabbageBox GPU workhorse, or hybrid DevBench
curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databench --deeptune
curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role babbagebox --deeptune
curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role devbench --deeptune
```

### 2. Local `/usr/local/bin/brakerrak` Lifecycle & Stateless Persona Flipping

Once bootstrapped, use `brakerrak` CLI to flip node personas statelessly (e.g., staging a `DevBench-TitanP150A` / `BabbageBench-TitanP150A` bench and flipping it into `BabbageBox-TitanP150A` production), manage live Dual-LVM storage elasticity, apply role-mapped `RVDK` DeepTune profiles, capture signed ORT/CTD hardware snapshots, verify idempotency, run showdowns, or roll back to factory Day-0 state:

```bash
# Re-converge node from ~/.brakerrak/node.env (Pass 2) or flip node persona on the fly
brakerrak
brakerrak --role devbench --deeptune
brakerrak --role babbagebench --deeptune
brakerrak --role babbagebox --deeptune
brakerrak --role visionbench --deeptune
brakerrak --role databench --deeptune
brakerrak --role databroker --with-tailscale --ts-ssh

# Apply or inspect role-aware RVDK DeepTune (`databroker`/`databench` -> data, `babbage*`/`vision*`/`devbench` -> ai)
brakerrak deeptune
brakerrak deeptune status

# Inspect or rebalance live vg_braker Dual-LVM extents online (`lv_pgdata` XFS + `lv_nfsvault` Btrfs)
brakerrak storage status
brakerrak storage grow-psql --gb 100
brakerrak storage grow-nfs --mb 500
brakerrak storage autotune

# Capture a read-only Operational Readiness Test (ORT) & SHA-256 CTD snapshot in ~/.brakerrak/snapshots/
brakerrak ort --stage day1-post-forge

# Execute the full 5-stage Day-0 -> Day-1 convergence & idempotency verification harness
brakerrak verify --use-pkg-cache

# Seed the 50M-row torture table & run the cold-cache PG 18.6 sync vs worker vs io_uring showdown
~/.brakerrak/engine/benchmarks/seed-io-torture.sh
~/.brakerrak/engine/benchmarks/run-iouring-showdown.sh

# Roll back NVMe to factory 512e (512B) LBA sectors and scrub PG18/service state (preserving .deb cache)
brakerrak reset --confirm-destroy --keep-pg-cache

# Pull latest RVDK + BrakerRak engines from GitHub
brakerrak update
```

---

<div align="center">

## Declarative Node Configuration (`~/.brakerrak/node.env`)

</div>

On **Pass 1**, `forge.sh` converges the core OS, `4Kn` NVMe (`vg_braker/lv_pgdata` + `vg_braker/lv_nfsvault` on single-NVMe NFS builds), and role-selected services using safe single-NVMe defaults (`WITH_RAID="false"`) and writes `~/.brakerrak/node.env`.

To attach external USB/SATA Btrfs RAID 10 vaults or customize network exports for **Pass 2**, populate `RAID_ARRAYS_JSON` in `~/.brakerrak/node.env` and re-run `sudo brakerrak`:

```bash
NODE_ROLE="databroker"
TARGET_HOSTNAME="brakerbox-p550"
ADMIN_USER="drew"
LAB_SUBNET="10.0.10.0/24"
RVDK_TUNE_PROFILE="data"

NVME_DEV="/dev/nvme0n1"
MOUNT_POINT="/mnt/nvme_pgdata"
NFS_MOUNT_POINT="/mnt/nfs_vault"

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

ENABLE_POSTGRES="true"
ENABLE_MQTT_BROKER="true"
MQTT_PORT="1883"
ENABLE_NFS_SERVER="true"
NFS_BACKEND="ganesha"
```

When `WITH_RAID="true"`, `BrakerRak` passes `RAID_ARRAYS_JSON` into `rvdk mods/btrfs-raid` and `rvdk mods/nfs-vault` to:

1. Match unmounted rotational candidate disks by byte-capacity bounds and assemble native kernel Btrfs RAID 10 volumes (`compress=zstd:3,nofail`).  

2. Register each array's PostgreSQL tablespace (`ts_warm_vault`, etc.) and scaffold shared `nfs_dirs`.  

3. Export vaults over NFSv4 via userspace `nfs-ganesha` (`FSAL_VFS`, safe even on vendor kernels lacking `CONFIG_NFSD`) or kernel `nfsd` (`--nfs-kernel`), falling back to the dedicated `lv_nfsvault` Btrfs LV (`${NFS_MOUNT_POINT}`) when `WITH_RAID="false"`.

4. Assert disk enumeration and mount health inside `ort-snapshot.py` while redacting physical drive serial numbers to `"REDACTED"` in companion `.public.json` manifests.

---

<div align="center">

## Deterministic 5-Stage Lifecycle State Machine (`brakerrak verify`)

</div>

1. **Stage 0 — Clean-Room ORT Baseline (`brakerrak ort --stage day0-pre-forge`):** 

Captures a zero-mutation JSON snapshot of factory PCIe link speeds, `512e` NVMe LBA formatting, rotational JBOD enumeration, and quiescent thermal/clock baselines.
<br>

2. **Stage 1 — Cold Convergence Forge (`brakerrak forge`):**

Dispatches 
* `rvdk day0`
* `rvdk mods/nvme-4kn` (`vg_braker` Dual-LVM or `85%VG`)
* role-gated `rvdk postgresql` (prebuilt `.tar.zst` or `--force-rebuild-pg` cold compile under `perf stat`), 
* optional `rvdk mods`:
  * `mosquitto`
  * `nfs-vault`
  * `btrfs-raid`
  * `rvdk deeptune`
<br>

3. **Stage 2 — Idempotency Verification Pass (`brakerrak forge`):** 

Re-executes the full pipeline against the live node, asserting `100% [SKIP]` across converged stages with zero destructive storage mutations or unnecessary `apt-get update` passes.
<br>

4. **Stage 3 — Post-Forge CTD Provenance (`brakerrak ort --stage day1-post-forge`):** 

Emits a SHA-256 signed JSON manifest (`.json` + redacted `.public.json`) to `~/.brakerrak/snapshots/` verifying `4Kn` block alignment, active `io_uring` backend configuration, `Sv39` HugePage consumption, and tablespace/NFSv4 routing.
<br>

5. **Option A Rollback (`brakerrak reset --confirm-destroy`):** 

Tears down services and LVM volumes, hardware-reformats the NVMe back to factory `512e` (`512B`) LBA sectors, and scrubs Day-1 state for repeatable clean-room testing.

---

<div align="center">

**[DREW-V Labs](https://github.com/drewv-labs)**  // Drew Vandagriff   
`Simplicity in Architecture · Efficiency in Engineering · Purity in Science · Audacity in Art · Life in Logic`

</div>
