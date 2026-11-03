#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive HiFive Premier JH7110 Target Forge Script
# Path: drewv-labs/brakerrak/targets/starfive-jh7110/forge.sh
# Architecture: RVA20 (RV64GC + Zba/Zbb) | 4x JH7110 3-Wide OoO | 32GB LPDDR5
#
# Usage:
#   ./forge.sh                                    # Two-Pass idempotent build (reads ~/.brakerrak/node.env if present)
#   ./forge.sh --config /path/to/node.env         # Explicitly load a specific declarative config file
#   ./forge.sh --role databroker|databench        # Select role persona (aliases: prod|bench)
#   ./forge.sh --with-raid                        # Provision/mount arrays defined in RAID_ARRAYS_JSON
#   ./forge.sh --with-mqtt                        # Enable Eclipse Mosquitto MQTT broker on NVMe
#   ./forge.sh --with-nfs                         # Export RAID vaults (or NVMe nfs_vault if no RAID) over NFSv4
#   ./forge.sh --force-wipe-nvme                  # Destructively 4Kn format NVMe & zero-cache rebuild PG18
#   ./forge.sh --with-raid --force-wipe-raid      # Destructively rebuild USB RAID10 arrays
#   ./forge.sh --force-rebuild-pg                 # Force zero-cache PGDG deb-src recompile with perf stat
#   ./forge.sh --use-pkg-cache                    # Restore/use cached JH7110 .deb packages on NVMe
# ==============================================================================

set -Eeuo pipefail

trap_err() {
    local exit_code=$?
    local line_no=$1
    printf "\n\033[1;31m[FATAL] Forge failed at line %s (exit code: %s)\033[0m\n" "$line_no" "$exit_code" >&2
    printf "\033[1;31m[CMD]   %s\033[0m\n" "${BASH_COMMAND}" >&2
    exit "$exit_code"
}
trap 'trap_err ${LINENO}' ERR

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        echo "Re-executing with sudo..."
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[FATAL] When piping via curl, run with 'sudo bash': curl -fsSL ... | sudo bash" >&2
        exit 1
    fi
fi

# ==============================================================================
# DREW-V Labs // Unified Two-Pass Declarative Config Loader (~/.brakerrak/node.env)
# ==============================================================================
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
BRAKER_CONF_DIR="${REAL_HOME}/.brakerrak"
USER_NODE_ENV="${BRAKER_CONF_DIR}/node.env"
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$PWD"
fi

# 1. Hardware-Agnostic Defaults (Pass 1 Baseline — Overridden by node.env or CLI flags)
TARGET_TAG="vf2"
NODE_ROLE="${NODE_ROLE:-databench}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-brakerbench-vf2}"
ADMIN_USER="${ADMIN_USER:-${REAL_USER}}"
LAB_SUBNET="${LAB_SUBNET:-127.0.0.1/32}"

ISA_MARCH="${ISA_MARCH:-rv64gc_zba_zbb}"
CPU_MTUNE="${CPU_MTUNE:-sifive-p550}"
KERNEL_HUGEPAGES_2MB="${KERNEL_HUGEPAGES_2MB:-4608}"

NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
NVME_TARGET_LBA_BYTES="${NVME_TARGET_LBA_BYTES:-4096}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
FS_LABEL="${FS_LABEL:-PGDATA_NVME}"
USE_LVM="${USE_LVM:-true}"
VG_NAME="${VG_NAME:-vg_braker}"
LV_NAME="${LV_NAME:-lv_pgdata}"
LV_PCT="${LV_PCT:-85%VG}"

WITH_RAID="${WITH_RAID:-false}"
RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"

PG_VERSION="${PG_VERSION:-18}"
PG_MAX_CONN="${PG_MAX_CONN:-250}"
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-8GB}"
PG_EFFECTIVE_CACHE_SIZE="${PG_EFFECTIVE_CACHE_SIZE:-24GB}"
PG_WORK_MEM="${PG_WORK_MEM:-32MB}"
PG_MAINT_WORK_MEM="${PG_MAINT_WORK_MEM:-2GB}"
PG_IO_CONCURRENCY="${PG_IO_CONCURRENCY:-200}"
PG_MAINT_IO_CONCURRENCY="${PG_MAINT_IO_CONCURRENCY:-100}"
PG_PREBUILT_DEB_URL="${PG_PREBUILT_DEB_URL:-}"

ENABLE_MQTT_BROKER="${ENABLE_MQTT_BROKER:-false}"
MQTT_PORT="${MQTT_PORT:-1883}"
ENABLE_NFS_SERVER="${ENABLE_NFS_SERVER:-false}"
NVME_NFS_EXPORT="${NVME_NFS_EXPORT:-}"

SHARE_ORT_SNAPSHOT="${SHARE_ORT_SNAPSHOT:-false}"
ORT_TELEMETRY_ENDPOINT="${ORT_TELEMETRY_ENDPOINT:-https://telemetry.drewv-labs.io/v1/ort}"

FORCE_WIPE_NVME="false"
FORCE_WIPE_RAID="false"
FORCE_REBUILD_PG="false"
USE_PKG_CACHE="false"

# 2. Source ~/.brakerrak/node.env (Pass 2) or Repo node.env if present
LOADED_ENV_FILE=""
FORGE_PASS="1"
if [[ -f "${USER_NODE_ENV}" ]]; then
    echo "[CONF] Pass 2 Detected: Loading user config from ${USER_NODE_ENV}"
    # shellcheck disable=SC1090
    source "${USER_NODE_ENV}"
    LOADED_ENV_FILE="${USER_NODE_ENV}"
    FORGE_PASS="2"
elif [[ -f "${SCRIPT_DIR}/node.env" ]]; then
    echo "[CONF] Loading repo config from ${SCRIPT_DIR}/node.env"
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/node.env"
    LOADED_ENV_FILE="${SCRIPT_DIR}/node.env"
fi

# 3. CLI Argument Overrides (Highest Precedence)
CLI_WITH_RAID=""
CLI_ENABLE_MQTT=""
CLI_ENABLE_NFS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            if [[ -f "${2:-}" ]]; then
                # shellcheck disable=SC1090
                source "$2"
                LOADED_ENV_FILE="$2"
                FORGE_PASS="2"
            else
                echo "Config file not found: ${2:-}" >&2
                exit 1
            fi
            shift 2
            ;;
        --role)
            NODE_ROLE="${2:-databroker}"
            shift 2
            ;;
        --with-raid)        CLI_WITH_RAID="true"; shift ;;
        --with-mqtt)        CLI_ENABLE_MQTT="true"; shift ;;
        --with-nfs)         CLI_ENABLE_NFS="true"; shift ;;
        --force-wipe-nvme)  FORCE_WIPE_NVME="true"; FORCE_REBUILD_PG="true"; shift ;;
        --force-wipe-raid)  FORCE_WIPE_RAID="true"; shift ;;
        --force-rebuild-pg) FORCE_REBUILD_PG="true"; shift ;;
        --use-pkg-cache)    USE_PKG_CACHE="true"; shift ;;
        -h|--help)
            echo "Usage: $0 [--config file.env] [--role databroker|databench] [--with-raid] [--with-mqtt] [--with-nfs] [--force-wipe-nvme] [--force-wipe-raid] [--force-rebuild-pg] [--use-pkg-cache]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Normalize NODE_ROLE aliases and load Role Persona defaults
case "$NODE_ROLE" in
    prod|broker|databroker)
        NODE_ROLE="databroker"
        TARGET_HOSTNAME="brakerbox-${TARGET_TAG}"
        ENABLE_MQTT_BROKER="true"
        ENABLE_NFS_SERVER="true"
        ;;
    bench|databench)
        NODE_ROLE="databench"
        TARGET_HOSTNAME="brakerbench-${TARGET_TAG}"
        WITH_RAID="false"
        ENABLE_MQTT_BROKER="false"
        ENABLE_NFS_SERVER="false"
        ;;
    *)
        echo "Unknown role: $NODE_ROLE (expected: databroker or databench)" >&2
        exit 1
        ;;
esac

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd || echo "")"
if [[ -n "$REPO_ROOT" && -f "${REPO_ROOT}/roles/${NODE_ROLE}.env" ]]; then
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/roles/${NODE_ROLE}.env"
fi
if [[ -n "$LOADED_ENV_FILE" && -f "$LOADED_ENV_FILE" ]]; then
    # Re-apply explicit user config values on top of role defaults
    # shellcheck disable=SC1090
    source "$LOADED_ENV_FILE"
    # Re-normalize NODE_ROLE if node.env used legacy prod/bench string
    [[ "$NODE_ROLE" == "prod" || "$NODE_ROLE" == "broker" ]] && NODE_ROLE="databroker"
    [[ "$NODE_ROLE" == "bench" ]] && NODE_ROLE="databench"
fi
[[ -n "$CLI_WITH_RAID" ]] && WITH_RAID="$CLI_WITH_RAID"
[[ -n "$CLI_ENABLE_MQTT" ]] && ENABLE_MQTT_BROKER="$CLI_ENABLE_MQTT"
[[ -n "$CLI_ENABLE_NFS" ]] && ENABLE_NFS_SERVER="$CLI_ENABLE_NFS"

NVME_NFS_EXPORT="${NVME_NFS_EXPORT:-${MOUNT_POINT}/nfs_vault}"

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_step() { printf "\n\033[1;36m=== [%s] %s ===\033[0m\n" "$(date +%H:%M:%S)" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s (already configured)\n" "$1"; }
log_warn() { printf "\033[1;31m[WARN]\033[0m %s\n" "$1"; }

# ==============================================================================
# STAGE 0: Hostname, Sleep Masking, Headless Strip & Sysctl Tuning
# ==============================================================================
log_step "0. Pregame: Hostname (${TARGET_HOSTNAME}), Power States, Headless Strip & Sysctls"

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

if [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
    systemctl set-default multi-user.target
    log_ok "Boot target set to headless multi-user.target"
else
    log_skip "Boot target is already multi-user.target"
fi

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

CORE_PKGS=(
    
    mdadm lvm2 xfsprogs btrfs-progs parted smartmontools nvme-cli hdparm
    linux-perf parted sysstat iotop htop bc rsync time
    jq curl ca-certificates gnupg lsb-release git build-essential
)
MISSING_PKGS=()
for pkg in "${CORE_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    apt-get -o DPkg::Lock::Timeout=120 update -q
    apt-get upgrade "${APT_FLAGS[@]}"
    apt-get install "${APT_FLAGS[@]}" "${MISSING_PKGS[@]}"
    apt-get install "${APT_FLAGS[@]}" "linux-tools-$(uname -r)" 2>/dev/null || true
    log_ok "Installed core packages: ${MISSING_PKGS[*]}"
else
    log_skip "All core JH7110 & storage packages already installed"
fi

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$RAID_ARRAYS_JSON"; then
    log_warn "RAID_ARRAYS_JSON is not a valid JSON array! Check your configuration."
    exit 1
fi
RAID_ARRAY_COUNT="$(jq -r 'length' <<< "$RAID_ARRAYS_JSON")"
if [[ "$WITH_RAID" == "true" && "$RAID_ARRAY_COUNT" -eq 0 ]]; then
    log_warn "WITH_RAID=true was requested, but RAID_ARRAYS_JSON is empty ([]). Disabling RAID provisioning."
    WITH_RAID="false"
fi

if ! getent group postgres >/dev/null; then
    groupadd -r -g 26 postgres || groupadd -r postgres
fi
PG_GID="$(getent group postgres | cut -d: -f3)"

SYSCTL_FILE="/etc/sysctl.d/90-brakerbox-broker.conf"
SYSCTL_CONTENT="# Allow non-root perf sampling of JH7110 L1/PL2/CCACHE hardware counters
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0

# 2MB Sv39 HugePages for PostgreSQL shared_buffers (${KERNEL_HUGEPAGES_2MB} * 2MB)
vm.nr_hugepages = ${KERNEL_HUGEPAGES_2MB}
vm.hugetlb_shm_group = ${PG_GID}

# Broker memory, scheduler stickiness & dirty page writeback tuning
vm.swappiness = 1
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
-kernel.sched_migration_cost_ns = 5000000
-kernel.sched_autogroup_enabled = 0

# Disable NMI watchdog interrupts if supported by kernel architecture

if [[ ! -f "$SYSCTL_FILE" ]] || [[ "$(cat "$SYSCTL_FILE")" != "$SYSCTL_CONTENT" ]]; then
    echo "$SYSCTL_CONTENT" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    log_ok "Applied JH7110 PMU, 2MB HugePages & broker sysctl parameters ($SYSCTL_FILE)"
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
    for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
    wipefs -af "$NVME_DEV"
    partprobe "$NVME_DEV" 2>/dev/null || true
fi

if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE_NVME" == "false" ]]; then
    log_skip "Existing filesystem labeled '$FS_LABEL' found on $EXISTING_FS_DEV (Logical sector size: ${CURRENT_LBA_SIZE}B)"
else
    if [[ "$CURRENT_LBA_SIZE" == "$NVME_TARGET_LBA_BYTES" && "$FORCE_WIPE_NVME" == "false" ]]; then
        log_skip "$NVME_DEV is already formatted to native ${NVME_TARGET_LBA_BYTES}-byte (4Kn) sectors"
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
        for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
    wipefs -af "$NVME_DEV"
    partprobe "$NVME_DEV" 2>/dev/null || true

        pvcreate --dataalignment 4m -f -y "$NVME_DEV"
        vgcreate -s 4m "$VG_NAME" "$NVME_DEV"
        lvcreate -l "$LV_PCT" -n "$LV_NAME" -y "$VG_NAME"
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_ok "Created LVM Logical Volume $TARGET_BLOCK_DEV (${LV_PCT} with snapshot reserve)"
    else
        for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
    wipefs -af "$NVME_DEV"
    partprobe "$NVME_DEV" 2>/dev/null || true
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
# STAGE 3B: Dynamic USB RAID 10 Provisioning (Driven by RAID_ARRAYS_JSON)
# ==============================================================================
HAS_MD_MOD="false"
if modprobe md_mod 2>/dev/null || [[ -d /sys/module/md_mod ]]; then
    HAS_MD_MOD="true"
else
    modprobe btrfs 2>/dev/null || true
fi

provision_usb_raid10() {
    local display_name="$1"
    local array_id="$2"
    local array_type="$3"
    local md_dev="$4"
    local fs_label="$5"
    local mount_pt="$6"
    local expected_disks="$7"
    local min_bytes="$8"
    local max_bytes="$9"

    echo "--- Checking ${display_name} [${array_type^^}] (${fs_label} -> ${mount_pt}) ---"
    if [[ "$HAS_MD_MOD" == "true" ]]; then
        mdadm --assemble --scan 2>/dev/null || true
    else
        btrfs device scan >/dev/null 2>&1 || true
    fi

    local existing_fs
    existing_fs="$(blkid -L "$fs_label" || true)"

    if [[ -n "$existing_fs" && "$FORCE_WIPE_RAID" == "false" ]]; then
        log_skip "${display_name} (${array_type}) volume '${fs_label}' already exists on ${existing_fs}"
    else
        mapfile -t CANDIDATE_DISKS < <(
            lsblk -b -dn -o NAME,SIZE,ROTA,TYPE | awk -v min="$min_bytes" -v max="$max_bytes" '
                $4 == "disk" && $3 == "1" && $2 >= min && $2 <= max { print "/dev/"$1 }
            '
        )

        if [[ ${#CANDIDATE_DISKS[@]} -ne "$expected_disks" ]]; then
            log_warn "${display_name} skipped: Expected ${expected_disks} rotational disks in Clear RAID mode, found ${#CANDIDATE_DISKS[@]} (${CANDIDATE_DISKS[*]:-none})."
            return 0
        fi

        umount -f "$mount_pt" 2>/dev/null || true

        if [[ "$HAS_MD_MOD" == "true" ]]; then
            log_warn "Building ${display_name} mdadm RAID 10 + XFS across ${expected_disks} drives: ${CANDIDATE_DISKS[*]}"
            mdadm --stop "$md_dev" 2>/dev/null || true
            for d in "${CANDIDATE_DISKS[@]}"; do
                mdadm --zero-superblock "$d" 2>/dev/null || true
                wipefs -a "$d"
            done
            mdadm --create "$md_dev" \
                --level=10 --raid-devices="$expected_disks" \
                --metadata=1.2 --bitmap=internal --assume-clean \
                --name="$array_id" --run --force \
                "${CANDIDATE_DISKS[@]}"
            udevadm settle
            mkfs.xfs -f -b size=4096 -L "$fs_label" "$md_dev"
            udevadm settle
            log_ok "Created and formatted ${display_name} (${md_dev}) with XFS label '${fs_label}'"
        else
            echo "  [INFO] Using native kernel Btrfs RAID 10 (-d raid10 -m raid10) across: ${CANDIDATE_DISKS[*]}"
            for d in "${CANDIDATE_DISKS[@]}"; do
                wipefs -a "$d"
            done
            mkfs.btrfs -f -L "$fs_label" -d raid10 -m raid10 "${CANDIDATE_DISKS[@]}"
            udevadm settle
            btrfs device scan >/dev/null 2>&1 || true
            log_ok "Created native ${expected_disks}-drive Btrfs RAID 10 volume '${fs_label}' (${CANDIDATE_DISKS[*]})"
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
        log_ok "Added ${fs_label} (${mount_pt}, ${fs_type}) to /etc/fstab with nofail protection"
    else
        log_skip "${fs_label} already in /etc/fstab"
    fi

    if ! mountpoint -q "$mount_pt"; then
        mount "$mount_pt"
        log_ok "Mounted ${mount_pt} (${fs_type} RAID 10)"
    else
        log_skip "${mount_pt} is already mounted"
    fi
}

ARRAY_SUMMARY_LABELS="$(jq -r 'if length > 0 then ([.[] | "\(.name):\(.label)"] | join(", ")) else "None" end' <<< "$RAID_ARRAYS_JSON")"

if [[ "$WITH_RAID" == "true" && "$RAID_ARRAY_COUNT" -gt 0 ]]; then
    log_step "3B. Provisioning USB RAID 10 Arrays (${ARRAY_SUMMARY_LABELS})"

    cat << 'EOF' > /etc/udev/rules.d/99-brakerrak-usb-raid.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="08", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF
    udevadm control --reload-rules && udevadm trigger

    while IFS= read -r arr_json; do
        arr_name="$(jq -r '.name' <<< "$arr_json")"
        arr_id="$(jq -r '.id // (.name | ascii_downcase)' <<< "$arr_json")"
        arr_type="$(jq -r '.type // "vault"' <<< "$arr_json")"
        arr_label="$(jq -r '.label' <<< "$arr_json")"
        arr_mount="$(jq -r '.mount' <<< "$arr_json")"
        arr_md="$(jq -r '.md_dev // ("/dev/md/" + (.id // (.name | ascii_downcase)))' <<< "$arr_json")"
        arr_disks="$(jq -r '.disks // 4' <<< "$arr_json")"
        arr_min="$(jq -r '.min_bytes' <<< "$arr_json")"
        arr_max="$(jq -r '.max_bytes' <<< "$arr_json")"

        provision_usb_raid10 \
            "$arr_name" "$arr_id" "$arr_type" "$arr_md" \
            "$arr_label" "$arr_mount" "$arr_disks" "$arr_min" "$arr_max"
    done < <(jq -c '.[]' <<< "$RAID_ARRAYS_JSON")

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
    log_step "3B. USB RAID Provisioning Skipped (WITH_RAID=false / No arrays configured)"
fi

# ==============================================================================
# STAGE 4: Zero-Cache Forge of PostgreSQL $PG_VERSION (PGDG deb-src + perf stat)
# ==============================================================================
log_step "4. Forging PostgreSQL ${PG_VERSION} (PGDG riscv64 + ${ISA_MARCH} + perf stat)"

PGDG_KEY="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
LOCAL_LIST="/etc/apt/sources.list.d/drewv-local-pgdg.list"
CODENAME="$(lsb_release -cs 2>/dev/null || echo sid)"
case "$CODENAME" in
    forky|trixie|bookworm|n/a|"") CODENAME="sid" ;;
esac
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
    apt-get -o DPkg::Lock::Timeout=120 update -q
    log_ok "Configured PGDG binary + deb-src repositories for ${CODENAME}-pgdg"
else
    log_skip "PGDG repository already configured"
fi

update_local_pgdg_repo() {
    (cd "$LOCAL_REPO_DIR" && dpkg-scanpackages . /dev/null > Packages 2>/dev/null)
    echo "deb [trusted=yes] file://${LOCAL_REPO_DIR} ./" > "$LOCAL_LIST"
    apt-get -o DPkg::Lock::Timeout=120 update -o Acquire::GzipIndexes=false -q
}

if dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 && [[ "$FORCE_REBUILD_PG" == "false" ]]; then
    log_skip "postgresql-${PG_VERSION} is already installed (pass --force-rebuild-pg to recompile from scratch)"
else
    if [[ "$FORCE_REBUILD_PG" == "true" ]]; then
        log_warn "Purging existing postgresql-${PG_VERSION} installation and .deb caches for zero-cache forge..."
        systemctl stop postgresql 2>/dev/null || true
        apt-get purge "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" 2>/dev/null || true
        rm -rf "${LOCAL_REPO_DIR:?}"/postgresql-${PG_VERSION}_*.deb "${LOCAL_REPO_DIR:?}"/postgresql-client-${PG_VERSION}_*.deb "${NVME_CACHE_DIR:?}" "${BUILD_DIR:?}" "$LOCAL_LIST" 2>/dev/null || true
        apt-get -o DPkg::Lock::Timeout=120 update -q
    elif [[ "$USE_PKG_CACHE" == "true" ]]; then
        mkdir -p "$NVME_CACHE_DIR"
        if ! ls "${LOCAL_REPO_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1 && \
           ls "${NVME_CACHE_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1; then
            cp -a "${NVME_CACHE_DIR}"/*.deb "$LOCAL_REPO_DIR/"
            log_ok "Restored cached JH7110 PostgreSQL ${PG_VERSION} .deb packages from NVMe (--use-pkg-cache)"
        fi
    elif [[ -n "$PG_PREBUILT_DEB_URL" ]]; then
        log_ok "Downloading prebuilt JH7110 PostgreSQL ${PG_VERSION} bundle from ${PG_PREBUILT_DEB_URL}..."
        curl -fsSL "$PG_PREBUILT_DEB_URL" | tar -I zstd -xf - -C "$LOCAL_REPO_DIR"
    else
        rm -rf "${LOCAL_REPO_DIR:?}"/postgresql-${PG_VERSION}_*.deb "${LOCAL_REPO_DIR:?}"/postgresql-client-${PG_VERSION}_*.deb "$LOCAL_LIST" 2>/dev/null || true
    fi

    if { [[ "$USE_PKG_CACHE" == "true" ]] || [[ -n "$PG_PREBUILT_DEB_URL" ]]; } && ls "${LOCAL_REPO_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1; then
        update_local_pgdg_repo
        log_skip "Using prebuilt/cached JH7110-optimized postgresql-${PG_VERSION} .deb packages in $LOCAL_REPO_DIR"
    else
        log_warn "Compiling zero-cache JH7110-tuned postgresql-${PG_VERSION} from PGDG deb-src with perf telemetry..."
        apt-get install "${APT_FLAGS[@]}" dpkg-dev debhelper build-essential liburing-dev libzstd-dev liblz4-dev

        unset CCACHE_DIR CCACHE_PREFIX || true
        mkdir -p "$BUILD_DIR"
        chmod 755 /opt/drewv-pgdg-riscv64 "$LOCAL_REPO_DIR"
        chown -R _apt:root "$BUILD_DIR"
        chmod 775 "$BUILD_DIR"

        JH7110_FLAGS="-O3 -pipe -march=${ISA_MARCH}"
        if gcc -O3 -pipe -march="${ISA_MARCH}" -mcpu="${CPU_MTUNE}" -mtune="${CPU_MTUNE}" -x c -c /dev/null -o /dev/null 2>/dev/null; then
            JH7110_FLAGS="-O3 -pipe -march=${ISA_MARCH} -mcpu=${CPU_MTUNE} -mtune=${CPU_MTUNE}"
        fi
        log_ok "Selected GCC optimization flags: ${JH7110_FLAGS}"

        export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
        export DEB_CFLAGS_APPEND="$JH7110_FLAGS"
        export DEB_CXXFLAGS_APPEND="$JH7110_FLAGS"

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

        rm -rf "${BUILD_DIR:?}"/*
        chown _apt:root "$BUILD_DIR"
        cd "$BUILD_DIR"
        apt-get build-dep "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}"

        PERF_CSV="${TELEMETRY_DIR}/pg${PG_VERSION}-forge-perf-${RUN_TS}.csv"
        PERF_TXT="${TELEMETRY_DIR}/pg${PG_VERSION}-forge-perf-${RUN_TS}.txt"
        META_JSON="${TELEMETRY_DIR}/pg${PG_VERSION}-forge-meta-${RUN_TS}.json"
        PERF_EVENTS="task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,L1-icache-loads,L1-icache-load-misses,dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses"

        PERF_BIN="$(command -v perf || true)"
        if [[ -n "$PERF_BIN" ]] && ! "$PERF_BIN" stat -e cycles true >/dev/null 2>&1; then
            PERF_BIN="$(find /usr/lib/linux-tools-* -name perf -type f 2>/dev/null | sort -V | tail -n1 || true)"
        fi

        START_EPOCH="$(date +%s.%N)"
        if [[ -n "$PERF_BIN" ]] && "$PERF_BIN" stat -e cycles true >/dev/null 2>&1; then
            log_ok "Capturing StarFive JH7110 (SiFive U74) PMU counters via ${PERF_BIN} stat -> ${PERF_CSV}"
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
  "soc": "ESWIN EIC7700X (4x StarFive JH7110 (SiFive U74) @ 1.4GHz)",
  "isa_flags": "${JH7110_FLAGS}",
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
# STAGE 5: Relocating Cluster to SN850X & Tuning for StarFive JH7110 (SiFive U74) 32GB
# ==============================================================================
log_step "5. Relocating Cluster to $MOUNT_POINT & Applying StarFive JH7110 (SiFive U74) Tuning"

NVME_PG_ROOT="${MOUNT_POINT}/postgresql"
NVME_PG_DATA="${NVME_PG_ROOT}/${PG_VERSION}/main"
DEFAULT_PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
DROPIN_CONF="${CONF_DIR}/99-brakerbox-vf2.conf"
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

rm -f "${CONF_DIR}/99-brackerbox-p550.conf"

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

PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin/postgres"
IO_METHOD="worker"
if [[ -x "$PG_BIN" ]] && ldd "$PG_BIN" | grep -q "liburing"; then
    if [[ "$(sysctl -n kernel.io_uring_disabled 2>/dev/null || echo 0)" == "0" ]]; then
        IO_METHOD="io_uring"
    fi
fi
log_ok "Selected PostgreSQL 18 Async I/O method: io_method = ${IO_METHOD}"

mkdir -p "$CONF_DIR"
DESIRED_PG_CONF="# DREW-V Labs: SiFive HiFive Premier JH7110 (32GB LPDDR5 + WD_BLACK SN850X 4Kn)
data_directory = '${NVME_PG_DATA}'
listen_addresses = '*'
max_connections = ${PG_MAX_CONN}

# 32GB LPDDR5 Memory Allocation (Backed by 2MB Sv39 HugePages)
shared_buffers = ${PG_SHARED_BUFFERS}
effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE}
work_mem = ${PG_WORK_MEM}
maintenance_work_mem = ${PG_MAINT_WORK_MEM}
huge_pages = try

# StarFive JH7110 (SiFive U74) 4-Core (3-Wide Out-of-Order, RVA20+Zba/Zbb) Tuning
jit = off
max_worker_processes = 8
max_parallel_workers = 4
max_parallel_workers_per_gather = 2
max_parallel_maintenance_workers = 2

# WD_BLACK SN850X 4Kn PCIe Gen3 x4 & PostgreSQL 18 Async I/O
io_method = ${IO_METHOD}
effective_io_concurrency = ${PG_IO_CONCURRENCY}
maintenance_io_concurrency = ${PG_MAINT_IO_CONCURRENCY}
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

if ! systemctl is-active --quiet postgresql || [[ "$NEED_PG_RESTART" == "true" ]]; then
    systemctl enable postgresql >/dev/null 2>&1 || true
    systemctl restart postgresql
    log_ok "PostgreSQL ${PG_VERSION} service started/restarted"
else
    log_skip "PostgreSQL ${PG_VERSION} is already active and running current config"
fi

if [[ "$WITH_RAID" == "true" && "$RAID_ARRAY_COUNT" -gt 0 ]]; then
    while IFS= read -r arr_json; do
        arr_name="$(jq -r '.name' <<< "$arr_json")"
        arr_type="$(jq -r '.type // "vault"' <<< "$arr_json")"
        arr_mount="$(jq -r '.mount' <<< "$arr_json")"
        arr_ts="$(jq -r '.tablespace // empty' <<< "$arr_json")"

        [[ -z "$arr_ts" ]] && continue

        if mountpoint -q "$arr_mount"; then
            ts_dir="${arr_mount}/postgresql/tablespaces"
            mkdir -p "$ts_dir"
            chattr +C "$ts_dir" 2>/dev/null || true
            chown -R postgres:postgres "${arr_mount}/postgresql"
            chmod 700 "$ts_dir"

            if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_tablespace WHERE spcname = '${arr_ts}';" | grep -q 1; then
                rm -rf "${ts_dir}"/PG_* 2>/dev/null || true
                sudo -u postgres psql -c "CREATE TABLESPACE ${arr_ts} LOCATION '${ts_dir}';"
                log_ok "Created ${arr_type^} Tablespace (${arr_name}): ${arr_ts} -> ${ts_dir}"
            else
                log_skip "${arr_type^} Tablespace (${arr_name}) '${arr_ts}' already registered"
            fi
        else
            log_warn "Skipping tablespace '${arr_ts}': ${arr_mount} is not mounted"
        fi
    done < <(jq -c '.[]' <<< "$RAID_ARRAYS_JSON")
fi

# ==============================================================================
# STAGE 5B: DataBroker Services (Mosquitto MQTT + Dynamic NFSv4 Server)
# ==============================================================================
if [[ "$ENABLE_MQTT_BROKER" == "true" ]]; then
    log_step "5B.1. Converging Eclipse Mosquitto MQTT Broker (:${MQTT_PORT})"
    if ! dpkg -s mosquitto >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=120 update -q
        apt-get install "${APT_FLAGS[@]}" mosquitto mosquitto-clients
    fi

    MQTT_CONF="/etc/mosquitto/conf.d/brakerrak.conf"
    DESIRED_MQTT_CONF="# DREW-V Labs // BrakerRak Telemetry Broker Configuration

# BrakerRak CTD Telemetry Broker Profile (Ubuntu 24.04 / Mosquitto 2.0.18)
per_listener_settings false
allow_anonymous true

# Edge Node TCP Ingress
listener ${MQTT_PORT} 0.0.0.0
max_connections -1

# Local PigeonCoop Zero-TCP IPC Socket (Port 0 + Path = AF_UNIX)
listener 0 /run/mosquitto/mosquitto.sock

# High-Throughput Queue & NVMe Wear Mitigation
autosave_interval 1800
max_inflight_messages 100
max_queued_messages 10000"

    if [[ ! -f "$MQTT_CONF" ]] || [[ "$(cat "$MQTT_CONF")" != "$DESIRED_MQTT_CONF" ]]; then
        echo "$DESIRED_MQTT_CONF" > "$MQTT_CONF"
        [[ -n "${ADMIN_USER:-}" ]] && usermod -aG mosquitto "$ADMIN_USER" || true
        systemctl enable mosquitto >/dev/null 2>&1 || true
        systemctl reset-failed mosquitto >/dev/null 2>&1 || true
        systemctl restart mosquitto
        chmod 0750 /run/mosquitto 2>/dev/null || true
        log_ok "Configured & started Mosquitto MQTT on :${MQTT_PORT} + /run/mosquitto/mosquitto.sock"
    else
        if ! systemctl is-active --quiet mosquitto; then
            systemctl reset-failed mosquitto >/dev/null 2>&1 || true
            systemctl restart mosquitto
        fi
        chmod 0750 /run/mosquitto 2>/dev/null || true
        log_skip "Mosquitto MQTT already configured and active on :${MQTT_PORT}"
    fi
    mosquitto_pub -h 127.0.0.1 -p "$MQTT_PORT" -t "brakerrak/${TARGET_HOSTNAME}/status" -m "ONLINE" -r || true
elif systemctl is-active --quiet mosquitto 2>/dev/null; then
    systemctl disable --now mosquitto 2>/dev/null || true
    log_ok "Disabled Mosquitto MQTT broker for role=${NODE_ROLE}"
fi

NFS_EXPORT_SUMMARY="Disabled"
if [[ "$ENABLE_NFS_SERVER" == "true" ]]; then
    if ! dpkg -s nfs-kernel-server >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=120 update -q
        apt-get install "${APT_FLAGS[@]}" nfs-kernel-server
    fi

    DESIRED_EXPORTS_BLOCK="# BRAKERRAK_NFS_BEGIN"
    if [[ "$WITH_RAID" == "true" && "$RAID_ARRAY_COUNT" -gt 0 ]]; then
        log_step "5B.2. Converging NFSv4 Kernel Server on RAID Vaults (${ARRAY_SUMMARY_LABELS})"
        idx_fsid=10
        while IFS= read -r arr_json; do
            arr_mount="$(jq -r '.mount' <<< "$arr_json")"
            arr_fsid="$(jq -r ".nfs_fsid // ${idx_fsid}" <<< "$arr_json")"
            idx_fsid=$((idx_fsid + 10))

            if mountpoint -q "$arr_mount"; then
                while IFS= read -r subdir; do
                    [[ -z "$subdir" ]] && continue
                    install -d -m 0775 -o "$ADMIN_USER" -g "$ADMIN_USER" "${arr_mount}/${subdir}"
                done < <(jq -r '.nfs_dirs[]? // empty' <<< "$arr_json")
            fi

            DESIRED_EXPORTS_BLOCK+=$'\n'"${arr_mount} ${LAB_SUBNET}(rw,sync,no_subtree_check,no_root_squash,fsid=${arr_fsid})"
        done < <(jq -c '.[]' <<< "$RAID_ARRAYS_JSON")
        NFS_EXPORT_SUMMARY="RAID Vaults (${ARRAY_SUMMARY_LABELS}) -> ${LAB_SUBNET}"
    else
        log_step "5B.2. Converging NFSv4 Kernel Server on NVMe (${NVME_NFS_EXPORT})"
        for subdir in "" "/models" "/sigmf" "/fits" "/pg_backups" "/ctd-vault" "/shared"; do
            install -d -m 0775 -o "$ADMIN_USER" -g "$ADMIN_USER" "${NVME_NFS_EXPORT}${subdir}"
        done
        DESIRED_EXPORTS_BLOCK+=$'\n'"${NVME_NFS_EXPORT} ${LAB_SUBNET}(rw,sync,no_subtree_check,no_root_squash,fsid=10)"
        NFS_EXPORT_SUMMARY="NVMe Vault (${NVME_NFS_EXPORT}) -> ${LAB_SUBNET}"
    fi
    DESIRED_EXPORTS_BLOCK+=$'\n'"# BRAKERRAK_NFS_END"

    CURRENT_EXPORTS_BLOCK="$(awk '/^# BRAKERRAK_NFS_BEGIN$/,/^# BRAKERRAK_NFS_END$/' /etc/exports 2>/dev/null || true)"
    if [[ "$CURRENT_EXPORTS_BLOCK" != "$DESIRED_EXPORTS_BLOCK" ]]; then
        sed -i '/# BRAKERRAK_NFS_BEGIN/,/# BRAKERRAK_NFS_END/d' /etc/exports 2>/dev/null || true
        printf "%s\n" "$DESIRED_EXPORTS_BLOCK" >> /etc/exports
        exportfs -ra
        systemctl enable nfs-kernel-server >/dev/null 2>&1 || true
        systemctl restart nfs-kernel-server
        log_ok "NFSv4 exporting ${NFS_EXPORT_SUMMARY}"
    else
        systemctl is-active --quiet nfs-kernel-server || systemctl restart nfs-kernel-server
        log_skip "NFSv4 exports in /etc/exports already up to date (${NFS_EXPORT_SUMMARY})"
    fi
elif systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
    systemctl disable --now nfs-kernel-server 2>/dev/null || true
    log_ok "Disabled nfs-kernel-server for role=${NODE_ROLE}"
fi

# ==============================================================================
# STAGE 6: Emit Hardware-Agnostic ~/.brakerrak/node.env Template & Summary
# ==============================================================================
if [[ ! -f "$USER_NODE_ENV" ]]; then
    install -d -m 0750 -o "$REAL_USER" -g "$REAL_USER" "$BRAKER_CONF_DIR"
    cat <<EOF > "$USER_NODE_ENV"
# ==============================================================================
# DREW-V Labs // BrakerRak User Node Config (~/.brakerrak/node.env)
# Generated on Pass 1. Customize values below and re-run the following for Pass 2.
#  > sudo brakerrak verify --use-pkg-cache
# ==============================================================================
NODE_ROLE="${NODE_ROLE}"
TARGET_HOSTNAME="${TARGET_HOSTNAME}"
ADMIN_USER="${ADMIN_USER}"
LAB_SUBNET="${LAB_SUBNET}"

# Hot NVMe Storage
NVME_DEV="${NVME_DEV}"
MOUNT_POINT="${MOUNT_POINT}"

# Optional USB/SATA RAID 10 Arrays (Default: false / empty array)
WITH_RAID="false"
RAID_ARRAYS_JSON='[]'

# DataBroker Network Services (When ENABLE_NFS_SERVER=true and WITH_RAID=false, exports \${MOUNT_POINT}/nfs_vault)
ENABLE_MQTT_BROKER="${ENABLE_MQTT_BROKER}"
MQTT_PORT="${MQTT_PORT}"
ENABLE_NFS_SERVER="${ENABLE_NFS_SERVER}"

# Opt-In Community RISC-V Telemetry Commons
SHARE_ORT_SNAPSHOT="false"
EOF
    chown "${REAL_USER}:${REAL_USER}" "$USER_NODE_ENV"
    log_ok "Generated hardware-agnostic Pass 2 user config template at ${USER_NODE_ENV}"
fi

log_step "6. Post-Flight Verification Summary (Pass ${FORGE_PASS})"

ACTIVE_DATA_DIR="$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null || echo "N/A")"
ACTIVE_IO_METHOD="$(sudo -u postgres psql -tAc "SHOW io_method;" 2>/dev/null || echo "N/A")"
ACTIVE_BUFFERS="$(sudo -u postgres psql -tAc "SHOW shared_buffers;" 2>/dev/null || echo "N/A")"
HUGEPAGES_FREE="$(awk '/HugePages_Free:/ {print $2}' /proc/meminfo)"
HUGEPAGES_TOTAL="$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo)"
FINAL_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
MQTT_STATE="$(systemctl is-active mosquitto 2>/dev/null || echo "inactive")"
NFS_STATE="$(systemctl is-active nfs-kernel-server 2>/dev/null || echo "inactive")"

printf "  • %-18s : %s (Role: %s | Pass: %s)\n" "Hostname" "$(hostname)" "$NODE_ROLE" "$FORGE_PASS"
printf "  • %-18s : %s (%s)\n" "Kernel / Arch" "$(uname -r)" "$(uname -m)"
printf "  • %-18s : %s bytes\n" "NVMe LBA Block Sz" "$FINAL_LBA"
printf "  • %-18s : %s\n" "Hot NVMe Mount" "$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT" || echo "Not Mounted")"

if [[ "$WITH_RAID" == "true" && "$RAID_ARRAY_COUNT" -gt 0 ]]; then
    while IFS= read -r arr_json; do
        arr_name="$(jq -r '.name' <<< "$arr_json")"
        arr_type="$(jq -r '.type // "vault"' <<< "$arr_json")"
        arr_mount="$(jq -r '.mount' <<< "$arr_json")"
        tier_title="${arr_type^} RAID (${arr_name})"
        printf "  • %-18s : %s\n" "$tier_title" "$(findmnt -n -o SOURCE,TARGET,FSTYPE "$arr_mount" 2>/dev/null || echo "Not Mounted")"
    done < <(jq -c '.[]' <<< "$RAID_ARRAYS_JSON")
else
    printf "  • %-18s : %s\n" "USB RAID Arrays" "None configured (NVMe-only topology)"
fi

printf "  • %-18s : %s\n" "PG Data Directory" "$ACTIVE_DATA_DIR"
printf "  • %-18s : io_method = %s\n" "PG 18 Async I/O" "$ACTIVE_IO_METHOD"
printf "  • %-18s : %s (HugePages in use: %d / %d)\n" "PG Shared Buffers" "$ACTIVE_BUFFERS" "$((HUGEPAGES_TOTAL - HUGEPAGES_FREE))" "$HUGEPAGES_TOTAL"
printf "  • %-18s : %s (Port %s)\n" "Mosquitto MQTT" "$MQTT_STATE" "$MQTT_PORT"
printf "  • %-18s : %s (%s)\n" "NFSv4 Vault Server" "$NFS_STATE" "$NFS_EXPORT_SUMMARY"

echo ""
log_ok "${TARGET_HOSTNAME} PostgreSQL ${PG_VERSION} (${NODE_ROLE}) Forge Complete!"
