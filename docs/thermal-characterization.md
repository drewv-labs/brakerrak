# BrakerRak Thermal Characterization Baseline

- **Campaign ID:** `drewvlabs-brakerrak-8fan-nafc1-characterization`
- **Timestamp (UTC):** `2026-11-03T22:15:34Z`
- **Ambient Baseline:** `21.0°C`
- **Cooling Fabric:** Noctua `NA-FC1` PWM Controller driving `8x 40mm` fans (`5x` on `U02` 1U vented shelf spacer + `3x` inside `U03` SilverStone `SST-RM100` 1U chassis)
- **Workload:** 600-second 4-hart `blake2b` + `128 MB` (`32 MB/hart`) LPDDR4/LPDDR5 cache-thrash soak
- **SHA-256 Digest:** `c4e97238a4dca9a40aba1fd460ccb9eca40066f00f33301a433a66f1d6bb31f9`

| Node (Sensor) | Quiescent Idle | 0% Mean / Peak | 50% Mean / Peak | 100% Mean / Peak |
| :--- | :--- | :--- | :--- | :--- |
| **BrakerBox-P550 (pvt)** | 42.92°C to 37.00°C | 48.69°C / 50.80°C | 47.62°C / 48.13°C | 42.16°C / 42.92°C |
| **BrakerBox-P550 (nvme)** | 30.85°C | 32.70°C / 32.85°C | 32.85°C / 32.85°C | 32.85°C / 32.85°C |
| **BrakerBench-VF2 (sfctemp)** | 37.71°C to 34.00°C | 47.76°C / 51.28°C | 44.00°C / 44.38°C | 41.33°C / 41.83°C |
| **VisionFerret-H8 (sfctemp)** | 34.17°C to 30.00°C | 43.40°C / 46.58°C | 40.55°C / 40.90°C | 38.00°C / 38.00°C |
| **RakWrt-R6S (soc)** | 36.00°C (Passive) | N/A | N/A | N/A |
