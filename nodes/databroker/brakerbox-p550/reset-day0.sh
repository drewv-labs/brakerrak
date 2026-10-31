#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Option A In-Place Day-0 Factory State Rollback (BrakerBox-P550)
# Path: drewv-labs/brakerrak/nodes/databrokers/brakerbox-p550/reset-day0.sh
# Description: Tears down PostgreSQL 18, resets WD_BLACK SN850X to factory 512e
#              (512-byte) LBA sectors, wipes USB RAID superblocks, and reverts
#              eMMC OS configuration back to pre-forge Day-0 state.
#
# Usage:
#   sudo ./reset-day0.sh --confirm-destroy                  # Full zero-cache rollback
#   sudo ./reset-day0.sh --confirm-destroy --keep-pg-cache  # Fast-loop (preserves PG18 .debs)
#   sudo ./reset-day0.sh --confirm-destroy --skip-raid-wipe # Keep BigRed/LilBlu intact
# ==============================================================================

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Re-executing with sudo..."
    exec sudo -E bash "$0" "$@"
fi

CONFIRM_DESTROY="false"
KEEP_CACHE="false"
SKIP_RAID_WIPE="false"
RESET_HOSTNAME="ubuntu"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm-destroy) CONFIRM_DESTROY="true"; shift ;;
        --keep-pg-cache)   KEEP_CACHE="true"; shift ;;
        --skip-raid-wipe)  SKIP_RAID_WIPE="true"; shift ;;
        --hostname)        RESET_HOSTNAME="${2:-ubuntu}"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 --confirm-destroy [--keep-pg-cache] [--skip-raid-wipe] [--hostname ubuntu]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo $0 --confirm-destroy [--keep-pg-cache] [--skip-raid-wipe] [--hostname ubuntu]"
            exit 1
            ;;
    esac
done

if [[ "$CONFIRM_DESTROY" != "true" ]]; then
    printf "\033[1;31m[ABORT] Destructive Day-0 rollback requires --confirm-destroy flag.\033[0m\n" >&2
    echo "Example: sudo $0 --confirm-destroy [--keep-pg-cache]" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "=== 1. Stopping PostgreSQL & Handling .deb Cache (keep_cache=${KEEP_CACHE}) ==="
systemctl stop postgresql 2>/dev/null || true
pkill -9 -u postgres 2>/dev/null || true

if [[ "$KEEP_CACHE" == "true" ]]; then
    mkdir -p /tmp/pgdg-deb-backup
    cp -a /opt/drewv-pgdg-riscv64/debs/*.deb /tmp/pgdg-deb-backup/ 2>/dev/null || \
    cp -a /mnt/nvme_pgdata/.pkg-cache/pgdg-riscv64/*.deb /tmp/pgdg-deb-backup/ 2>/dev/null || true
else
    rm -rf /tmp/pgdg-deb-backup
fi

echo "=== 2. Unmounting Storage Tiers & Handling USB RAID Disks ==="
umount -f /mnt/nvme_pgdata /mnt/bigred_wdr48 /mnt/lilblu_wdr48 /mnt/lilblu_wdb24 2>/dev/null || true

if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
    for d in $(lsblk -b -dn -o NAME,ROTA,TYPE | awk '$3=="disk" && $2=="1" {print "/dev/"$1}'); do
        wipefs -a "$d" >/dev/null
        echo "  [OK] Wiped Btrfs/RAID superblocks on rotational disk $d"
    done
else
    echo "  [SKIP] Preserved rotational USB RAID disks (--skip-raid-wipe)"
fi

echo "=== 3. Tearing Down LVM (vg_braker) & Resetting SN850X to Factory 512e (512B) ==="
if vgs vg_braker >/dev/null 2>&1; then
    lvchange -an vg_braker 2>/dev/null || true
    vgremove -ff -y vg_braker 2>/dev/null || true
fi
pvremove -ff -y /dev/nvme0n1* 2>/dev/null || true
wipefs -a /dev/nvme0n1

LBA_512_INDEX="$(nvme id-ns /dev/nvme0n1 | awk '/^lbaf.*lbads:9/ {print $2}' | tr -d ':' | head -n1)"
if [[ -n "$LBA_512_INDEX" ]]; then
    nvme format /dev/nvme0n1 -l "$LBA_512_INDEX" -s 1 --force || nvme format /dev/nvme0n1 -l "$LBA_512_INDEX" --force
    partprobe /dev/nvme0n1 || true
    udevadm settle
    sleep 2
fi
echo "  [OK] /dev/nvme0n1 logical sector size reset to: $(cat /sys/block/nvme0n1/queue/logical_block_size)B (Factory 512e)"

echo "=== 4. Purging PostgreSQL 18, PGDG Repos & Mount Directories ==="
apt-get purge -y "postgresql-18*" "postgresql-client-18*" "postgresql-common*" 2>/dev/null || true
apt-get autoremove -y --purge >/dev/null
rm -rf /etc/postgresql /etc/postgresql-common /var/lib/postgresql /var/log/postgresql
rm -rf /opt/drewv-pgdg-riscv64 /mnt/nvme_pgdata /mnt/bigred_wdr48 /mnt/lilblu_wdb24
rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/drewv-local-pgdg.list
rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

if [[ "$KEEP_CACHE" == "true" ]] && ls /tmp/pgdg-deb-backup/*.deb >/dev/null 2>&1; then
    mkdir -p /opt/drewv-pgdg-riscv64/debs
    cp -a /tmp/pgdg-deb-backup/*.deb /opt/drewv-pgdg-riscv64/debs/
    echo "  [OK] Restored cached P550 PostgreSQL .deb packages to /opt/drewv-pgdg-riscv64/debs"
fi
apt-get update -q

echo "=== 5. Reverting /etc/fstab, Sysctls, Udev Rules & Hostname ==="
sed -i -e '/PGDATA_NVME/d' -e '/BIGRED_VAULT/d' -e '/LILBLU_ARCH/d' /etc/fstab
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
echo "=== [OK] Option A Day-0 Rollback Complete (Hostname: $(hostname), NVMe LBA: $(cat /sys/block/nvme0n1/queue/logical_block_size)B) ==="
