<div align="center">

# BrakerRak

**Bare-Metal RISC-V Data Engineering & Edge ML Research Rack: PostgreSQL 18 `io_uring` Data Brokers, `4Kn` NVMe + Btrfs RAID 10 Storage Tiers, and Continuous Telemetric Documentation (CTD).**

</div>

---

`BrakerRak` (named in tribute to database pioneer Michael Stonebraker) is a 15U bare-metal research rack engineered to benchmark, profile, and orchestrate **Out-of-Order (`OoO`) vs. In-Order (`InO`) RISC-V silicon** across high-throughput relational data brokering and heterogeneous Edge ML workloads.

Every node in the rack is provisioned as a deterministic, self-contained state machine—combining **native `4096B` (`4Kn`) NVMe sector formatting**, **`2MB` `Sv39` HugePage pinning**, **source-compiled PostgreSQL 18.6 (`-O3 -march=rv64gc_zba_zbb` with `liburing`)**, **multi-tier Btrfs RAID 10 vaults**, and **cycle-accurate PMU hardware counter telemetry** (`perf stat` + `ort-snapshot.py`).

---

## 15U Rack Elevation Topology

```text
U15 |---------------------------------------------------------------|
U14 |                                                               |
U13 |                       BabbageBox-RTX                          |
U12 |                                                               |
U11 |---------------------------------------------------------------|
U10 [                        VentedSpacer                           ]
U09 [                      ~BrakerBox-Titan                         ]
U08 [                        LilBlu-WDB24                           ]
U07 [                        BigRed-WDR48                           ]
U06 [                     ~BrakerBench-Titan                        ]
U05 [                      ~BrakerBench-J2                          ]
U04 [                      ~BrakerBench-J1                          ]
U03 [                       BrakerBox-P550                          ]
U02 [   LabWrt-R6S  |  VFerret-H8  |  VFerret-H8L  |  BBench-VF2    ]
U01 [                        Sodola Switch                          ]
    -----------------------------------------------------------------
```

## Hardware Node Matrix

| Unit | Node | Silicon | Core Complex | Primary Role |
| :--- | :--- | :--- | :--- | :--- |
| U11–U15 | `BabbageBox-RTX` | Intel i9-9900K | RTX 3090 + 3080 Ti | Tensor Forge & Hailo `.hef` Factory |
| U09 | `~BrakerBox-Titan` | UltraRISC DP1000 | 8x CP100 4-Wide OoO | Target Production Data Broker |
| U07–U08 | `BigRed` / `LilBlu` | 8x WD CMR Arrays | Btrfs RAID 10 | 43.6 TiB Warm + 21.8 TiB Cold Vaults |
| U06 | `~BrakerBench-Titan` | UltraRISC DP1000 | 8x CP100 4-Wide OoO | PCIe Gen4 x4 NVMe & KVM Benchmark |
| U05 | `~BrakerBench-J2` | SpacemiT K3 | 8x X100 4-Wide OoO | RVA23 + 1024-bit RVV 1.0 + 60 TOPS |
| U04 | `~BrakerBench-J1` | SpacemiT M1 | 8x X60 2-Wide InO | RVA22 + 256-bit RVV 1.0 Benchmark |
| U03 | `BrakerBench-P550` | ESWIN EIC7700X | 4x P550 3-Wide OoO | Active PG 18.6 `io_uring` Broker |
| U02 | `BrakerBench-VF2` | StarFive JH7110 | 4x U74 2-Wide InO | In-Order Scalar Baseline Control |
| U02 | `VisionFerret-H8` | JH7110 + Hailo-8 | 4x U74 + 26 TOPS | Full-SRAM Single-Context NPU Twin |
| U02 | `VisionFerret-H8L` | JH7110 + Hailo-8L | 4x U74 + 13 TOPS | Multi-Context DMA Spill NPU Twin |
| U01–U02 | `LabWrt` / `Switch` | RK3588S + Sodola | 2.5GbE / 10GbE SFP+ | `10.0.10.0/24` L2/L3 Lab Fabric |

*(Nodes prefixed with `~` denote backordered/planned expansion slots.)*

## Repository Structure

Each node directory operates as a blast-radius-isolated sandbox containing its own convergence script (`forge.sh`), read-only Continuous Telemetric Documentation (CTD) inspector (`ort-snapshot.py`), factory teardown harness (`reset-day0.sh`), and signed JSON provenance manifests (`snapshots/`):

```text
brakerrak/
├── README.md
└── nodes/
    ├── databrokers/
    │   ├── brakerbox-p550/
    │   │   ├── README.md
    │   │   ├── forge.sh                  # Stage 1 & 2: Idempotent convergence forge
    │   │   ├── ort-snapshot.py           # Stage 0 & 3: Zero-dependency ORT & CTD manifest generator
    │   │   ├── reset-day0.sh             # Option A: In-place 512e NVMe & OS factory rollback
    │   │   ├── verify-convergence.sh     # One-shot 5-stage validation & idempotency harness
    │   │   ├── benchmarks/               # PostgreSQL 18.6 io_uring + O_DIRECT torture suite
    │   │   └── snapshots/                # SHA-256 signed Day-0 and Day-1 CTD JSON artifacts
    │   └── brakerbox-titan/
    ├── databench/
    │   ├── brakerbench-j1/
    │   ├── brakerbench-j2/
    │   ├── brakerbench-p550/
    │   ├── brakerbench-titan/
    │   └── brakerbench-vf2/
    └── npubench/
        ├── visionferret-h8/
        └── visionferret-h8l/
```

## Deterministic 5-Stage Lifecycle State Machine

`BrakerRak` treats bare-metal infrastructure as a verifiable state machine paired with [`riscv-data-kit`](https://github.com/drewv-labs/riscv-data-kit) as a sibling repository:

1. **Stage 0A — Day-0 OS & Silicon Bootstrap (`riscv-data-kit`):** Strips desktop GUI/snap bloat, applies `CVE-2026-98432` raw `nftables` prerouting and MPTCP kernel guards, protects vendor U-Boot/DTB hooks, and unlocks hardware PMU counters (`kernel.perf_event_paranoid = -1`).
2. **Stage 0B — Clean-Room ORT Baseline (`ort-snapshot.py --stage day0-pre-forge`):** Captures a zero-mutation JSON snapshot of factory PCIe link speeds, `512e` NVMe LBA formatting, USB JBOD enumeration, and quiescent thermal/power baselines.
3. **Stage 1 — Cold Convergence Forge (`forge.sh`):** Reformats NVMe storage to native `4096B` (`4Kn`) sectors, provisions LVM + XFS (`HOT_NVME`) and native Btrfs RAID 10 (`zstd:1`) arrays (`WARM_VAULT` & `COLD_ARCH`), allocates `2MB` `Sv39` HugePages, and compiles PostgreSQL 18.6 from source with `-O3 -march=rv64gc_zba_zbb` and `liburing`.
4. **Stage 2 — Idempotency Verification Pass (`forge.sh`):** Re-executes the forge against the live node, asserting `100% [SKIP]` across all stages with zero service restarts or destructive storage mutations.
5. **Stage 3 — Post-Forge CTD Provenance (`ort-snapshot.py --stage day1-post-forge`):** Emits a SHA-256 signed JSON manifest proving `4Kn` block alignment, active `io_uring` backend configuration, HugePage reservation, and 3-tier tablespace routing.

## Quickstart: `BrakerBox-P550` End-to-End Verification

Assuming `brakerrak` and `riscv-data-kit` are checked out under `~/repo/[github.com/drewv-labs/](https://github.com/drewv-labs/)` (if `riscv-data-kit` is absent, `verify-convergence.sh` clones it automatically):

```bash
cd ~/repo/github.com/drewv-labs/brakerrak/nodes/databrokers/brakerbox-p550

# 1. Optional: Roll back a converged node to factory 512e NVMe & clean OS state
sudo ./reset-day0.sh --confirm-destroy

# 2. Execute the 5-stage Day-0 -> Day-1 convergence & idempotency verification harness
# (Pass --use-pkg-cache for fast iteration, or omit for a full perf stat source build)
sudo ./verify-convergence.sh --use-pkg-cache
```

## PostgreSQL 18.6 `io_uring` Benchmark Highlights (`BrakerBox-P550`)

Evaluated on a 50-million-row (`11 GB`, `1,351,353` pages) dataset stored on a `4Kn`-formatted `WD_BLACK SN850X` (`PCIe Gen3 x4`) across `4x SiFive P550` Out-of-Order cores (`32GB LPDDR5`, `shared_buffers = 8GB` in `2MB Sv39` HugePages) after cold-cache drop (`drop_caches = 3`):

| Workload & Metric | `sync` | `worker` | `io_uring` | `io_uring` + `O_DIRECT` |
| :--- | :--- | :--- | :--- | :--- |
| **Seq Scan Wall Time** | 15022 ms | 12776 ms | 13174 ms | — |
| **Seq Scan Backend I/O Wait** | 4017 ms | 112 ms | 32 ms | — |
| **Bitmap Scan Wall Time** | 54698 ms | 28530 ms | 35011 ms | 62482 ms |
| **Bitmap Scan Context Switches** | 24854 | 611038 | 508370 | 32189 |
| **Bitmap Scan L1d Cache Misses** | 4.75 B | 4.97 B | 4.93 B | 3.03 B |

Reproduce the full hardware-counter benchmark suite using the scripts under `nodes/databrokers/brakerbox-p550/benchmarks/`:

```bash
cd ~/repo/github.com/drewv-labs/brakerrak/nodes/databrokers/brakerbox-p550/benchmarks
sudo ./create-io-torture-table.sh
sudo ./run-iouring-showdown.sh
```

---

<div align="center">

**DREW-V LABS** // **Drew Vandagriff** — *Dallas, TX*  
`Simplicity in Architecture · Efficiency in Engineering · Purity in Science · Audacity in Art · Life in Logic`

</div>
