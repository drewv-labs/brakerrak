# BrakerRak Thermal Characterization Baseline

- **Campaign ID:** `brakerrak-8fan-nafc1-characterization`
- **Timestamp (UTC):** `2026-11-03T22:15:34Z`
- **Ambient Baseline:** `21.0°C`
- **Cooling Fabric:** Noctua `NA-FC1` PWM Controller driving `8x 40mm` fans (`5x` on `Slot-A` 1U vented shelf spacer + `3x` inside `Slot-B` SilverStone `SST-RM100` 1U chassis)
- **Workload:** 600-second 4-hart `blake2b` + `128 MB` (`32 MB/hart`) LPDDR4/LPDDR5 cache-thrash soak
- **SHA-256 Digest:** `1ccd2c9fc311fad8974a444ffac75fdc03d4c5085a615206f038f2195e556b26`

| Node (Sensor) | Quiescent Idle | 0% Mean / Peak | 50% Mean / Peak | 100% Mean / Peak |
| :--- | :--- | :--- | :--- | :--- |
| **BrakerBox-P550 (pvt)** | 42.92°C to 37.00°C | 48.69°C / 50.80°C | 47.62°C / 48.13°C | 42.16°C / 42.92°C |
| **BrakerBox-P550 (nvme)** | 30.85°C | 32.70°C / 32.85°C | 32.85°C / 32.85°C | 32.85°C / 32.85°C |
| **BrakerBench-VF2 (sfctemp)** | 37.71°C to 34.00°C | 47.76°C / 51.28°C | 44.00°C / 44.38°C | 41.33°C / 41.83°C |
| **Vision-Node (sfctemp)** | 34.17°C to 30.00°C | 43.40°C / 46.58°C | 40.55°C / 40.90°C | 38.00°C / 38.00°C |
| **Edge-Router (soc)** | 36.00°C (Passive) | N/A | N/A | N/A |

## Methodology Caveats

- **Sequential Sweep Thermal Carryover (`pwm_50_pct`):** The `0%`, `50%`, and `100%` PWM soak stages were executed sequentially without waiting for sensors to return to `quiescent_idle_min_c` between runs. Consequently, `pwm_50_pct` starts from an elevated thermal baseline (`idle_c`: `44.97°C` vs `42.92°C` at `0%` / `37.00°C` quiescent on `BrakerBox-P550 pvt`; `32.85°C` carried into `50%` and `100%` on `BrakerBox-P550 nvme`; `38.06°C` vs `37.71°C` on `BrakerBench-VF2`; `34.75°C` vs `34.17°C` on `Vision-Node`), understating steady-state cooling delta relative to cold-start `0%` sweeps.
- **Schema Scope (`ctd.thermal.v1`):** The signed [`artifacts/ctd-thermal-soak-baseline.json`](../artifacts/ctd-thermal-soak-baseline.json) capture records aggregate `idle_c`, `mean_c`, `peak_c`, and `rise_over_ambient_c` scalars only; it omits per-sample clock/frequency telemetry (`cpufreq` / thermal throttle indicators) and distribution percentiles (`p50` / `p95` / `p99` / `stddev`). The JSON artifact is preserved unmodified to retain its SHA-256 provenance digest.
