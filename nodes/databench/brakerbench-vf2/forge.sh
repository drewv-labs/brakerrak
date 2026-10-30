#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive VisionFive 2 Control Data Broker Forge Script
# Path: drewv-labs-toolkit/starfive-vf2-databroker/forge/forge-vf2.sh
# Architecture: RVA20 (RV64GC Scalar) | 4x SiFive U74 2-Wide In-Order | 8GB LPDDR4
# Storage: WD_BLACK SN750 NVMe (PCIe Gen2 x1)
#
# Usage:
#   ./forge-vf2.sh                     # Standard idempotent VF2 + SN750 + PG build
#   ./forge-vf2.sh --force-wipe-nvme   # Destructively re-format SN750 & rebuild PG
# ==============================================================================

set -euo pipefail

# --- Configuration Variables ---
TARGET_HOSTNAME="${TARGET_HOSTNAME:-brakerbench-vf2}"
NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
FS_LABEL="PGDATA_NVME"
USE_LVM="${USE_LVM:-true}"          # true = LVM with 15% snapshot reserve; false = raw GPT partition
VG_NAME="vg_ferret"
LV_NAME="lv_pgdata"
PG_VERSION="${PG_VERSION:-18}"

FORCE_WIPE_NVME="false"
for arg in "$@"; do
    case "$arg" in
        --force-wipe-nvme) FORCE_WIPE_NVME="true" ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--force-wipe-nvme]"
            exit 1
            ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# --- Logging Helpers ---
log_step() { printf "\n\033[1;36m=== [%s] %s ===\033[0m\n" "$(date +%H:%M:%S)" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s (already configured)\n" "$1"; }
log_warn() { printf "\033[1;31m[WARN]\033[0m %s\n" "$1"; }

# Ensure script runs as root or via sudo
if [[ $EUID -ne 0 ]]; then
   echo "Re-executing with sudo..."
   exec sudo -E bash "$0" "$@"
fi

# ==============================================================================
# STAGE 0: Hostname, Sleep Masking, SD/eMMC Isolation, Headless Strip & Sysctls
# ==============================================================================
log_step "0. Pregame: Hostname, SD-Card Jitter Isolation, Headless Strip & Sysctls"

# 0.1 Idempotent Hostname Check
CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" != "$TARGET_HOSTNAME" ]]; then
    hostnamectl set-hostname "$TARGET_HOSTNAME"
    if ! grep -q "$TARGET_HOSTNAME" /etc/hosts; then
        sed -i "s/127.0.1.1.*/127.0.1.1\t${TARGET_HOSTNAME}/g" /etc/hosts || true
        grep -q "$TARGET_HOSTNAME" /etc/hosts || echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts
    fi
    log_ok "Hostname set to ${TARGET_HOSTNAME}"
else
    log_skip "Hostname is already ${TARGET_HOSTNAME}"
fi

# 0.2 Idempotent Sleep/Suspend Masking (Prevents JH7110 SoC hangs)
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
NEED_MASK="false"
for tgt in "${SLEEP_TARGETS[@]}"; do
    if [[ "$(systemctl is-enabled "$tgt" 2>/dev/null || true)" != "masked" ]]; then
        NEED_MASK="true"
        break
    fi
done

if [[ "$NEED_MASK" == "true" ]]; then
    systemctl mask "${SLEEP_TARGETS[@]}"
    log_ok "Masked sleep, suspend, hibernate, and hybrid-sleep targets"
else
    log_skip "Sleep/suspend targets already masked"
fi

# 0.3 Install Core Storage & Telemetry Packages (Debian/Ubuntu cross-compatible)
CORE_PKGS=(
    lvm2 xfsprogs parted smartmontools nvme-cli
    sysstat iotop htop jq curl ca-certificates gnupg
    lsb-release git build-essential rsync
)
# Add linux-perf (Debian) or linux-tools-common (Ubuntu) if available in repo
if apt-cache show linux-perf >/dev/null 2>&1; then
    CORE_PKGS+=(linux-perf)
elif apt-cache show linux-tools-common >/dev/null 2>&1; then
    CORE_PKGS+=(linux-tools-common)
fi

MISSING_PKGS=()
for pkg in "${CORE_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    apt-get update -q
    apt-get install "${APT_FLAGS[@]}" "${MISSING_PKGS[@]}"
    log_ok "Installed core packages: ${MISSING_PKGS[*]}"
else
    log_skip "All core VF2 storage & telemetry packages already installed"
fi

# 0.4 Set Default Boot Target to Headless Console
if [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
    systemctl set-default multi-user.target
    log_ok "Boot target set to headless multi-user.target"
else
    log_skip "Boot target is already multi-user.target"
fi

# 0.5 Idempotent Desktop GUI Bloat Purge (StarFive Debian ships XFCE/LightDM by default)
GUI_BLOAT=(
    lightdm gdm3 xfce4* gnome-shell xserver-xorg* xwayland
    desktop-base task-xfce-desktop unattended-upgrades packagekit modemmanager
)
PURGE_LIST=()
for pattern in "${GUI_BLOAT[@]}"; do
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && PURGE_LIST+=("$pkg")
    done < <(dpkg-query -W -f='${Package}\t${Status}\n' "$pattern" 2>/dev/null | awk '/install ok installed/ {print $1}')
done

if [[ ${#PURGE_LIST[@]} -gt 0 ]]; then
    apt-get purge "${APT_FLAGS[@]}" "${PURGE_LIST[@]}"
    apt-get autoremove "${APT_FLAGS[@]}" --purge
    apt-get clean
    log_ok "Purged GUI & background bloat (${#PURGE_LIST[@]} packages removed)"
else
    log_skip "Desktop GUI & background bloat already purged"
fi

# 0.6 Neutralize MicroSD / eMMC OS Write Jitter (Volatile Journald + Disable Swap)
swapoff -a 2>/dev/null || true
if grep -q -E "^[^#].*\sswap\s" /etc/fstab; then
    sed -i '/\sswap\s/s/^/#/' /etc/fstab
    log_ok "Disabled swap in /etc/fstab to protect SD/eMMC and prevent benchmark paging"
else
    log_skip "Swap already disabled in /etc/fstab"
fi

JOURNALD_CONF="/etc/systemd/journald.conf.d/90-volatile-ram.conf"
if [[ ! -f "$JOURNALD_CONF" ]]; then
    mkdir -p /etc/systemd/journald.conf.d
    cat << 'EOF' > "$JOURNALD_CONF"
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF
    systemctl restart systemd-journald
    log_ok "Configured systemd-journald to volatile RAM (0 KB/s SD card write jitter)"
else
    log_skip "systemd-journald volatile RAM logging already configured"
fi

# 0.7 Idempotent Sysctl Configuration (U74 PMU Counters & Memory Writeback)
SYSCTL_FILE="/etc/sysctl.d/90-brakerbench-vf2.conf"
SYSCTL_CONTENT="# Allow non-root perf sampling of SiFive U74 hardware counters
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0

# Broker memory & dirty page writeback tuning (Matched 1:1 with P550)
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15"

if [[ ! -f "$SYSCTL_FILE" ]] || [[ "$(cat "$SYSCTL_FILE")" != "$SYSCTL_CONTENT" ]]; then
    echo "$SYSCTL_CONTENT" > "$SYSCTL_FILE"
    sysctl --system >/dev/null
    log_ok "Applied SiFive U74 PMU & broker sysctl parameters ($SYSCTL_FILE)"
else
    log_skip "Sysctl parameters in $SYSCTL_FILE already up to date"
fi

# ==============================================================================
# STAGE 1 & 2: Verify WD_BLACK SN750 Presence & 4Kn Native Sector Size (4096B)
# ==============================================================================
log_step "1 & 2. Verifying WD_BLACK SN750 ($NVME_DEV) & 4Kn LBA Sector Size"

if [[ ! -b "$NVME_DEV" ]]; then
    log_warn "NVMe device $NVME_DEV not detected! Check M.2 seating on underside of VF2 and run 'lspci'."
    exit 1
fi

NVME_SHORT="$(basename "$NVME_DEV")"
CURRENT_LBA_SIZE="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"

if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE_NVME" == "false" ]]; then
    log_skip "Existing filesystem labeled '$FS_LABEL' found on $EXISTING_FS_DEV (Logical sector size: ${CURRENT_LBA_SIZE}B)"
else
    if [[ "$CURRENT_LBA_SIZE" == "4096" ]]; then
        log_skip "$NVME_DEV is already formatted to native 4096-byte (4Kn) sectors"
    else
        if lsblk -no MOUNTPOINT "$NVME_DEV" | grep -q "/"; then
            log_warn "$NVME_DEV has active mounts! Unmount before formatting."
            exit 1
        fi

        # Match lbads:12 (2^12 = 4096 bytes) on WD_Black SN750
        LBA_4K_INDEX="$(nvme id-ns "$NVME_DEV" | awk '/lbads:12/ {print $2}' | tr -d ':' | head -n1)"
        if [[ -n "$LBA_4K_INDEX" ]]; then
            echo "Switching $NVME_DEV from ${CURRENT_LBA_SIZE}B to 4096B sectors (LBA Format Index: $LBA_4K_INDEX)..."
            nvme format "$NVME_DEV" -l "$LBA_4K_INDEX" -s 1 --force || nvme format "$NVME_DEV" -l "$LBA_4K_INDEX" --force
            partprobe "$NVME_DEV" || true
            udevadm settle
            sleep 2
            NEW_LBA_SIZE="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
            log_ok "$NVME_DEV formatted to ${NEW_LBA_SIZE}-byte native sectors"
        else
            log_warn "Could not auto-detect 4K LBA index on $NVME_DEV; keeping ${CURRENT_LBA_SIZE}B sectors"
        fi
    fi
fi

# ==============================================================================
# STAGE 3: Partitioning / LVM & XFS Formatting on SN750 + /etc/fstab
# ==============================================================================
log_step "3. Provisioning SN750 Storage Volume & Mounting XFS ($MOUNT_POINT)"

EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"

if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE_NVME" == "false" ]]; then
    TARGET_BLOCK_DEV="$EXISTING_FS_DEV"
    log_skip "XFS volume '$FS_LABEL' already exists at $TARGET_BLOCK_DEV"
else
    log_warn "Creating fresh storage layout on $NVME_DEV..."
    umount "$MOUNT_POINT" 2>/dev/null || true

    if [[ "$USE_LVM" == "true" ]]; then
        vgremove -f "$VG_NAME" 2>/dev/null || true
        pvremove -f "$NVME_DEV" 2>/dev/null || true
        wipefs -a "$NVME_DEV"

        pvcreate --dataalignment 4m -f -y "$NVME_DEV"
        vgcreate "$VG_NAME" "$NVME_DEV"
        # Allocate 85% of VG, leaving 15% free for instant benchmark LVM snapshots
        lvcreate -l 85%VG -n "$LV_NAME" -y "$VG_NAME"
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_ok "Created LVM Logical Volume $TARGET_BLOCK_DEV (with 15% VG snapshot reserve)"
    else
        wipefs -a "$NVME_DEV"
        parted -s "$NVME_DEV" mklabel gpt
        parted -s -a optimal "$NVME_DEV" mkpart primary xfs 1MiB 100%
        partprobe "$NVME_DEV" || true
        udevadm settle
        sleep 2
        TARGET_BLOCK_DEV="${NVME_DEV}p1"
        log_ok "Created GPT partition $TARGET_BLOCK_DEV"
    fi

    SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
    mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV"
    udevadm settle
    log_ok "Formatted $TARGET_BLOCK_DEV as XFS (label: $FS_LABEL, sector: ${SECTOR_SZ}B)"
fi

mkdir -p "$MOUNT_POINT"

FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  xfs  rw,noatime,nodiratime,logbsize=256k,nofail,x-systemd.device-timeout=15s  0  2"
if ! grep -q "LABEL=${FS_LABEL}" /etc/fstab && ! grep -q "[[:space:]]${MOUNT_POINT}[[:space:]]" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    systemctl daemon-reload
    log_ok "Added $FS_LABEL to /etc/fstab with nofail protection"
else
    log_skip "$MOUNT_POINT already present in /etc/fstab"
fi

if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$MOUNT_POINT"
    log_ok "Mounted $MOUNT_POINT"
else
    log_skip "$MOUNT_POINT is already mounted"
fi

# ==============================================================================
# STAGE 4: Installing PostgreSQL (PGDG / Debian riscv64 Auto-Resolution)
# ==============================================================================
log_step "4. Installing PostgreSQL ${PG_VERSION} (riscv64)"

PGDG_KEY="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
CODENAME="$(lsb_release -cs 2>/dev/null || echo "sid")"
# StarFive Debian images sometimes report 'unstable' or 'trixie'; PGDG uses 'sid' or 'trixie'
if [[ "$CODENAME" == "unstable" ]]; then
    CODENAME="sid"
fi

if [[ ! -f "$PGDG_KEY" ]]; then
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o "$PGDG_KEY"
    log_ok "Downloaded PGDG signing key"
else
    log_skip "PGDG signing key already present"
fi

EXPECTED_REPO="deb [arch=riscv64 signed-by=${PGDG_KEY}] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main"
if [[ ! -f "$PGDG_LIST" ]] || ! grep -q "${CODENAME}-pgdg" "$PGDG_LIST"; then
    echo "$EXPECTED_REPO" > "$PGDG_LIST"
    # If the specific Debian suite isn't in PGDG riscv64 yet, fall back cleanly to native Debian repo
    if ! apt-get update -q 2>/dev/null; then
        log_warn "PGDG suite ${CODENAME}-pgdg not available for riscv64; falling back to native Debian repository"
        rm -f "$PGDG_LIST"
        apt-get update -q
    else
        log_ok "Configured PGDG repository for ${CODENAME}-pgdg (riscv64)"
    fi
else
    log_skip "PGDG repository check complete"
fi

# Verify requested PG_VERSION exists in apt cache; fallback to highest available (e.g. 17 or 16) if on older StarFive Debian
if ! apt-cache show "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
    FALLBACK_PG="$(apt-cache search --names-only '^postgresql-[0-9]+$' | awk '{print $1}' | sed 's/postgresql-//' | sort -rn | head -n1)"
    if [[ -n "$FALLBACK_PG" ]]; then
        log_warn "postgresql-${PG_VERSION} not found in repo; using postgresql-${FALLBACK_PG}"
        PG_VERSION="$FALLBACK_PG"
    fi
fi

if ! dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
    apt-get install "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
    log_ok "Installed postgresql-${PG_VERSION}"
else
    log_skip "postgresql-${PG_VERSION} is already installed"
fi

# ==============================================================================
# STAGE 5: Relocating Cluster to SN750 & Tuning for SiFive U74 8GB Control Node
# ==============================================================================
log_step "5. Relocating Cluster to $MOUNT_POINT & Applying SiFive U74 Control Tuning"

NVME_PG_ROOT="${MOUNT_POINT}/postgresql"
NVME_PG_DATA="${NVME_PG_ROOT}/${PG_VERSION}/main"
DEFAULT_PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
DROPIN_CONF="${CONF_DIR}/99-brakerbench-vf2.conf"

# 5.1 Idempotent Data Directory Migration
if [[ -f "${NVME_PG_DATA}/PG_VERSION" ]]; then
    log_skip "PostgreSQL cluster already initialized on NVMe at ${NVME_PG_DATA}"
else
    echo "Migrating initial PostgreSQL ${PG_VERSION} cluster to ${NVME_PG_DATA}..."
    systemctl stop postgresql
    mkdir -p "$NVME_PG_DATA"
    chown -R postgres:postgres "$NVME_PG_ROOT"
    chmod 700 "$NVME_PG_DATA"

    rsync -a "${DEFAULT_PG_DATA}/" "${NVME_PG_DATA}/"
    chown -R postgres:postgres "$NVME_PG_ROOT"
    log_ok "Synced clean cluster from $DEFAULT_PG_DATA to $NVME_PG_DATA"
fi

# 5.2 Auto-verify PostgreSQL 18 io_method support (only include directive if PG >= 18)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin/postgres"
IO_METHOD_LINE=""
if [[ "$PG_VERSION" -ge 18 ]]; then
    IO_METHOD="worker"
    if [[ -x "$PG_BIN" ]] && ldd "$PG_BIN" | grep -q "liburing"; then
        if [[ "$(sysctl -n kernel.io_uring_disabled 2>/dev/null || echo 0)" == "0" ]]; then
            IO_METHOD="io_uring"
        fi
    fi
    IO_METHOD_LINE="io_method = ${IO_METHOD}"
    log_ok "Selected PostgreSQL ${PG_VERSION} Async I/O method: ${IO_METHOD_LINE}"
fi

# 5.3 Idempotent Drop-In Tuning File (Planner costs locked 1:1 with BrakerBench-P550!)
mkdir -p "$CONF_DIR"
DESIRED_PG_CONF="# DREW-V Labs: StarFive VisionFive 2 (8GB LPDDR4 + WD_BLACK SN750 4Kn Control Node)
data_directory = '${NVME_PG_DATA}'
listen_addresses = '*'

# 8GB LPDDR4 Memory Allocation (25% Shared Buffers; work_mem locked 1:1 with P550 for Planner Parity)
shared_buffers = 2GB
effective_cache_size = 6GB
work_mem = 64MB
maintenance_work_mem = 512MB
huge_pages = try

# SiFive U74 4-Core (2-Wide In-Order, RVA20 RV64GC Scalar) Tuning — Locked 1:1 with P550
jit = off
max_worker_processes = 4
max_parallel_workers = 4
max_parallel_workers_per_gather = 2

# WD_BLACK SN750 4Kn PCIe Gen2 x1 — Planner Costs Locked 1:1 with P550
${IO_METHOD_LINE}
effective_io_concurrency = 200
maintenance_io_concurrency = 100
random_page_cost = 1.1
track_io_timing = on

# WAL & Checkpoints (Identical to P550)
wal_compression = zstd
wal_buffers = 64MB
min_wal_size = 2GB
max_wal_size = 16GB
checkpoint_completion_target = 0.9"

NEED_PG_RESTART="false"
if [[ ! -f "$DROPIN_CONF" ]] || [[ "$(cat "$DROPIN_CONF")" != "$DESIRED_PG_CONF" ]]; then
    echo "$DESIRED_PG_CONF" > "$DROPIN_CONF"
    chown -R postgres:postgres "$CONF_DIR"
    NEED_PG_RESTART="true"
    log_ok "Wrote tuning configuration to $DROPIN_CONF"
else
    log_skip "PostgreSQL configuration $DROPIN_CONF is already up to date"
fi

# 5.4 Ensure Service is Running & Healthy
if ! systemctl is-active --quiet postgresql || [[ "$NEED_PG_RESTART" == "true" ]]; then
    systemctl enable postgresql >/dev/null 2>&1 || true
    systemctl restart postgresql
    log_ok "PostgreSQL ${PG_VERSION} service started/restarted"
else
    log_skip "PostgreSQL ${PG_VERSION} is already active and running current config"
fi

# ==============================================================================
# STAGE 6: Post-Flight Verification Summary
# ==============================================================================
log_step "6. Post-Flight Verification Summary"

ACTIVE_DATA_DIR="$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null || echo "N/A")"
ACTIVE_BUFFERS="$(sudo -u postgres psql -tAc "SHOW shared_buffers;" 2>/dev/null || echo "N/A")"
FINAL_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"

printf "  • Hostname           : %s\n" "$(hostname)"
printf "  • Kernel / Arch      : %s (%s)\n" "$(uname -r)" "$(uname -m)"
printf "  • Journald Storage   : %s\n" "$(grep -h "^Storage=" /etc/systemd/journald.conf.d/* 2>/dev/null || echo "default")"
printf "  • NVMe LBA Block Sz  : %s bytes\n" "$FINAL_LBA"
printf "  • Hot NVMe Mount     : %s\n" "$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT" || echo "Not Mounted")"
printf "  • PG Data Directory  : %s\n" "$ACTIVE_DATA_DIR"
printf "  • PG Shared Buffers  : %s\n" "$ACTIVE_BUFFERS"

echo ""
log_ok "BrakerBench-VF2 PostgreSQL ${PG_VERSION} Control Node Forge Complete!"
