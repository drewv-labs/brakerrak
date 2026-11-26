<div align="center">

# DREW-V Labs DevBench-P4

*Waveshare ESP32-P4-WIFI6-DEV-KIT (`riscv32`) Edge Telemetry & AI Bench Build*

</div>

---

## 1. Architectural Overview

[DREW-V Labs](https://github.com/drewv-labs) presents `devbench-p4` as the first **`riscv32` (`nommu`)** edge silicon target integrated into `BrakerRak` and `riscv-data-kit` (`RVDK`). Built around the **Waveshare `ESP32-P4-WIFI6-DEV-KIT`** (`espressif-esp32p4`, target tag `p4`), it anchors two distinct operational classes on a shared microSD-backed microcontroller topology (`TARGET_ARCH="riscv32"`, `STORAGE_MEDIA="sd"`):

1. **Hybrid Development Bench (`--role devbench --target p4`):** Supports both `--tune iot` (low-power tickless telemetry) and `--tune ai` (400 MHz PIE SIMD + PSRAM XIP edge inference). Because `espressif-esp32p4` lacks an MMU and PCIe bus, `forge.sh` automatically clamps `ENABLE_POSTGRES`, `ENABLE_MQTT_BROKER`, `ENABLE_NFS_SERVER`, and `WITH_RAID` to `"false"` with `[SKIP]` diagnostics when defaulted by `--role devbench` (while failing fast if `--with-pg`, `--with-nfs`, `--with-raid`, `--with-mqtt`, or `--with-tailscale` are requested explicitly).
2. **Dedicated Sensor Personas (`--role snitchbench` / `--role lilsnitch`):** Purpose-built `--tune iot` personas (`snitchbench-p4` for isolated dev shelf bring-up, `lilsnitch-p4` for production per-unit environmental telemetry) with all heavy server daemons disabled by design.

Because an RTOS/ESP-IDF `riscv32` target cannot run CPython 3.12 or local Linux `psql`/`nvme` tooling on-device, `BrakerRak` converges `espressif-esp32p4` via **host-staged SD provisioning (`--stage-dir`)** and captures SHA-256 signed ORT/CTD provenance manifests via **host-proxied USB-Serial-JTAG (`303a:1001`)** or staged SD telemetry JSON (`--telemetry-json`).

---

## 2. Hardware BOM (`Waveshare ESP32-P4-WIFI6-DEV-KIT`)

| Subsystem | Specification | Notes |
| :--- | :--- | :--- |
| **Board / SoC** | Waveshare `ESP32-P4-WIFI6-DEV-KIT` (`ESP32-P4NRW32X`) | Canonical SoC slug `espressif-esp32p4`, board tag `p4` |
| **CPU Complex** | 2x ESP32-P4 HP Harts @ up to 400 MHz + 1x LP Hart @ 40 MHz | `rv32imafc_zicsr_zifencei` + PIE AI SIMD extensions (`-mabi=ilp32f`, `nommu`) |
| **On-Package Memory** | 32 MB Hexadeca PSRAM (200 MHz) + 768 KB HP L2MEM + 16 MB NOR Flash | ORT minimum usable PSRAM floor: `>= 28,000 kB` (`ORT-02_PSRAM_CAPACITY`) |
| **Primary Storage** | 32 GB Industrial MicroSD Card (4-Bit SDMMC @ 40 MHz) | MBR + 4 MiB-aligned FAT32 (`RVDK_P4_SD`, 32 KB cluster size) |
| **Wireless Co-Processor** | Onboard `ESP32-C6` over SDIO (`esp-hosted`) | Wi-Fi 6 (`802.11ax`) + BLE 5.3 (`wlan0`), toggleable via `c6-sdio` quirk |
| **Wired Network** | `IP101GRI` 100M RMII Ethernet PHY (`eth0`) | Deterministic wired fallback when `c6-sdio` quirk is disabled |
| **Debug & Host Proxy** | Native USB-Serial-JTAG (`303a:1001`) + USB 2.0 OTG HS | `/dev/ttyACM0` (Linux) or `/dev/cu.usbmodem*` (macOS) for `esptool` & ORT proxy |
| **Rack Placement** | Open Benchtop or Vented 1U/2U Rack Shelf | Host-proxied over USB-Serial-JTAG to an adjacent workstation or `BrakerRak` Linux host |

---

## 3. SD Media Provisioning & Host-Staged Convergence

### A. Provisioning the FAT32 SD Card (`rvdk flash p4 sd`)

Format and scaffold a 32 GB microSD card on a Linux or macOS workstation with a 4 MiB-aligned MBR FAT32 partition labeled `RVDK_P4_SD` (`/config`, `/firmware`, `/models`, `/telemetry`, `/ota`):

```bash
# Preview partition layout and safety interlocks without writing to disk
rvdk flash p4 sd /dev/diskX --tune iot --hostname devbench-p4 --dry-run

# Format removable microSD card and stage initial ESP32-P4 RVDK config/Kconfig fragments
rvdk flash p4 sd /dev/diskX --tune iot --hostname devbench-p4

# CI / offline dry-staging into a local directory (zero block-device writes)
rvdk flash p4 sd --stage-only /tmp/p4-sd-stage --tune iot --hostname devbench-p4
```

### B. Converging `devbench-p4`: `--tune iot` vs `--tune ai`

Mount the provisioned `RVDK_P4_SD` volume on the host (e.g., `/Volumes/RVDK_P4_SD` on macOS or `/mnt/rvdk_p4_sd` on Linux) and run `brakerrak` in host-staged mode (`--stage-dir`). `forge.sh` atomically writes `<stage-dir>/config/node.env`, skips NVMe `4Kn`/LVM/PG18/MQTT/NFS stages cleanly with `[SKIP]`, and dispatches `rvdk bsp/espressif/esp32p4/forge.sh`, `rvdk bsp/espressif/esp32p4/deeptune.sh`, and `rvdk boards/waveshare/esp32-p4-wifi6/deeptune.sh`:

| Setting / Behavior | `--tune iot` (Default for `snitchbench`/`lilsnitch`) | `--tune ai` (Hybrid `devbench-p4` AI/PIE Mode) |
| :--- | :--- | :--- |
| **HP Core Clock & PM** | `360 MHz`, `CONFIG_PM_ENABLE=y`, FreeRTOS tickless idle (`1000 Hz`) | `400 MHz` sustained, `CONFIG_PM_ENABLE=n`, `-O2` perf optimization |
| **PSRAM & L2 Cache** | `200 MHz` PSRAM, BSS in external memory (`CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY=y`) | `200 MHz` PSRAM + `XIP_FROM_PSRAM`, `256 KB` L2 cache (`128B` line), RTC fast heap |
| **SDMMC & Logging** | `40 MHz` SDMMC + FATFS LFN heap, `WARN` log level (minimal flash/serial noise) | `40 MHz` SDMMC + sustained model asset streaming |
| **Peripherals** | `ESP32-C6` Wi-Fi 6 SDIO active; MIPI-CSI/DSI power-gated for minimal thermal floor | `ESP32-C6` SDIO active; MIPI-CSI/DSI enabled for camera/PIE vision pipelines |

```bash
# Converge DevBench-P4 in low-power telemetry mode (--tune iot)
sudo brakerrak --role devbench --target p4 --tune iot --stage-dir /Volumes/RVDK_P4_SD

# Hot-flip DevBench-P4 to sustained 400 MHz PIE SIMD / PSRAM XIP mode (--tune ai)
sudo brakerrak --role devbench --target p4 --tune ai --stage-dir /Volumes/RVDK_P4_SD

# Converge dedicated sensor bench / production sensor kit personas (--tune iot)
sudo brakerrak --role snitchbench --target p4 --deeptune --stage-dir /Volumes/RVDK_P4_SD
sudo brakerrak --role lilsnitch --target p4 --deeptune --stage-dir /Volumes/RVDK_P4_SD

# Verify Pass-2 idempotency ([SKIP] convergence + unchanged staged config digest)
brakerrak verify --target p4 --role devbench --tune iot --stage-dir /Volumes/RVDK_P4_SD
```

---

## 4. Host-Proxied ORT & CTD Provenance Capture (`303a:1001`)

Connect the Waveshare `ESP32-P4-WIFI6-DEV-KIT` to a `BrakerRak` host or workstation via its native **USB-Serial-JTAG** port (`VID:PID 303a:1001`). `brakerrak ort` instantiates `HostProxiedTelemetryProbe` to ingest the compact RTOS telemetry JSON stream (either live over `--serial-port` or from a staged SD file via `--telemetry-json`), evaluate the ESP32-P4 ORT assertion matrix, and write a signed `.json` + redacted `.public.json` CTD manifest to `~/.brakerrak/snapshots/`:

```bash
# Live host-proxied ORT capture over USB-Serial-JTAG (303a:1001)
brakerrak ort --target espressif-esp32p4 --serial-port /dev/ttyACM0 --stage day1-post-forge

# Host-proxied ORT capture from a staged SD telemetry payload (macOS / Linux)
brakerrak ort --target p4 --telemetry-json /Volumes/RVDK_P4_SD/telemetry/ort.json --stage day0-pre-forge
```

### ESP32-P4 ORT Assertion Matrix

| Assertion ID | Scope | Expected / Pass Threshold |
| :--- | :--- | :--- |
| `ORT-01_CPU_HARTS` | HP Core Complex | Exactly `2` ESP32-P4 HP harts online (`rv32imafc_zicsr_zifencei`, `mmu_type = "none"`) |
| `ORT-02_PSRAM_CAPACITY` | On-Package PSRAM | `>= 28,000 kB` usable PSRAM reported (`32 MB` nominal) |
| `ORT-03_SDMMC_STORAGE` | 4-Bit SDMMC Card | SD media present (`>= 4 GiB`); replaces PCIe NVMe link check |
| `ORT-03B_ESP32_C6_SDIO` | Wireless / RMII Link | `ESP32-C6` Wi-Fi 6 SDIO or `IP101GRI` RMII link ready (`WARN` if C6 disabled by quirk while RMII up) |
| `ORT-04_PRIMARY_NIC_*` | Primary Network | `wlan0` / `eth0` carrier UP with global IPv4 lease |
| `ORT-05_THERMAL_IDLE_FLOOR` | Quiescent Thermal | SoC peak temperature `< 65.0 C` |
| `ORT-D1_SD_MOUNT` | Day-1 Storage | SD volume mounted (`vfat` / `fat32` / `ext4` / `littlefs`); skips NVMe `4Kn` / XFS / PG18 / HugePages |

---

## 5. Reference Staged `/config/node.env` (`devbench-p4`)

```bash
# ==============================================================================
# DREW-V Labs // BrakerRak Node Configuration (<stage-dir>/config/node.env)
# ==============================================================================
NODE_ROLE="devbench"
TARGET_HOSTNAME="devbench-p4"
TARGET_ARCH="riscv32"
STORAGE_MEDIA="sd"
ADMIN_USER="ubuntu"
LAB_SUBNET="198.51.100.0/24"
RVDK_TUNE_PROFILE="iot"
PIGEON_ROLE="pigeoneer"

WITH_RAID="false"
RAID_ARRAYS_JSON='[]'

ENABLE_POSTGRES="false"
ENABLE_MQTT_BROKER="false"
MQTT_PORT="1883"
ENABLE_NFS_SERVER="false"
NFS_BACKEND="ganesha"
SHARE_ORT_SNAPSHOT="false"
```

---

<div align="center">

**[DREW-V Labs](https://github.com/drewv-labs)** // Indie Data Systems R&D  
`Simplicity in Architecture · Efficiency in Engineering · Purity in Science · Audacity in Art · Life in Logic`

</div>
