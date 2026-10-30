#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive HiFive Premier P550 Data Broker Forge Script
# Path: drewv-labs/brakerrak/nodes/databrokers/brakerbox-p550/forge.sh
# Architecture: RVA20 (RV64GC + Zba/Zbb) | 4x P550 3-Wide OoO | 32GB LPDDR5
#
# Usage:
#   ./forge.sh                                 # Standard idempotent P550 + NVMe + PG18 build (RAID skipped)
#   ./forge.sh --role bench                    # Set hostname to brakerbench-p550 (default: brakerbox-p550)
#   ./forge.sh --with-raid                     # Also provision/mount BigRed-WDR48 & LilBlu-WDB24
#   ./forge.sh --force-wipe-nvme               # Destructively 4Kn format NVMe & zero-cache rebuild PG18
#   ./forge.sh --with-raid --force-wipe-raid   # Destructively rebuild USB RAID10 arrays
#   ./forge.sh --force-rebuild-pg              # Force zero-cache PGDG deb-src recompile with perf stat
# ==============================================================================

set -Eeuo pipefail

# --- Fail-Fast Error Trap ---
trap_err() {
    local exit_code=$?
    local line_no=$1
    printf "\n\033[1;31m[FATAL] Forge failed at line %s (exit code: %s)\033[0m\n" "$line_no" "$exit_code" >&2
    printf "\033[1;31m[CMD]   %s\033[0m\n" "${BASH_COMMAND}" >&2
    exit "$exit_code"
}
trap 'trap_err ${LINENO}' ERR

# Ensure script runs as root BEFORE shifting CLI arguments
if [[ $EUID -ne 0 ]]; then
    echo "Re-executing with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# --- Configuration Variables ---
NODE_ROLE="${NODE_ROLE:-prod}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-brakerbox-p550}"
LAB_SUBNET="${LAB_SUBNET:-10.0.10.0/24}"
NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
FS_LABEL="PGDATA_NVME"
USE_LVM="${USE_LVM:-true}"          # true = LVM with 15% snapshot reserve; false = raw GPT partition
VG_NAME="vg_braker"
LV_NAME="lv_pgdata"
PG_VERSION="${PG_VERSION:-18}"

# SilverStone USB 3.2 Gen 1 RAID 10 Configuration (BigRed-WDR48 & LilBlu-WDB24)
BIGRED_MD="/dev/md/bigred"
BIGRED_LABEL="BIGRED_VAULT"
BIGRED_MOUNT="/mnt/bigred_wdr48"

LILBLU_MD="/dev/md/lilblu"
LILBLU_LABEL="LILBLU_ARCH"
LILBLU_MOUNT="/mnt/lilblu_wdb24"

# --- CLI Argument Parsing ---
WITH_RAID="false"
FORCE_WIPE_NVME="false"
FORCE_WIPE_RAID="false"
FORCE_REBUILD_PG="false"
USE_PKG_CACHE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            NODE_ROLE="${2:-prod}"
            if [[ "$NODE_ROLE" == "bench" ]]; then
                TARGET_HOSTNAME="brakerbench-p550"
            else
                TARGET_HOSTNAME="brakerbox-p550"
            fi
            shift 2
            ;;
        --with-raid)        WITH_RAID="true"; shift ;;
        --force-wipe-nvme)  FORCE_WIPE_NVME="true"; FORCE_REBUILD_PG="true"; shift ;;
        --force-wipe-raid)  FORCE_WIPE_RAID="true"; shift ;;
        --force-rebuild-pg) FORCE_REBUILD_PG="true"; shift ;;
        --use-pkg-cache)    USE_PKG_CACHE="true"; shift ;;
        -h|--help)
            echo "Usage: $0 [--role prod|bench] [--with-raid] [--force-wipe-nvme] [--force-wipe-raid] [--force-rebuild-pg] [--use-pkg-cache]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--role prod|bench] [--with-raid] [--force-wipe-nvme] [--force-wipe-raid] [--force-rebuild-pg] [--use-pkg-cache]"
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

# ==============================================================================
# STAGE 0: Hostname, Sleep Masking, Headless Strip & Sysctl Tuning
# ==============================================================================
log_step "0. Pregame: Hostname, Power States, Headless Strip & Sysctls"

# 0.1 Idempotent Hostname Check
CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" != "$TARGET_HOSTNAME" ]]; then
    hostnamectl set-hostname "$TARGET_HOSTNAME"
    if ! grep -qE "[[:space:]]${TARGET_HOSTNAME}([[:space:]]|$)" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${TARGET_HOSTNAME}/g" /etc/hosts || true
        grep -qE "[[:space:]]${TARGET_HOSTNAME}([[:space:]]|$)" /etc/hosts || printf "127.0.1.1\t%s\n" "$TARGET_HOSTNAME" >> /etc/hosts
    fi
    log_ok "Hostname set to ${TARGET_HOSTNAME} (was ${CURRENT_HOSTNAME})"
else
    log_skip "Hostname is already ${TARGET_HOSTNAME}"
fi

# 0.2 Idempotent Sleep/Suspend Masking (Prevents EIC7700X SoC hangs)
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

# 0.3 Set Default Boot Target to Headless Console
if [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
    systemctl set-default multi-user.target
    log_ok "Boot target set to headless multi-user.target"
else
    log_skip "Boot target is already multi-user.target"
fi

# 0.4 Idempotent Snap & Desktop GUI Bloat Purge (BEFORE apt upgrade to avoid upgrading bloat)
if command -v snap >/dev/null 2>&1 || dpkg -l snapd 2>/dev/null | grep -q "^ii"; then
    for s in firefox snap-store gnome-42-2204 gtk-common-themes core22 bare snapd; do
        snap remove --purge "$s" 2>/dev/null || true
    done
    systemctl stop snapd.socket snapd.service 2>/dev/null || true
    apt-get purge "${APT_FLAGS[@]}" snapd 2>/dev/null || true
    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd /root/snap /home/*/snap
    log_ok "Purged snapd and all snap packages"
else
    log_skip "snapd already purged"
fi

GUI_BLOAT=(
    ubuntu-desktop ubuntu-desktop-minimal gnome-shell gdm3 xwayland
    apport whoopsie unattended-upgrades packagekit modemmanager
)
PURGE_LIST=()
for pkg in "${GUI_BLOAT[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        PURGE_LIST+=("$pkg")
    fi
done

if [[ ${#PURGE_LIST[@]} -gt 0 ]]; then
    apt-get purge "${APT_FLAGS[@]}" "${PURGE_LIST[@]}"
    apt-get autoremove "${APT_FLAGS[@]}" --purge
    apt-get clean
    log_ok "Purged GUI & background bloat: ${PURGE_LIST[*]}"
else
    log_skip "Desktop GUI & telemetry bloat already purged"
fi

# 0.5 Install Core Packages, Perf Tools & SiFive P550 PWM Fan Controller
CORE_PKGS=(
    fancontrol-config-p550-premier
    mdadm lvm2 xfsprogs btrfs-progs parted smartmontools nvme-cli hdparm
    linux-tools-common linux-tools-generic sysstat iotop htop bc rsync time
    jq curl ca-certificates gnupg lsb-release git build-essential
)
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
    apt-get install "${APT_FLAGS[@]}" "linux-tools-$(uname -r)" 2>/dev/null || true
    log_ok "Installed core packages: ${MISSING_PKGS[*]}"
else
    log_skip "All core P550 & storage packages already installed"
fi

# Ensure postgres group exists early for hugetlb_shm_group sysctl
if ! getent group postgres >/dev/null; then
    groupadd -r -g 26 postgres || groupadd -r postgres
fi
PG_GID="$(getent group postgres | cut -d: -f3)"

# 0.6 Idempotent Sysctl Configuration (PMU Counters, 2MB Sv39 HugePages & Writeback)
SYSCTL_FILE="/etc/sysctl.d/90-brakerbox-broker.conf"
SYSCTL_CONTENT="# Allow non-root perf sampling of P550 L1/PL2/CCACHE hardware counters
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0

# 2MB Sv39 HugePages for 8GB PostgreSQL shared_buffers (4608 * 2MB = 9GB)
vm.nr_hugepages = 4608
vm.hugetlb_shm_group = ${PG_GID}

# Broker memory, scheduler stickiness & dirty page writeback tuning
vm.swappiness = 1
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
-kernel.sched_migration_cost_ns = 5000000
-kernel.sched_autogroup_enabled = 0

# Disable NMI watchdog interrupts if supported by kernel architecture
-kernel.nmi_watchdog = 0"

if [[ ! -f "$SYSCTL_FILE" ]] || [[ "$(cat "$SYSCTL_FILE")" != "$SYSCTL_CONTENT" ]]; then
    echo "$SYSCTL_CONTENT" > "$SYSCTL_FILE"
    sysctl --system >/dev/null
    log_ok "Applied P550 PMU, 2MB HugePages & broker sysctl parameters ($SYSCTL_FILE)"
else
    log_skip "Sysctl parameters in $SYSCTL_FILE already up to date"
fi

# ==============================================================================
# STAGE 1 & 2: Verify NVMe Presence & 4Kn Native Sector Size (4096-Byte LBA)
# ==============================================================================
log_step "1 & 2. Verifying NVMe Device ($NVME_DEV) & 4Kn LBA Sector Size"

if [[ ! -b "$NVME_DEV" ]]; then
    log_warn "NVMe device $NVME_DEV not detected! Check PCIe adapter seating and run 'lspci'."
    exit 1
fi

ROOT_DEV="$(findmnt -n -o SOURCE /)"
if [[ "$ROOT_DEV" == "${NVME_DEV}"* ]]; then
    log_warn "Root filesystem (/) is mounted on $NVME_DEV ($ROOT_DEV)! Boot from eMMC before wiping NVMe."
    exit 1
fi

NVME_SHORT="$(basename "$NVME_DEV")"
CURRENT_LBA_SIZE="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"

if [[ "$FORCE_WIPE_NVME" == "true" ]]; then
    log_warn "--force-wipe-nvme requested: stopping PostgreSQL and tearing down NVMe mounts/LVM..."
    systemctl stop postgresql 2>/dev/null || true
    pkill -9 -u postgres 2>/dev/null || true
    umount -f "$MOUNT_POINT" 2>/dev/null || true
    if vgs "$VG_NAME" >/dev/null 2>&1; then
        lvchange -an "$VG_NAME" 2>/dev/null || true
        vgremove -ff -y "$VG_NAME" 2>/dev/null || true
    fi
    pvremove -ff -y "${NVME_DEV}"* 2>/dev/null || true
    wipefs -a "$NVME_DEV"
fi

if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE_NVME" == "false" ]]; then
    log_skip "Existing filesystem labeled '$FS_LABEL' found on $EXISTING_FS_DEV (Logical sector size: ${CURRENT_LBA_SIZE}B)"
else
    if [[ "$CURRENT_LBA_SIZE" == "4096" && "$FORCE_WIPE_NVME" == "false" ]]; then
        log_skip "$NVME_DEV is already formatted to native 4096-byte (4Kn) sectors"
    else
        if lsblk -no MOUNTPOINT "$NVME_DEV" | grep -q "/"; then
            log_warn "$NVME_DEV has active mounts! Unmount before formatting."
            exit 1
        fi

        LBA_4K_INDEX="$(nvme id-ns "$NVME_DEV" | awk '/^lbaf.*lbads:12/ {print $2}' | tr -d ':' | head -n1)"
        if [[ -n "$LBA_4K_INDEX" ]]; then
            echo "Formatting $NVME_DEV to 4096B native sectors (LBA Format Index: $LBA_4K_INDEX, SES=1)..."
            nvme format "$NVME_DEV" -l "$LBA_4K_INDEX" -s 1 --force || nvme format "$NVME_DEV" -l "$LBA_4K_INDEX" --force
            partprobe "$NVME_DEV" || true
            udevadm settle
            sleep 2
            NEW_LBA_SIZE="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
            log_ok "$NVME_DEV hardware formatted to ${NEW_LBA_SIZE}-byte native 4Kn sectors"
        else
            log_warn "Could not auto-detect 4K LBA index on $NVME_DEV; keeping ${CURRENT_LBA_SIZE}B sectors"
        fi
    fi
fi

# ==============================================================================
# STAGE 3A: Partitioning / LVM & XFS Formatting on NVMe + /etc/fstab
# ==============================================================================
log_step "3A. Provisioning NVMe Storage Volume & Mounting XFS ($MOUNT_POINT)"

EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"

if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE_NVME" == "false" ]]; then
    TARGET_BLOCK_DEV="$EXISTING_FS_DEV"
    log_skip "XFS volume '$FS_LABEL' already exists at $TARGET_BLOCK_DEV"
else
    log_warn "Creating fresh storage layout on $NVME_DEV..."
    umount -f "$MOUNT_POINT" 2>/dev/null || true

    if [[ "$USE_LVM" == "true" ]]; then
        vgremove -ff -y "$VG_NAME" 2>/dev/null || true
        pvremove -ff -y "$NVME_DEV" 2>/dev/null || true
        wipefs -a "$NVME_DEV"

        pvcreate --dataalignment 4m -f -y "$NVME_DEV"
        vgcreate -s 4m "$VG_NAME" "$NVME_DEV"
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

FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2"
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
# STAGE 3B: Optional SilverStone USB RAID 10 (BigRed-WDR48 & LilBlu-WDB24)
# Only runs when --with-raid is explicitly passed!
# ==============================================================================
HAS_MD_MOD="false"
if modprobe md_mod 2>/dev/null || [[ -d /sys/module/md_mod ]]; then
    HAS_MD_MOD="true"
else
    modprobe btrfs 2>/dev/null || true
fi

provision_usb_raid10() {
    local array_name="$1"
    local md_dev="$2"
    local fs_label="$3"
    local mount_pt="$4"
    local min_bytes="$5"
    local max_bytes="$6"

    echo "--- Checking $array_name ($fs_label -> $mount_pt) ---"
    if [[ "$HAS_MD_MOD" == "true" ]]; then
        mdadm --assemble --scan 2>/dev/null || true
    else
        btrfs device scan >/dev/null 2>&1 || true
    fi

    local existing_fs
    existing_fs="$(blkid -L "$fs_label" || true)"

    if [[ -n "$existing_fs" && "$FORCE_WIPE_RAID" == "false" ]]; then
        log_skip "$array_name volume '$fs_label' already exists on $existing_fs"
    else
        mapfile -t CANDIDATE_DISKS < <(
            lsblk -b -dn -o NAME,SIZE,ROTA,TYPE | awk -v min="$min_bytes" -v max="$max_bytes" '
                $4 == "disk" && $3 == "1" && $2 >= min && $2 <= max { print "/dev/"$1 }
            '
        )

        if [[ ${#CANDIDATE_DISKS[@]} -ne 4 ]]; then
            log_warn "$array_name skipped: Expected 4 rotational disks in Clear RAID mode, found ${#CANDIDATE_DISKS[@]} (${CANDIDATE_DISKS[*]:-none})."
            return 0
        fi

        umount -f "$mount_pt" 2>/dev/null || true

        if [[ "$HAS_MD_MOD" == "true" ]]; then
            log_warn "Building $array_name mdadm RAID 10 + XFS across 4 drives: ${CANDIDATE_DISKS[*]}"
            mdadm --stop "$md_dev" 2>/dev/null || true
            for d in "${CANDIDATE_DISKS[@]}"; do
                mdadm --zero-superblock "$d" 2>/dev/null || true
                wipefs -a "$d"
            done
            mdadm --create "$md_dev" \
                --level=10 --raid-devices=4 \
                --metadata=1.2 --bitmap=internal --assume-clean \
                --name="$array_name" --run --force \
                "${CANDIDATE_DISKS[@]}"
            udevadm settle
            mkfs.xfs -f -b size=4096 -L "$fs_label" "$md_dev"
            udevadm settle
            log_ok "Created and formatted $array_name ($md_dev) with XFS label '$fs_label'"
        else
            echo "  [INFO] Using native kernel Btrfs RAID 10 (-d raid10 -m raid10) across: ${CANDIDATE_DISKS[*]}"
            for d in "${CANDIDATE_DISKS[@]}"; do
                wipefs -a "$d"
            done
            mkfs.btrfs -f -L "$fs_label" -d raid10 -m raid10 "${CANDIDATE_DISKS[@]}"
            udevadm settle
            btrfs device scan >/dev/null 2>&1 || true
            log_ok "Created native 4-drive Btrfs RAID 10 volume '$fs_label' (${CANDIDATE_DISKS[*]})"
        fi
    fi

    mkdir -p "$mount_pt"
    local dev_node fs_type
    dev_node="$(blkid -L "$fs_label" 2>/dev/null || true)"
    fs_type="$(blkid -s TYPE -o value "$dev_node" 2>/dev/null || echo "btrfs")"
    local raid_fstab
    if [[ "$fs_type" == "btrfs" ]]; then
        raid_fstab="LABEL=${fs_label}  ${mount_pt}  btrfs  defaults,noatime,compress=zstd:1,space_cache=v2,autodefrag,nofail,x-systemd.device-timeout=30s  0  0"
    else
        raid_fstab="LABEL=${fs_label}  ${mount_pt}  xfs  defaults,noatime,nodiratime,nofail,x-systemd.device-timeout=30s  0  2"
    fi

    if ! grep -q "LABEL=${fs_label}" /etc/fstab; then
        echo "$raid_fstab" >> /etc/fstab
        systemctl daemon-reload
        log_ok "Added $fs_label ($mount_pt, $fs_type) to /etc/fstab with nofail protection"
    else
        log_skip "$fs_label already in /etc/fstab"
    fi

    if ! mountpoint -q "$mount_pt"; then
        mount "$mount_pt"
        log_ok "Mounted $mount_pt ($fs_type RAID 10)"
    else
        log_skip "$mount_pt is already mounted"
    fi
}

if [[ "$WITH_RAID" == "true" ]]; then
    log_step "3B. Provisioning SilverStone USB RAID 10 Arrays (BigRed-WDR48 & LilBlu-WDB24)"

    # Lock USB 3.2 mass-storage link power management and rotational mq-deadline scheduler
    cat << 'EOF' > /etc/udev/rules.d/99-brakerrak-usb-raid.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="08", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF
    udevadm control --reload-rules && udevadm trigger

    # BigRed-WDR48: 4x 12TB WD Red Plus (~12,000,138,625,024 bytes -> match 11TB to 13TB)
    provision_usb_raid10 "bigred" "$BIGRED_MD" "$BIGRED_LABEL" "$BIGRED_MOUNT" 11000000000000 13000000000000

    # LilBlu-WDB24: 4x 6TB WD Blue (~6,001,175,126,016 bytes -> match 5.5TB to 6.5TB)
    provision_usb_raid10 "lilblu" "$LILBLU_MD" "$LILBLU_LABEL" "$LILBLU_MOUNT" 5500000000000 6500000000000

    if [[ "$HAS_MD_MOD" == "true" ]]; then
        mkdir -p /etc/mdadm
        MDADM_SCAN="$(mdadm --detail --scan)"
        if [[ -n "$MDADM_SCAN" ]] && ! grep -qF "$MDADM_SCAN" /etc/mdadm/mdadm.conf 2>/dev/null; then
            sed -i '/^ARRAY /d' /etc/mdadm/mdadm.conf 2>/dev/null || true
            echo "$MDADM_SCAN" >> /etc/mdadm/mdadm.conf
            update-initramfs -u
            log_ok "Updated /etc/mdadm/mdadm.conf and initramfs"
        else
            log_skip "/etc/mdadm/mdadm.conf already contains active array definitions"
        fi
    fi
else
    log_step "3B. SilverStone USB RAID Provisioning Skipped (Pass --with-raid to enable)"
fi

# ==============================================================================
# STAGE 4: Zero-Cache Forge of PostgreSQL $PG_VERSION (PGDG deb-src + perf stat)
# ==============================================================================
log_step "4. Forging PostgreSQL ${PG_VERSION} (PGDG riscv64 + SiFive P550 Zba/Zbb + perf stat)"

PGDG_KEY="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
LOCAL_LIST="/etc/apt/sources.list.d/drewv-local-pgdg.list"
CODENAME="$(lsb_release -cs)"
LOCAL_REPO_DIR="/opt/drewv-pgdg-riscv64/debs"
NVME_CACHE_DIR="${MOUNT_POINT}/.pkg-cache/pgdg-riscv64"
BUILD_DIR="/opt/drewv-pgdg-riscv64/build"
TELEMETRY_DIR="${MOUNT_POINT}/telemetry/forge"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$TELEMETRY_DIR" "$LOCAL_REPO_DIR"

if [[ ! -f "$PGDG_KEY" ]]; then
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o "$PGDG_KEY"
    log_ok "Downloaded PGDG signing key"
else
    log_skip "PGDG signing key already present"
fi

EXPECTED_REPO="# DREW-V Labs PGDG riscv64 Source & Binary Channels
deb [arch=riscv64 signed-by=${PGDG_KEY}] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main
deb-src [signed-by=${PGDG_KEY}] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main ${PG_VERSION}"

if [[ ! -f "$PGDG_LIST" ]] || [[ "$(cat "$PGDG_LIST")" != "$EXPECTED_REPO" ]]; then
    echo "$EXPECTED_REPO" > "$PGDG_LIST"
    rm -f "$LOCAL_LIST" 2>/dev/null || true
    apt-get update -q
    log_ok "Configured PGDG binary + deb-src repositories for ${CODENAME}-pgdg"
else
    log_skip "PGDG repository already configured"
fi

update_local_pgdg_repo() {
    (cd "$LOCAL_REPO_DIR" && dpkg-scanpackages . /dev/null > Packages 2>/dev/null)
    echo "deb [trusted=yes] file://${LOCAL_REPO_DIR} ./" > "$LOCAL_LIST"
    apt-get update -o Acquire::GzipIndexes=false -q
}

if dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 && [[ "$FORCE_REBUILD_PG" == "false" ]]; then
    log_skip "postgresql-${PG_VERSION} is already installed (pass --force-rebuild-pg to recompile from scratch)"
else
    # Handle cache seeding vs. zero-cache purge only when installing or rebuilding
    if [[ "$FORCE_REBUILD_PG" == "true" ]]; then
        log_warn "Purging existing postgresql-${PG_VERSION} installation and .deb caches for zero-cache forge..."
        systemctl stop postgresql 2>/dev/null || true
        apt-get purge "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" 2>/dev/null || true
        rm -rf "${LOCAL_REPO_DIR:?}"/postgresql-${PG_VERSION}_*.deb "${LOCAL_REPO_DIR:?}"/postgresql-client-${PG_VERSION}_*.deb "${NVME_CACHE_DIR:?}" "${BUILD_DIR:?}" "$LOCAL_LIST" 2>/dev/null || true
        apt-get update -q
    elif [[ "$USE_PKG_CACHE" == "true" ]]; then
        mkdir -p "$NVME_CACHE_DIR"
        if ! ls "${LOCAL_REPO_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1 && \
           ls "${NVME_CACHE_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1; then
            cp -a "${NVME_CACHE_DIR}"/*.deb "$LOCAL_REPO_DIR/"
            log_ok "Restored cached P550 PostgreSQL ${PG_VERSION} .deb packages from NVMe (--use-pkg-cache)"
        fi
    else
        # Default zero-cache policy for fresh installs: do not use cached PG18 debs
        rm -rf "${LOCAL_REPO_DIR:?}"/postgresql-${PG_VERSION}_*.deb "${LOCAL_REPO_DIR:?}"/postgresql-client-${PG_VERSION}_*.deb "$LOCAL_LIST" 2>/dev/null || true
    fi

    if [[ "$USE_PKG_CACHE" == "true" ]] && ls "${LOCAL_REPO_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1; then
        update_local_pgdg_repo
        log_skip "Using cached P550-optimized postgresql-${PG_VERSION} .deb packages in $LOCAL_REPO_DIR"
    else
        log_warn "Compiling zero-cache P550-tuned postgresql-${PG_VERSION} from PGDG deb-src with perf telemetry..."
        apt-get install "${APT_FLAGS[@]}" dpkg-dev debhelper build-essential liburing-dev libzstd-dev liblz4-dev

        unset CCACHE_DIR CCACHE_PREFIX || true
        mkdir -p "$BUILD_DIR"
        chmod 755 /opt/drewv-pgdg-riscv64 "$LOCAL_REPO_DIR"
        chown -R _apt:root "$BUILD_DIR"
        chmod 775 "$BUILD_DIR"

        P550_FLAGS="-O3 -pipe -march=rv64gc_zba_zbb"
        if gcc -O3 -pipe -march=rv64gc_zba_zbb -mcpu=sifive-p550 -mtune=sifive-p550 -x c -c /dev/null -o /dev/null 2>/dev/null; then
            P550_FLAGS="-O3 -pipe -march=rv64gc_zba_zbb -mcpu=sifive-p550 -mtune=sifive-p550"
        fi
        log_ok "Selected GCC P550 optimization flags: ${P550_FLAGS}"

        export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
        export DEB_CFLAGS_APPEND="$P550_FLAGS"
        export DEB_CXXFLAGS_APPEND="$P550_FLAGS"

        # 1. Build PGDG postgresql-common (provides postgresql-common-dev >= 262) if not yet installed
        if ! dpkg -s postgresql-common-dev >/dev/null 2>&1; then
            rm -rf "${BUILD_DIR:?}"/*
            chown _apt:root "$BUILD_DIR"
            cd "$BUILD_DIR"
            apt-get build-dep "${APT_FLAGS[@]}" postgresql-common
            apt-get source --compile postgresql-common
            mv -f ./*.deb "$LOCAL_REPO_DIR/"
            update_local_pgdg_repo
            apt-get install "${APT_FLAGS[@]}" postgresql-common postgresql-common-dev
        fi

        # 2. Zero-cache build of postgresql-18 wrapped in perf stat hardware counters
        rm -rf "${BUILD_DIR:?}"/*
        chown _apt:root "$BUILD_DIR"
        cd "$BUILD_DIR"
        apt-get build-dep "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}"

        PERF_CSV="${TELEMETRY_DIR}/pg${PG_VERSION}-forge-perf-${RUN_TS}.csv"
        PERF_TXT="${TELEMETRY_DIR}/pg${PG_VERSION}-forge-perf-${RUN_TS}.txt"
        META_JSON="${TELEMETRY_DIR}/pg${PG_VERSION}-forge-meta-${RUN_TS}.json"
        PERF_EVENTS="task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,L1-icache-loads,L1-icache-load-misses,dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses"

        # Resolve real perf binary directly (bypasses Ubuntu wrapper version check on custom vendor kernels)
        PERF_BIN="$(command -v perf || true)"
        if [[ -n "$PERF_BIN" ]] && ! "$PERF_BIN" stat -e cycles true >/dev/null 2>&1; then
            PERF_BIN="$(find /usr/lib/linux-tools-* -name perf -type f 2>/dev/null | sort -V | tail -n1 || true)"
        fi

        START_EPOCH="$(date +%s.%N)"
        if [[ -n "$PERF_BIN" ]] && "$PERF_BIN" stat -e cycles true >/dev/null 2>&1; then
            log_ok "Capturing SiFive P550 PMU counters via ${PERF_BIN} stat -> ${PERF_CSV}"
            "$PERF_BIN" stat -x, -o "$PERF_CSV" -e "$PERF_EVENTS" \
                apt-get source --compile "postgresql-${PG_VERSION}"
            awk -F, 'NF>=3 {printf "%-28s : %18s %s\n", $3, $1, $2}' "$PERF_CSV" > "$PERF_TXT"
        else
            log_warn "Kernel perf binary unavailable; recording execution metrics with /usr/bin/time -> ${PERF_TXT}"
            /usr/bin/time -v -o "$PERF_TXT" apt-get source --compile "postgresql-${PG_VERSION}"
        fi
        END_EPOCH="$(date +%s.%N)"
        WALL_SECS="$(echo "${END_EPOCH} - ${START_EPOCH}" | bc -l)"

        mv -f ./*.deb "$LOCAL_REPO_DIR/"
        if [[ "$USE_PKG_CACHE" == "true" ]]; then
            mkdir -p "$NVME_CACHE_DIR"
            cp -a "${LOCAL_REPO_DIR}"/*.deb "$NVME_CACHE_DIR/" || true
        fi
        update_local_pgdg_repo

        cat << EOF > "$META_JSON"
{
  "hostname": "${TARGET_HOSTNAME}",
  "role": "${NODE_ROLE}",
  "soc": "ESWIN EIC7700X (4x SiFive P550 @ 1.4GHz)",
  "isa_flags": "${P550_FLAGS}",
  "pg_version": "${PG_VERSION}",
  "zero_cache_build": $([[ "$USE_PKG_CACHE" == "false" ]] && echo "true" || echo "false"),
  "build_threads": $(nproc),
  "wall_clock_seconds": $(printf "%.3f" "$WALL_SECS"),
  "timestamp_utc": "${RUN_TS}",
  "perf_csv": "${PERF_CSV}",
  "perf_summary": "${PERF_TXT}"
}
EOF
        log_ok "Compiled postgresql-${PG_VERSION} from source in $(printf "%.2f" "$WALL_SECS")s (Telemetry: $META_JSON)"
    fi

    apt-get install "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
    log_ok "Installed postgresql-${PG_VERSION}"
fi

# ==============================================================================
# STAGE 5: Relocating Cluster to SN850X & Tuning for SiFive P550 32GB
# ==============================================================================
log_step "5. Relocating Cluster to $MOUNT_POINT & Applying SiFive P550 Tuning"

NVME_PG_ROOT="${MOUNT_POINT}/postgresql"
NVME_PG_DATA="${NVME_PG_ROOT}/${PG_VERSION}/main"
DEFAULT_PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
DROPIN_CONF="${CONF_DIR}/99-brakerbox-p550.conf"
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

# Remove legacy typo config file if present
rm -f "${CONF_DIR}/99-brackerbox-p550.conf"

# 5.1 Idempotent Data Directory Migration
if [[ -f "${NVME_PG_DATA}/PG_VERSION" && "$FORCE_WIPE_NVME" == "false" && "$FORCE_REBUILD_PG" == "false" ]]; then
    log_skip "PostgreSQL cluster already initialized on NVMe at ${NVME_PG_DATA}"
else
    echo "Migrating initial PostgreSQL ${PG_VERSION} cluster to ${NVME_PG_DATA}..."
    systemctl stop postgresql
    rm -rf "${NVME_PG_DATA:?}"
    mkdir -p "$NVME_PG_DATA"
    chown -R postgres:postgres "$NVME_PG_ROOT"
    chmod 700 "$NVME_PG_DATA"

    rsync -a "${DEFAULT_PG_DATA}/" "${NVME_PG_DATA}/"
    chown -R postgres:postgres "$NVME_PG_ROOT"
    log_ok "Synced clean cluster from $DEFAULT_PG_DATA to $NVME_PG_DATA"
fi

# 5.2 Auto-verify io_uring support in PostgreSQL binary & kernel
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin/postgres"
IO_METHOD="worker"
if [[ -x "$PG_BIN" ]] && ldd "$PG_BIN" | grep -q "liburing"; then
    if [[ "$(sysctl -n kernel.io_uring_disabled 2>/dev/null || echo 0)" == "0" ]]; then
        IO_METHOD="io_uring"
    fi
fi
log_ok "Selected PostgreSQL 18 Async I/O method: io_method = ${IO_METHOD}"

# 5.3 Idempotent Drop-In Tuning File & Lab Subnet pg_hba.conf Rule
mkdir -p "$CONF_DIR"
DESIRED_PG_CONF="# DREW-V Labs: SiFive HiFive Premier P550 (32GB LPDDR5 + WD_BLACK SN850X 4Kn)
data_directory = '${NVME_PG_DATA}'
listen_addresses = '*'
max_connections = 250

# 32GB LPDDR5 Memory Allocation (Backed by 2MB Sv39 HugePages)
shared_buffers = 8GB
effective_cache_size = 24GB
work_mem = 32MB
maintenance_work_mem = 2GB
huge_pages = try

# SiFive P550 4-Core (3-Wide Out-of-Order, RVA20+Zba/Zbb) Tuning
jit = off
max_worker_processes = 8
max_parallel_workers = 4
max_parallel_workers_per_gather = 2
max_parallel_maintenance_workers = 2

# WD_BLACK SN850X 4Kn PCIe Gen3 x4 & PostgreSQL 18 Async I/O
io_method = ${IO_METHOD}
effective_io_concurrency = 200
maintenance_io_concurrency = 100
random_page_cost = 1.1
track_io_timing = on
track_wal_io_timing = on

# WAL, Group Commit & Checkpoints
wal_compression = zstd
wal_buffers = 64MB
min_wal_size = 2GB
max_wal_size = 16GB
checkpoint_completion_target = 0.9
commit_delay = 20
commit_siblings = 8"

NEED_PG_RESTART="false"
if [[ ! -f "$DROPIN_CONF" ]] || [[ "$(cat "$DROPIN_CONF")" != "$DESIRED_PG_CONF" ]]; then
    echo "$DESIRED_PG_CONF" > "$DROPIN_CONF"
    chown -R postgres:postgres "$CONF_DIR"
    NEED_PG_RESTART="true"
    log_ok "Wrote tuning configuration to $DROPIN_CONF"
else
    log_skip "PostgreSQL configuration $DROPIN_CONF is already up to date"
fi

if [[ -f "$PG_HBA" ]] && ! grep -qF "$LAB_SUBNET" "$PG_HBA"; then
    printf "\n# DREW-V Labs BrakerRak Subnet Access\nhost    all             all             %s            scram-sha-256\n" "$LAB_SUBNET" >> "$PG_HBA"
    NEED_PG_RESTART="true"
    log_ok "Added lab subnet ($LAB_SUBNET) rule to $PG_HBA"
else
    log_skip "Lab subnet ($LAB_SUBNET) already authorized in $PG_HBA"
fi

# 5.4 Ensure Service is Running & Healthy
if ! systemctl is-active --quiet postgresql || [[ "$NEED_PG_RESTART" == "true" ]]; then
    systemctl enable postgresql >/dev/null 2>&1 || true
    systemctl restart postgresql
    log_ok "PostgreSQL ${PG_VERSION} service started/restarted"
else
    log_skip "PostgreSQL ${PG_VERSION} is already active and running current config"
fi

# 5.5 Optional Warm/Cold Tablespace Provisioning (ONLY if --with-raid is passed)
if [[ "$WITH_RAID" == "true" ]]; then
    for raid_mp in "$BIGRED_MOUNT" "$LILBLU_MOUNT"; do
        if mountpoint -q "$raid_mp"; then
            ts_dir="${raid_mp}/postgresql/tablespaces"
            mkdir -p "$ts_dir"
            # Disable Btrfs Copy-on-Write (+C) on tablespace dir before PG writes heap files
            chattr +C "$ts_dir" 2>/dev/null || true
            chown -R postgres:postgres "${raid_mp}/postgresql"
            chmod 700 "$ts_dir"
        fi
    done

    if mountpoint -q "$BIGRED_MOUNT"; then
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_tablespace WHERE spcname = 'ts_bigred_warm';" | grep -q 1; then
            rm -rf "${BIGRED_MOUNT}/postgresql/tablespaces"/PG_* 2>/dev/null || true
            sudo -u postgres psql -c "CREATE TABLESPACE ts_bigred_warm LOCATION '${BIGRED_MOUNT}/postgresql/tablespaces';"
        fi
        log_ok "Verified Warm Tablespace: ts_bigred_warm (${BIGRED_MOUNT}/postgresql/tablespaces)"
    fi

    if mountpoint -q "$LILBLU_MOUNT"; then
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_tablespace WHERE spcname = 'ts_lilblu_cold';" | grep -q 1; then
            rm -rf "${LILBLU_MOUNT}/postgresql/tablespaces"/PG_* 2>/dev/null || true
            sudo -u postgres psql -c "CREATE TABLESPACE ts_lilblu_cold LOCATION '${LILBLU_MOUNT}/postgresql/tablespaces';"
        fi
        log_ok "Verified Cold Tablespace: ts_lilblu_cold (${LILBLU_MOUNT}/postgresql/tablespaces)"
    fi
fi

# ==============================================================================
# STAGE 6: Post-Flight Verification Summary
# ==============================================================================
log_step "6. Post-Flight Verification Summary"

ACTIVE_DATA_DIR="$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null || echo "N/A")"
ACTIVE_IO_METHOD="$(sudo -u postgres psql -tAc "SHOW io_method;" 2>/dev/null || echo "N/A")"
ACTIVE_BUFFERS="$(sudo -u postgres psql -tAc "SHOW shared_buffers;" 2>/dev/null || echo "N/A")"
HUGEPAGES_FREE="$(awk '/HugePages_Free:/ {print $2}' /proc/meminfo)"
HUGEPAGES_TOTAL="$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo)"
FINAL_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"

printf "  • Hostname           : %s (Role: %s)\n" "$(hostname)" "$NODE_ROLE"
printf "  • Kernel / Arch      : %s (%s)\n" "$(uname -r)" "$(uname -m)"
printf "  • NVMe LBA Block Sz  : %s bytes\n" "$FINAL_LBA"
printf "  • Hot NVMe Mount     : %s\n" "$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT" || echo "Not Mounted")"
printf "  • Warm RAID (BigRed) : %s\n" "$(findmnt -n -o SOURCE,TARGET,FSTYPE "$BIGRED_MOUNT" 2>/dev/null || echo "Skipped / Not Mounted")"
printf "  • Cold RAID (LilBlu) : %s\n" "$(findmnt -n -o SOURCE,TARGET,FSTYPE "$LILBLU_MOUNT" 2>/dev/null || echo "Skipped / Not Mounted")"
printf "  • PG Data Directory  : %s\n" "$ACTIVE_DATA_DIR"
printf "  • PG 18 Async I/O    : io_method = %s\n" "$ACTIVE_IO_METHOD"
printf "  • PG Shared Buffers  : %s (HugePages in use: %d / %d)\n" "$ACTIVE_BUFFERS" "$((HUGEPAGES_TOTAL - HUGEPAGES_FREE))" "$HUGEPAGES_TOTAL"

echo ""
log_ok "${TARGET_HOSTNAME} PostgreSQL ${PG_VERSION} Forge Complete!"
echo ""
