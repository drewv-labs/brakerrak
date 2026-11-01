#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Option A In-Place Day-0 Factory State Rollback (BrakerBox-P550)
# Path: drewv-labs/brakerrak/nodes/databroker/brakerbox-p550/reset-day0.sh
# Description: Tears down PostgreSQL 18, Mosquitto MQTT, and NFSv4 exports,
#              resets primary NVMe to factory 512e (512-byte) LBA sectors,
#              unmounts & wipes any RAID arrays configured in RAID_ARRAYS_JSON,
#              and reverts eMMC OS configuration back to pre-forge Day-0 state.
#
# Usage:
#   sudo ./reset-day0.sh --confirm-destroy                  # Full zero-cache rollback
#   sudo ./reset-day0.sh --confirm-destroy --keep-pg-cache  # Fast-loop (preserves PG18 .debs)
#   sudo ./reset-day0.sh --confirm-destroy --skip-raid-wipe # Keep RAID vaults intact
# ==============================================================================

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Re-executing with sudo..."
    exec sudo -E bash "$0" "$@"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
USER_NODE_ENV="${REAL_HOME}/.brakerrak/node.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NVME_DEV="/dev/nvme0n1"
MOUNT_POINT="/mnt/nvme_pgdata"
FS_LABEL="PGDATA_NVME"
VG_NAME="vg_braker"
LV_NAME="lv_pgdata"
WITH_RAID="false"
RAID_ARRAYS_JSON='[]'

if [[ -f "${USER_NODE_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${USER_NODE_ENV}"
elif [[ -f "${SCRIPT_DIR}/node.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/node.env"
fi

CONFIRM_DESTROY="false"
KEEP_CACHE="false"
SKIP_RAID_WIPE="false"
RESET_HOSTNAME="ubuntu"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            if [[ -f "${2:-}" ]]; then
                # shellcheck disable=SC1090
                source "$2"
            else
                echo "Config file not found: ${2:-}" >&2
                exit 1
            fi
            shift 2
            ;;
        --confirm-destroy) CONFIRM_DESTROY="true"; shift ;;
        --keep-pg-cache)   KEEP_CACHE="true"; shift ;;
        --skip-raid-wipe)  SKIP_RAID_WIPE="true"; shift ;;
        --hostname)        RESET_HOSTNAME="${2:-ubuntu}"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 --confirm-destroy [--config file.env] [--keep-pg-cache] [--skip-raid-wipe] [--hostname ubuntu]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ "$CONFIRM_DESTROY" != "true" ]]; then
    printf "\033[1;31m[ABORT] Destructive Day-0 rollback requires --confirm-destroy flag.\033[0m\n" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
NVME_SHORT="$(basename "$NVME_DEV")"

mapfile -t RAID_MOUNTS < <(jq -r '.[].mount // empty' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || true)
mapfile -t RAID_LABELS < <(jq -r '.[].label // empty' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || true)
mapfile -t RAID_MDS    < <(jq -r '.[].md_dev // empty' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || true)

echo "=== 1. Stopping DataBroker Services & Handling .deb Cache (keep_cache=${KEEP_CACHE}) ==="
systemctl stop postgresql "postgresql@*" mosquitto nfs-kernel-server 2>/dev/null || true
pkill -9 -u postgres 2>/dev/null || true

if [[ "$KEEP_CACHE" == "true" ]]; then
    mkdir -p /tmp/pgdg-deb-backup
    cp -a /opt/drewv-pgdg-riscv64/debs/*.deb /tmp/pgdg-deb-backup/ 2>/dev/null || \
    cp -a "${MOUNT_POINT}/.pkg-cache/pgdg-riscv64/"*.deb /tmp/pgdg-deb-backup/ 2>/dev/null || true
else
    rm -rf /tmp/pgdg-deb-backup
fi

echo "=== 2. Unmounting Storage Tiers & Handling Configured RAID Disks ==="
for mp in "$MOUNT_POINT" "${RAID_MOUNTS[@]}"; do
    [[ -z "$mp" ]] && continue
    if mountpoint -q "$mp" 2>/dev/null; then
        fuser -km "$mp" 2>/dev/null || true
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        echo "  [OK] Unmounted $mp"
    fi
done

if [[ "$WITH_RAID" == "true" && "${#RAID_MOUNTS[@]}" -gt 0 && "$SKIP_RAID_WIPE" == "false" ]]; then
    for md in "${RAID_MDS[@]}"; do
        [[ -n "$md" ]] && mdadm --stop "$md" 2>/dev/null || true
    done
    while IFS= read -r arr_json; do
        min_b="$(jq -r '.min_bytes // 0' <<< "$arr_json")"
        max_b="$(jq -r '.max_bytes // 0' <<< "$arr_json")"
        for d in $(lsblk -b -dn -o NAME,SIZE,ROTA,TYPE | awk -v min="$min_b" -v max="$max_b" '$4=="disk" && $3=="1" && $2>=min && $2<=max {print "/dev/"$1}'); do
            mdadm --zero-superblock "$d" 2>/dev/null || true
            wipefs -a "$d" >/dev/null
            echo "  [OK] Wiped Btrfs/RAID superblocks on rotational disk $d"
        done
    done < <(jq -c '.[]' <<< "$RAID_ARRAYS_JSON")
else
    echo "  [SKIP] No RAID disk wipe requested (WITH_RAID=${WITH_RAID}, skip_raid_wipe=${SKIP_RAID_WIPE})"
fi

echo "=== 3. Tearing Down LVM (${VG_NAME}) & Resetting ${NVME_DEV} to Factory 512e (512B) ==="
umount "/dev/mapper/${VG_NAME}-"* 2>/dev/null || umount -l "/dev/mapper/${VG_NAME}-"* 2>/dev/null || true
if vgs "$VG_NAME" >/dev/null 2>&1; then
    lvchange -an "$VG_NAME" 2>/dev/null || true
    vgchange -an "$VG_NAME" 2>/dev/null || true
    vgremove -ff -y "$VG_NAME" 2>/dev/null || true
fi
dmsetup remove "${VG_NAME}-${LV_NAME}" 2>/dev/null || true
pvremove -ff -y "${NVME_DEV}"* 2>/dev/null || true
udevadm settle
sleep 1

wipefs -a "$NVME_DEV"

LBA_512_INDEX="$(nvme id-ns "$NVME_DEV" | awk '/^lbaf.*lbads:9/ {print $2}' | tr -d ':' | head -n1)"
if [[ -n "$LBA_512_INDEX" ]]; then
    nvme format "$NVME_DEV" -l "$LBA_512_INDEX" -s 1 --force || nvme format "$NVME_DEV" -l "$LBA_512_INDEX" --force
    partprobe "$NVME_DEV" || true
    udevadm settle
    sleep 2
fi
echo "  [OK] ${NVME_DEV} logical sector size reset to: $(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")B (Factory 512e)"

echo "=== 4. Purging PostgreSQL 18, Mosquitto/NFS Configs & Mount Directories ==="
apt-get -o DPkg::Lock::Timeout=120 purge -y "postgresql-18*" "postgresql-client-18*" "postgresql-common*" 2>/dev/null || true
apt-get -o DPkg::Lock::Timeout=120 autoremove -y --purge >/dev/null
rm -rf /etc/postgresql /etc/postgresql-common /var/lib/postgresql /var/log/postgresql
rm -rf /opt/drewv-pgdg-riscv64 "$MOUNT_POINT"
if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
    for mp in "${RAID_MOUNTS[@]}"; do
        [[ -n "$mp" ]] && rm -rf "${mp:?}"
    done
fi
rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/drewv-local-pgdg.list
rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
rm -f /etc/mosquitto/conf.d/brakerrak.conf /etc/mosquitto/conf.d/99-brakerrak.conf
if [[ -f /etc/exports ]]; then
    sed -i '/# BRAKERRAK_NFS_BEGIN/,/# BRAKERRAK_NFS_END/d' /etc/exports 2>/dev/null || true
    exportfs -ra 2>/dev/null || true
fi

if [[ "$KEEP_CACHE" == "true" ]] && ls /tmp/pgdg-deb-backup/*.deb >/dev/null 2>&1; then
    mkdir -p /opt/drewv-pgdg-riscv64/debs
    cp -a /tmp/pgdg-deb-backup/*.deb /opt/drewv-pgdg-riscv64/debs/
    echo "  [OK] Restored cached P550 PostgreSQL .deb packages to /opt/drewv-pgdg-riscv64/debs"
fi
apt-get -o DPkg::Lock::Timeout=120 update -q

echo "=== 5. Reverting /etc/fstab, Sysctls, Udev Rules & Hostname ==="
sed -i "/${FS_LABEL}/d" /etc/fstab
for lbl in "${RAID_LABELS[@]}"; do
    [[ -n "$lbl" ]] && sed -i "/${lbl}/d" /etc/fstab
done
systemctl daemon-reload

rm -f /etc/sysctl.d/90-brakerbox-broker.conf \
      /etc/sysctl.d/90-sifive-p550-pmu.conf \
      /etc/udev/rules.d/99-brakerrak-usb-raid.rules \
      /etc/apt/apt.conf.d/90-p550-bsp-protect \
      /etc/apt/preferences.d/nosnap.pref

sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1 || true
sysctl --system >/dev/null
udevadm control --reload-rules && udevadm trigger

systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
hostnamectl set-hostname "$RESET_HOSTNAME"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${RESET_HOSTNAME}/g" /etc/hosts || true

echo ""
echo "=== [OK] Option A Day-0 Rollback Complete (Hostname: $(hostname), NVMe LBA: $(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")B) ==="
