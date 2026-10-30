#!/usr/bin/env bash
# Title: forge-brakerbox-titan.sh
# Description: Script to provision a BrakerBox-Titan server with optional RAID, NFS, and 10GbE networking.
# Author: Drew Vandagriff (DREW-V Labs)
# Date: 2026-10-24
# Version: 1.0.0
# License: MIT
# ==============================================================================
# DREW-V Labs // Milk-V Titan (UltraRISC UR-DP1000) Forge Script
# Path: drewv-labs-toolkit/milkv-titan-databroker/forge/forge-brakerbox-titan.sh
# Architecture: RVA22 + H-Ext 1.0 (RV64GCBHX) | 8x UR-CP100 4-Wide OoO @ 2.0GHz
# Cache & RAM : 8MB L2 + 16MB Shared LLC (24MB Total) | 64GB ECC DDR4-3200 UDIMM
# Storage     : Native M.2 PCIe Gen4 x4 WD_BLACK SN850X (~7,300 MB/s)
#
# Usage:
#   ./forge-brakerbox-titan.sh --role prod                  # Provision BrakerBox-Titan (Prod + RAID + NFS + 10GbE)
#   ./forge-brakerbox-titan.sh --role bench                 # Provision BrakerBench-Titan (Test Bench, no RAID)
#   ./forge-brakerbox-titan.sh --role bench --with-raid     # Bench with optional RAID
#   ./forge-brakerbox-titan.sh --role bench --force-wipe-pg # Re-create PG LVM/XFS volume
# ==============================================================================

set -euo pipefail

# --- Default Role & Configuration Variables ---
NODE_ROLE=""
NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
FS_LABEL="PGDATA_NVME"
USE_LVM="${USE_LVM:-true}"          # true = LVM with 15% snapshot reserve
VG_NAME="vg_titan"
LV_NAME="lv_pgdata"
PG_VERSION="${PG_VERSION:-18}"
LAB_SUBNET="${LAB_SUBNET:-10.0.10.0/24}"

# SilverStone USB 3.0 RAID 10 Configuration (BigRed-WDR48 & LilBlu-WDB24)
BIGRED_MD="/dev/md/bigred"
BIGRED_LABEL="BIGRED_VAULT"
BIGRED_MOUNT="/mnt/bigred_wdr48"

LILBLU_MD="/dev/md/lilblu"
LILBLU_LABEL="LILBLU_ARCH"
LILBLU_MOUNT="/mnt/lilblu_wdb24"

# --- CLI Argument Parsing ---
WITH_RAID="auto"
FORCE_WIPE_PG="false"
FORCE_WIPE_RAID="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            NODE_ROLE="${2:-}"
            shift 2
            ;;
        --role=*)
            NODE_ROLE="${1#*=}"
            shift
            ;;
        --with-raid)
            WITH_RAID="true"
            shift
            ;;
        --no-raid)
            WITH_RAID="false"
            shift
            ;;
        --force-wipe-pg|--force-wipe-nvme)
            FORCE_WIPE_PG="true"
            shift
            ;;
        --force-wipe-raid)
            FORCE_WIPE_RAID="true"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --role <prod|bench> [--with-raid|--no-raid] [--force-wipe-pg] [--force-wipe-raid]"
            exit 1
            ;;
    esac
done

if [[ "$NODE_ROLE" != "prod" && "$NODE_ROLE" != "bench" ]]; then
    echo "ERROR: You must specify --role prod (for brakerbox-titan) or --role bench (for BrakerBench-Titan)."
    echo "Example: sudo ./forge-brakerbox-titan.sh --role prod"
    exit 1
fi

if [[ "$NODE_ROLE" == "prod" ]]; then
    TARGET_HOSTNAME="${TARGET_HOSTNAME:-brakerbox-titan}"
    [[ "$WITH_RAID" == "auto" ]] && WITH_RAID="true"
else
    TARGET_HOSTNAME="${TARGET_HOSTNAME:-brakerbench-titan}"
    [[ "$WITH_RAID" == "auto" ]] && WITH_RAID="false"
fi

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# --- Logging Helpers ---
log_step() { printf "\n\033[1;36m=== [%s] %s ===\033[0m\n" "$(date +%H:%M:%S)" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s (already configured)\n" "$1"; }
log_warn() { printf "\033[1;31m[WARN]\033[0m %s\n" "$1"; }

if [[ $EUID -ne 0 ]]; then
   echo "Re-executing with sudo..."
   exec sudo -E bash "$0" "$@"
fi

# ==============================================================================
# STAGE 0: Hostname, Power States, Headless Strip, CPU Governor & Sysctls
# ==============================================================================
log_step "0. Pregame: Hostname ($TARGET_HOSTNAME), Headless Strip, CPPC Governor & Sysctls"

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

# 0.2 Idempotent Sleep/Suspend Masking
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

# 0.3 Install Core Server, Storage, BMC/IPMI & Telemetry Packages
CORE_PKGS=(
    mdadm lvm2 xfsprogs parted gdisk smartmontools nvme-cli
    sysstat iotop htop jq curl ca-certificates gnupg lsb-release
    git build-essential rsync dmidecode ipmitool ethtool
)
if [[ "$NODE_ROLE" == "prod" ]]; then
    CORE_PKGS+=(nfs-kernel-server)
fi
if apt-cache show linux-perf >/dev/null 2>&1; then
    CORE_PKGS+=(linux-perf)
elif apt-cache show linux-tools-common >/dev/null 2>&1; then
    CORE_PKGS+=(linux-tools-common linux-tools-generic)
fi

MISSING_PKGS=()
for pkg in "${CORE_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    apt-get update -q
    apt-get upgrade "${APT_FLAGS[@]}"
    apt-get install "${APT_FLAGS[@]}" "${MISSING_PKGS[@]}"
    log_ok "Installed core Titan packages: ${MISSING_PKGS[*]}"
else
    log_skip "All core Titan packages already installed"
fi

# 0.4 Set Default Boot Target to Headless Console
if [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
    systemctl set-default multi-user.target
    log_ok "Boot target set to headless multi-user.target"
else
    log_skip "Boot target is already multi-user.target"
fi

# 0.5 Idempotent Snap & Desktop GUI Bloat Purge
if command -v snap >/dev/null 2>&1 || dpkg -s snapd >/dev/null 2>&1; then
    for s in firefox snap-store bare core22 gtk-common-themes gnome-42-2204 snapd; do
        snap remove --purge "$s" 2>/dev/null || true
    done
    systemctl stop snapd.socket snapd.service 2>/dev/null || true
    apt-get purge "${APT_FLAGS[@]}" snapd 2>/dev/null || true
    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd ~/snap
    log_ok "Purged snapd and all snap packages"
else
    log_skip "snapd already purged"
fi

GUI_BLOAT=(
    ubuntu-desktop ubuntu-desktop-minimal gnome-shell gdm3 lightdm xfce4*
    xwayland apport whoopsie unattended-upgrades packagekit modemmanager
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
    log_ok "Purged GUI & background bloat (${#PURGE_LIST[@]} packages)"
else
    log_skip "Desktop GUI & telemetry bloat already purged"
fi

# 0.6 Lock UltraRISC UR-CP100 ACPI CPPC CPU Governor to 'performance' (2.0 GHz)
GOV_SERVICE="/etc/systemd/system/drewv-cpu-performance.service"
if [[ ! -f "$GOV_SERVICE" ]]; then
    cat << 'EOF' > "$GOV_SERVICE"
[Unit]
Description=DREW-V Labs: Pin CPU Frequency Governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$g" ] && echo performance > "$g" || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now drewv-cpu-performance.service
    log_ok "Created & enabled drewv-cpu-performance.service (pins all 8 UR-CP100 cores to 2.0GHz)"
else
    systemctl start drewv-cpu-performance.service 2>/dev/null || true
    log_skip "CPU performance governor service already installed"
fi

# 0.7 Idempotent Sysctl Configuration (UR-CP100 PMU + 64GB RAM + 10GbE Network Buffers)
SYSCTL_FILE="/etc/sysctl.d/90-${TARGET_HOSTNAME}.conf"
SYSCTL_CONTENT="# Allow non-root perf sampling of UltraRISC UR-CP100 L1/L2/LLC hardware counters
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0
kernel.nmi_watchdog = 0

# 64GB ECC DDR4 Memory & Dirty Page Writeback Tuning (Matched with P550/VF2)
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15

# 10GbE SFP+ & High-Concurrency Broker Network Queue Tuning
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 4194304
net.core.netdev_max_backlog = 30000
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mtu_probing = 1"

if [[ ! -f "$SYSCTL_FILE" ]] || [[ "$(cat "$SYSCTL_FILE")" != "$SYSCTL_CONTENT" ]]; then
    echo "$SYSCTL_CONTENT" > "$SYSCTL_FILE"
    sysctl --system >/dev/null
    log_ok "Applied UR-DP1000 PMU, 64GB VM & 10GbE sysctl parameters ($SYSCTL_FILE)"
else
    log_skip "Sysctl parameters in $SYSCTL_FILE already up to date"
fi

# ==============================================================================
# STAGE 1 & 2: Detect NVMe Topology (Dedicated NVMe vs Shared OS+Data NVMe)
# ==============================================================================
log_step "1 & 2. Inspecting PCIe Gen4 x4 NVMe ($NVME_DEV) & Root OS Layout"

if [[ ! -b "$NVME_DEV" ]]; then
    log_warn "NVMe device $NVME_DEV not detected! Check M.2 Gen4 x4 slot seating and run 'lspci'."
    exit 1
fi

NVME_SHORT="$(basename "$NVME_DEV")"
ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
NVME_HAS_ROOT="false"
if [[ "$ROOT_SOURCE" == "${NVME_DEV}"* ]]; then
    NVME_HAS_ROOT="true"
    log_warn "Root OS (/) resides on $NVME_DEV ($ROOT_SOURCE)."
    log_warn "Shared-NVMe Mode active: OS partitions will be strictly protected; PGDATA will use a dedicated partition."
else
    log_ok "Root OS (/) resides on $ROOT_SOURCE; $NVME_DEV is a dedicated data drive."
fi

CURRENT_LBA_SIZE="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"

if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE_PG" == "false" ]]; then
    log_skip "Existing filesystem labeled '$FS_LABEL' found on $EXISTING_FS_DEV (LBA sector size: ${CURRENT_LBA_SIZE}B)"
elif [[ "$NVME_HAS_ROOT" == "true" ]]; then
    log_skip "Skipping whole-disk 'nvme format' because OS is running from $NVME_DEV (Current LBA size: ${CURRENT_LBA_SIZE}B)"
else
    if [[ "$CURRENT_LBA_SIZE" == "4096" ]]; then
        log_skip "$NVME_DEV is already formatted to native 4096-byte (4Kn) sectors"
    else
        if lsblk -no MOUNTPOINT "$NVME_DEV" | grep -q "/"; then
            log_warn "$NVME_DEV has active mounts! Unmount before low-level 4Kn formatting."
            exit 1
        fi
        LBA_4K_INDEX="$(nvme id-ns "$NVME_DEV" | awk '/lbads:12/ {print $2}' | tr -d ':' | head -n1)"
        if [[ -n "$LBA_4K_INDEX" ]]; then
            echo "Formatting dedicated $NVME_DEV from ${CURRENT_LBA_SIZE}B to 4096B sectors (LBA Index: $LBA_4K_INDEX)..."
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
# STAGE 3A: Provisioning LVM + 4K XFS Volume on SN850X ($MOUNT_POINT)
# ==============================================================================
log_step "3A. Provisioning PCIe Gen4 x4 XFS Volume ($MOUNT_POINT)"

EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"

if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE_PG" == "false" ]]; then
    TARGET_BLOCK_DEV="$EXISTING_FS_DEV"
    log_skip "XFS volume '$FS_LABEL' already exists at $TARGET_BLOCK_DEV"
else
    umount "$MOUNT_POINT" 2>/dev/null || true

    if [[ "$NVME_HAS_ROOT" == "false" ]]; then
        # Dedicated Whole-Disk Mode
        log_warn "Provisioning dedicated whole-disk storage on $NVME_DEV..."
        vgremove -f "$VG_NAME" 2>/dev/null || true
        pvremove -f "$NVME_DEV" 2>/dev/null || true
        wipefs -a "$NVME_DEV"
        PV_TARGET="$NVME_DEV"
    else
        # Shared Single-NVMe Mode (OS + Data Partition)
        PG_PART="${NVME_DEV}p3"
        if [[ ! -b "$PG_PART" ]]; then
            log_warn "Creating dedicated data partition ($PG_PART) in remaining unallocated space on $NVME_DEV..."
            # Find end of last partition and allocate remaining space to partition 3
            LAST_END="$(parted -m -s "$NVME_DEV" unit MiB print | tail -n1 | cut -d: -f3 | tr -d 'MiB')"
            if [[ -z "$LAST_END" ]]; then
                log_warn "Could not determine free space on shared OS drive $NVME_DEV. Shrink root partition or create ${NVME_DEV}p3 manually."
                exit 1
            fi
            START_MIB=$(( ${LAST_END%.*} + 2 ))
            parted -s -a optimal "$NVME_DEV" mkpart PGDATA_LVM "${START_MIB}MiB" 100%
            partprobe "$NVME_DEV" || true
            udevadm settle
            sleep 2
        fi
        if [[ ! -b "$PG_PART" ]]; then
            log_warn "Partition $PG_PART could not be created (is the root OS partition occupying 100% of $NVME_DEV?)."
            exit 1
        fi
        vgremove -f "$VG_NAME" 2>/dev/null || true
        pvremove -f "$PG_PART" 2>/dev/null || true
        wipefs -a "$PG_PART"
        PV_TARGET="$PG_PART"
    fi

    if [[ "$USE_LVM" == "true" ]]; then
        pvcreate --dataalignment 4m -f -y "$PV_TARGET"
        vgcreate "$VG_NAME" "$PV_TARGET"
        lvcreate -l 85%VG -n "$LV_NAME" -y "$VG_NAME"
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_ok "Created LVM Logical Volume $TARGET_BLOCK_DEV on $PV_TARGET (15% VG snapshot reserve)"
    else
        TARGET_BLOCK_DEV="$PV_TARGET"
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
# STAGE 3B: SilverStone USB 3.0 RAID 10 & NFSv4 Vault (Default on --role prod)
# ==============================================================================
provision_usb_raid10() {
    local array_name="$1"
    local md_dev="$2"
    local fs_label="$3"
    local mount_pt="$4"
    local min_bytes="$5"
    local max_bytes="$6"

    echo "--- Checking $array_name ($md_dev -> $mount_pt) ---"
    mdadm --assemble --scan 2>/dev/null || true

    local existing_fs
    existing_fs="$(blkid -L "$fs_label" || true)"

    if [[ -n "$existing_fs" && "$FORCE_WIPE_RAID" == "false" ]]; then
        log_skip "$array_name XFS volume '$fs_label' already exists on $existing_fs"
    else
        mapfile -t CANDIDATE_DISKS < <(
            lsblk -b -dn -o NAME,SIZE,TYPE | awk -v min="$min_bytes" -v max="$max_bytes" '
                $3 == "disk" && $2 >= min && $2 <= max { print "/dev/"$1 }
            '
        )

        if [[ ${#CANDIDATE_DISKS[@]} -ne 4 ]]; then
            log_warn "$array_name skipped: Expected 4 individual disks in Clear RAID mode, found ${#CANDIDATE_DISKS[@]} (${CANDIDATE_DISKS[*]:-none})."
            return 0
        fi

        log_warn "Building $array_name RAID 10 across 4 drives: ${CANDIDATE_DISKS[*]}"
        umount "$mount_pt" 2>/dev/null || true
        mdadm --stop "$md_dev" 2>/dev/null || true

        for d in "${CANDIDATE_DISKS[@]}"; do
            mdadm --zero-superblock "$d" 2>/dev/null || true
            wipefs -a "$d"
        done

        mdadm --create "$md_dev" \
            --level=10 --raid-devices=4 \
            --metadata=1.2 --bitmap=internal \
            --name="$array_name" --run --force \
            "${CANDIDATE_DISKS[@]}"

        udevadm settle
        mkfs.xfs -f -b size=4096 -L "$fs_label" "$md_dev"
        udevadm settle
        log_ok "Created and formatted $array_name ($md_dev) with XFS label '$fs_label'"
    fi

    mkdir -p "$mount_pt"
    local raid_fstab="LABEL=${fs_label}  ${mount_pt}  xfs  defaults,noatime,nodiratime,nofail,x-systemd.device-timeout=15s  0  2"
    if ! grep -q "LABEL=${fs_label}" /etc/fstab; then
        echo "$raid_fstab" >> /etc/fstab
        systemctl daemon-reload
        log_ok "Added $fs_label ($mount_pt) to /etc/fstab with nofail protection"
    else
        log_skip "$fs_label already in /etc/fstab"
    fi

    if ! mountpoint -q "$mount_pt"; then
        mount "$mount_pt"
        log_ok "Mounted $mount_pt"
    else
        log_skip "$mount_pt is already mounted"
    fi
}

if [[ "$WITH_RAID" == "true" ]]; then
    log_step "3B. Provisioning SilverStone USB RAID 10 Arrays & NFS Exports ($TARGET_HOSTNAME)"

    # BigRed-WDR48: 4x 12TB WD Red (~12TB -> match 11TB to 13TB)
    provision_usb_raid10 "bigred" "$BIGRED_MD" "$BIGRED_LABEL" "$BIGRED_MOUNT" 11000000000000 13000000000000

    # LilBlu-WDB24: 4x 6TB WD Blue (~6TB -> match 5.5TB to 6.5TB)
    provision_usb_raid10 "lilblu" "$LILBLU_MD" "$LILBLU_LABEL" "$LILBLU_MOUNT" 5500000000000 6500000000000

    mkdir -p /etc/mdadm
    if [[ -f /etc/mdadm/mdadm.conf ]]; then
        sed -i '/^ARRAY /d' /etc/mdadm/mdadm.conf
    fi
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u
    log_ok "Updated /etc/mdadm/mdadm.conf and initramfs"

    # Configure idempotent NFS exports on Production brakerbox-titan
    if [[ "$NODE_ROLE" == "prod" ]] && dpkg -s nfs-kernel-server >/dev/null 2>&1; then
        for mp in "$BIGRED_MOUNT" "$LILBLU_MOUNT"; do
            if mountpoint -q "$mp"; then
                mkdir -p "${mp}/nfs_share"
                if ! grep -q "^${mp}/nfs_share " /etc/exports 2>/dev/null; then
                    echo "${mp}/nfs_share ${LAB_SUBNET}(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
                    log_ok "Added NFS export for ${mp}/nfs_share (${LAB_SUBNET})"
                fi
            fi
        done
        exportfs -ra 2>/dev/null || true
        systemctl enable --now nfs-kernel-server 2>/dev/null || true
    fi
else
    log_step "3B. SilverStone USB RAID Provisioning Skipped (Role: $NODE_ROLE)"
fi

# ==============================================================================
# STAGE 4: Installing PostgreSQL $PG_VERSION (PGDG Ubuntu/Debian riscv64)
# ==============================================================================
log_step "4. Installing PostgreSQL ${PG_VERSION} (riscv64)"

PGDG_KEY="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
CODENAME="$(lsb_release -cs 2>/dev/null || echo "noble")"
[[ "$CODENAME" == "unstable" ]] && CODENAME="sid"

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
    if ! apt-get update -q 2>/dev/null; then
        log_warn "PGDG suite ${CODENAME}-pgdg unavailable; falling back to distro repository"
        rm -f "$PGDG_LIST"
        apt-get update -q
    else
        log_ok "Configured PGDG repository for ${CODENAME}-pgdg (riscv64)"
    fi
else
    log_skip "PGDG repository already configured"
fi

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
# STAGE 5: Relocating Cluster to Gen4 SN850X & Tuning for UltraRISC UR-DP1000
# ==============================================================================
log_step "5. Relocating Cluster to $MOUNT_POINT & Applying UltraRISC UR-DP1000 Tuning"

NVME_PG_ROOT="${MOUNT_POINT}/postgresql"
NVME_PG_DATA="${NVME_PG_ROOT}/${PG_VERSION}/main"
DEFAULT_PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
DROPIN_CONF="${CONF_DIR}/99-${TARGET_HOSTNAME}.conf"

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

# Prepare warm/cold PostgreSQL tablespace directories if BigRed / LilBlu are mounted
for raid_mp in "$BIGRED_MOUNT" "$LILBLU_MOUNT"; do
    if mountpoint -q "$raid_mp"; then
        mkdir -p "${raid_mp}/postgresql/tablespaces"
        chown -R postgres:postgres "${raid_mp}/postgresql"
        chmod 700 "${raid_mp}/postgresql/tablespaces"
    fi
done

# 5.2 Auto-verify PostgreSQL 18 io_uring support
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

# 5.3 Role-Specific Tuning (Prod vs Bench Planner-Parity)
if [[ "$NODE_ROLE" == "prod" ]]; then
    MAINT_WORK_MEM="4GB"
    MAX_WAL="32GB"
else
    # Bench mode locks maintenance & WAL bounds closer to P550/VF2 while keeping 1:1 planner costs
    MAINT_WORK_MEM="2GB"
    MAX_WAL="16GB"
fi

mkdir -p "$CONF_DIR"
DESIRED_PG_CONF="# DREW-V Labs: Milk-V Titan (${TARGET_HOSTNAME} | Role: ${NODE_ROLE})
# Silicon: UltraRISC UR-DP1000 (8x UR-CP100 4-Wide OoO @ 2.0GHz, 24MB Cache, 64GB ECC DDR4)
data_directory = '${NVME_PG_DATA}'
listen_addresses = '*'
max_connections = 200

# 64GB ECC DDR4-3200 Memory Allocation (work_mem = 64MB locked 1:1 with P550 & VF2 for Planner Parity)
shared_buffers = 16GB
effective_cache_size = 48GB
work_mem = 64MB
maintenance_work_mem = ${MAINT_WORK_MEM}
huge_pages = try

# UltraRISC UR-DP1000 8-Core (4-Wide Out-of-Order, RVA22 + H-Ext 1.0) Tuning
jit = off
max_worker_processes = 8
max_parallel_workers = 8
max_parallel_workers_per_gather = 4

# WD_BLACK SN850X 4Kn Native PCIe Gen4 x4 (~7,300 MB/s) — Planner Costs Locked 1:1 with P550 & VF2
${IO_METHOD_LINE}
effective_io_concurrency = 200
maintenance_io_concurrency = 100
random_page_cost = 1.1
track_io_timing = on

# WAL & Checkpoints
wal_compression = zstd
wal_buffers = 64MB
min_wal_size = 2GB
max_wal_size = ${MAX_WAL}
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

if ! systemctl is-active --quiet postgresql || [[ "$NEED_PG_RESTART" == "true" ]]; then
    systemctl enable postgresql >/dev/null 2>&1 || true
    systemctl restart postgresql
    log_ok "PostgreSQL ${PG_VERSION} service started/restarted"
else
    log_skip "PostgreSQL ${PG_VERSION} is already active and running current config"
fi

# ==============================================================================
# STAGE 6: Post-Flight Hardware & Database Verification Summary
# ==============================================================================
log_step "6. Post-Flight Verification Summary (${TARGET_HOSTNAME})"

ACTIVE_DATA_DIR="$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null || echo "N/A")"
ACTIVE_BUFFERS="$(sudo -u postgres psql -tAc "SHOW shared_buffers;" 2>/dev/null || echo "N/A")"
FINAL_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
PCIE_LINK="$(lspci -vv 2>/dev/null | grep -A 15 -i "Non-Volatile memory" | grep "LnkSta:" | head -n1 | sed 's/^[[:space:]]*//' || echo "Unknown")"
KVM_STATUS="Not Detected"
[[ -e /dev/kvm ]] && KVM_STATUS="Active (/dev/kvm present — RISC-V H-Ext 1.0 Ready)"

printf "  • Hostname & Role    : %s (--role %s)\n" "$(hostname)" "$NODE_ROLE"
printf "  • Kernel / Arch      : %s (%s)\n" "$(uname -r)" "$(uname -m)"
printf "  • Total System RAM   : %s\n" "$(free -h | awk '/^Mem:/ {print $2}')"
printf "  • RISC-V KVM H-Ext   : %s\n" "$KVM_STATUS"
printf "  • NVMe PCIe Link     : %s\n" "${PCIE_LINK:-PCIe Gen4 x4}"
printf "  • NVMe LBA Block Sz  : %s bytes\n" "$FINAL_LBA"
printf "  • Hot NVMe Mount     : %s\n" "$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT" || echo "Not Mounted")"
printf "  • Warm RAID (BigRed) : %s\n" "$(findmnt -n -o SOURCE,TARGET,FSTYPE "$BIGRED_MOUNT" 2>/dev/null || echo "Not Mounted")"
printf "  • Cold RAID (LilBlu) : %s\n" "$(findmnt -n -o SOURCE,TARGET,FSTYPE "$LILBLU_MOUNT" 2>/dev/null || echo "Not Mounted")"
printf "  • PG Data Directory  : %s\n" "$ACTIVE_DATA_DIR"
printf "  • PG Shared Buffers  : %s\n" "$ACTIVE_BUFFERS"

echo ""
log_ok "${TARGET_HOSTNAME} PostgreSQL ${PG_VERSION} Forge Complete!"
