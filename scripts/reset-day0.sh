#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared Option A In-Place Day-0 Factory State Rollback
# Path: brakerrak/scripts/reset-day0.sh
# Description: Stops DataBroker services, unmounts NVMe & Btrfs RAID vaults,
#              resets NVMe to factory 512e (512-byte) LBA sectors, purges
#              PostgreSQL 18 & RVDK service drop-ins, and reverts Day-1 state.
#
# Usage:
#   sudo brakerrak reset --confirm-destroy                  # Full rollback (keeps node.env)
#   sudo brakerrak reset --confirm-destroy --keep-pg-cache  # Preserve local .deb cache
#   sudo brakerrak reset --confirm-destroy --skip-raid-wipe # Keep USB RAID vaults intact
#   sudo brakerrak reset --confirm-destroy --purge-config   # Also delete ~/.brakerrak/node.env
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[RESET:FATAL] Run as root or via 'sudo brakerrak reset --confirm-destroy'." >&2
        exit 1
    fi
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6 2>/dev/null || eval echo "~${REAL_USER}")"
[[ -z "$REAL_HOME" ]] && REAL_HOME="/root"
USER_NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"

NVME_DEV="/dev/nvme0n1"
MOUNT_POINT="/mnt/nvme_pgdata"
NFS_MOUNT_POINT="/mnt/nfs_vault"
FS_LABEL="PGDATA_NVME"
NFS_FS_LABEL="NFS_VAULT"
VG_NAME="vg_braker"
LV_NAME="lv_pgdata"
NFS_LV_NAME="lv_nfsvault"
RAID_ARRAYS_JSON='[]'

if [[ -f "$USER_NODE_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$USER_NODE_ENV"
fi

# Auto-detect factory hostname default from Device Tree + /etc/os-release
DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
OS_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-debian}" || echo "debian")"
if [[ "$DT_MODEL" == *"VisionFive 2"* || "$DT_MODEL" == *"VF2"* || "$DT_MODEL" == *"JH7110"* ]] && [[ "$OS_ID" == "debian" ]]; then
    DEFAULT_RESET_HOST="starfive"
elif [[ "$OS_ID" == "ubuntu" ]]; then
    DEFAULT_RESET_HOST="ubuntu"
else
    DEFAULT_RESET_HOST="$OS_ID"
fi

CONFIRM_DESTROY="false"
KEEP_CACHE="false"
SKIP_RAID_WIPE="false"
PURGE_CONFIG="false"
RESET_HOSTNAME="$DEFAULT_RESET_HOST"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ ! -f "${2:-}" ]] && { echo "[ABORT] Config file not found: ${2:-}" >&2; exit 1; }
            # shellcheck disable=SC1090
            source "$2"
            shift 2
            ;;
        --confirm-destroy) CONFIRM_DESTROY="true"; shift ;;
        --keep-pg-cache)   KEEP_CACHE="true"; shift ;;
        --skip-raid-wipe)  SKIP_RAID_WIPE="true"; shift ;;
        --purge-config)    PURGE_CONFIG="true"; shift ;;
        --hostname)        RESET_HOSTNAME="${2:-$DEFAULT_RESET_HOST}"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo brakerrak reset --confirm-destroy [--keep-pg-cache] [--skip-raid-wipe] [--purge-config] [--hostname <name>]"
            exit 0
            ;;
        *)
            echo "[ABORT] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$CONFIRM_DESTROY" != "true" ]]; then
    printf "\033[1;31m[ABORT] Destructive Day-0 rollback requires --confirm-destroy flag.\033[0m\n" >&2
    exit 1
fi

if [[ -b "$NVME_DEV" ]] && lsblk -no MOUNTPOINT "$NVME_DEV" 2>/dev/null | grep -qE "^(/|/boot|/boot/efi)$"; then
    echo "[ABORT] Safety Interlock: ${NVME_DEV} backs the root/boot OS filesystem! Aborting." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
NVME_SHORT="$(basename "$NVME_DEV")"

if command -v jq >/dev/null 2>&1 && [[ "$(jq 'length' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || echo 0)" -gt 0 ]]; then
    mapfile -t RAID_MOUNTS < <(jq -r '.[].mount // empty' <<< "$RAID_ARRAYS_JSON")
    mapfile -t RAID_LABELS < <(jq -r '.[].label // empty' <<< "$RAID_ARRAYS_JSON")
    mapfile -t RAID_MDS    < <(jq -r '.[].md_dev // empty' <<< "$RAID_ARRAYS_JSON")
else
    RAID_MOUNTS=("/mnt/bigred_wdr48" "/mnt/lilblu_wdb24")
    RAID_LABELS=("BIGRED_VAULT" "LILBLU_ARCH")
    RAID_MDS=("/dev/md/bigred" "/dev/md/lilblu")
fi

echo "=== 1. Stopping DataBroker Services & Handling .deb Cache (keep_cache=${KEEP_CACHE}) ==="
systemctl stop postgresql "postgresql@*" mosquitto nfs-kernel-server nfs-server.service nfs-ganesha.service rvdk-thp-tune.service 2>/dev/null || true
systemctl disable nfs-kernel-server nfs-server.service nfs-ganesha.service mosquitto rvdk-thp-tune.service 2>/dev/null || true
systemctl reset-failed proc-fs-nfsd.mount nfs-server.service nfs-ganesha.service nfs-ganesha-lock.service 2>/dev/null || true
pkill -9 -u postgres 2>/dev/null || true

if [[ "$KEEP_CACHE" == "true" ]]; then
    mkdir -p /tmp/pgdg-deb-backup
    cp -a /opt/drewv-pgdg-riscv64/debs/*.deb /tmp/pgdg-deb-backup/ 2>/dev/null || \
    cp -a "${MOUNT_POINT}/.pkg-cache/pgdg-riscv64/"*.deb /tmp/pgdg-deb-backup/ 2>/dev/null || true
else
    rm -rf /tmp/pgdg-deb-backup
fi

echo "=== 2. Unmounting Storage Tiers & Handling Rotational RAID Disks ==="
for mp in "$NFS_MOUNT_POINT" "$MOUNT_POINT" "${RAID_MOUNTS[@]}"; do
    [[ -z "$mp" ]] && continue
    if mountpoint -q "$mp" 2>/dev/null; then
        fuser -km "$mp" 2>/dev/null || true
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        echo "  [OK] Unmounted $mp"
    fi
done

if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
    for md in "${RAID_MDS[@]}"; do
        [[ -n "$md" ]] && mdadm --stop "$md" 2>/dev/null || true
    done
    for d in $(lsblk -b -dn -o NAME,ROTA,TYPE | awk '$3=="disk" && $2=="1" {print "/dev/"$1}'); do
        if lsblk -no MOUNTPOINT "$d" 2>/dev/null | grep -qE "^(/|/boot)"; then
            continue
        fi
        mdadm --zero-superblock "$d" 2>/dev/null || true
        wipefs -af "$d" >/dev/null 2>&1 || true
        echo "  [OK] Wiped Btrfs/RAID superblocks on rotational disk $d"
    done
else
    echo "  [SKIP] Preserved rotational USB RAID disks (--skip-raid-wipe)"
fi

echo "=== 3. Tearing Down LVM (${VG_NAME}) & Resetting ${NVME_DEV} to Factory 512e (512B) ==="
if [[ -b "$NVME_DEV" ]]; then
    for cand_vg in "$VG_NAME" "vg_rvdk"; do
        [[ -z "$cand_vg" ]] && continue
        umount "/dev/mapper/${cand_vg}-"* 2>/dev/null || umount -l "/dev/mapper/${cand_vg}-"* 2>/dev/null || true
        if vgs "$cand_vg" >/dev/null 2>&1; then
            lvchange -an "$cand_vg" 2>/dev/null || true
            vgchange -an "$cand_vg" 2>/dev/null || true
            vgremove -ff -y "$cand_vg" 2>/dev/null || true
        fi
        dmsetup remove "${cand_vg}-${LV_NAME}" "${cand_vg}-${NFS_LV_NAME}" 2>/dev/null || true
    done
    pvremove -ff -y "${NVME_DEV}"* 2>/dev/null || true
    for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
    wipefs -af "$NVME_DEV" >/dev/null 2>&1 || true
    udevadm settle
    sleep 1

    LBA_512_INDEX="$(nvme id-ns "$NVME_DEV" 2>/dev/null | awk '/lbads:9/ {print $2}' | tr -dc '0-9' | head -n1 || true)"
    if [[ -n "$LBA_512_INDEX" ]]; then
        nvme format "$NVME_DEV" -l "$LBA_512_INDEX" -s 1 --force 2>/dev/null || nvme format "$NVME_DEV" -l "$LBA_512_INDEX" --force
        partprobe "$NVME_DEV" 2>/dev/null || true
        udevadm settle
        sleep 2
    fi
    CUR_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size" 2>/dev/null || echo "unknown")"
    echo "  [OK] ${NVME_DEV} logical sector size reset to: ${CUR_LBA}B"
else
    CUR_LBA="none"
    echo "  [SKIP] Block device ${NVME_DEV} not present"
fi

echo "=== 4. Purging PostgreSQL 18, RVDK/BrakerRak Drop-Ins & Mount Directories ==="
apt-get -o DPkg::Lock::Timeout=120 purge -y "postgresql-18*" "postgresql-client-18*" "postgresql-common*" 2>/dev/null || true
apt-get -o DPkg::Lock::Timeout=120 autoremove -y --purge >/dev/null 2>&1 || true
rm -rf /etc/postgresql /etc/postgresql-common /var/lib/postgresql /var/log/postgresql
rm -rf /opt/drewv-pgdg-riscv64 "$MOUNT_POINT" "$NFS_MOUNT_POINT"

if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
    for mp in "${RAID_MOUNTS[@]}"; do
        [[ -n "$mp" ]] && rm -rf "${mp:?}"
    done
fi

rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/drewv-local-pgdg.list
rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
rm -f /etc/mosquitto/conf.d/brakerrak.conf \
      /etc/mosquitto/conf.d/99-brakerrak.conf \
      /etc/mosquitto/conf.d/99-rvdk-broker.conf
rm -f /etc/exports.d/rvdk-vaults.exports \
      /etc/exports.d/brakerrak-vaults.exports
rm -f /etc/systemd/system/postgresql@.service.d/90-rvdk-qos.conf \
      /etc/systemd/system/nfs-ganesha.service.d/90-rvdk-qos.conf \
      /etc/systemd/system/nfs-server.service.d/90-rvdk-qos.conf
rmdir --ignore-fail-on-non-empty \
      /etc/systemd/system/postgresql@.service.d \
      /etc/systemd/system/nfs-ganesha.service.d \
      /etc/systemd/system/nfs-server.service.d 2>/dev/null || true
if [[ -f /etc/ganesha/ganesha.conf ]] && grep -q "DREW-V Labs // RVDK" /etc/ganesha/ganesha.conf 2>/dev/null; then
    printf "# Reset by BrakerRak reset-day0.sh\n" > /etc/ganesha/ganesha.conf
fi
if [[ -f /etc/exports ]]; then
    sed -i '/# BRAKERRAK_NFS_BEGIN/,/# BRAKERRAK_NFS_END/d' /etc/exports 2>/dev/null || true
fi
exportfs -ra 2>/dev/null || true

if [[ "$KEEP_CACHE" == "true" ]] && ls /tmp/pgdg-deb-backup/*.deb >/dev/null 2>&1; then
    mkdir -p /opt/drewv-pgdg-riscv64/debs
    cp -a /tmp/pgdg-deb-backup/*.deb /opt/drewv-pgdg-riscv64/debs/
    echo "  [OK] Restored cached PostgreSQL .deb packages to /opt/drewv-pgdg-riscv64/debs"
fi
apt-get -o DPkg::Lock::Timeout=120 update -q || true

echo "=== 5. Reverting /etc/fstab, HugePages/DeepTune Sysctls & Hostname ==="
sed -i "\|${FS_LABEL}|d" /etc/fstab 2>/dev/null || true
sed -i "\|${NFS_FS_LABEL}|d" /etc/fstab 2>/dev/null || true
sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
sed -i "\|[[:space:]]${NFS_MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
    for lbl in "${RAID_LABELS[@]}"; do
        [[ -n "$lbl" ]] && sed -i "\|${lbl}|d" /etc/fstab 2>/dev/null || true
    done
fi

rm -f /etc/sysctl.d/90-rvdk-pg18-hugepages.conf \
      /etc/sysctl.d/90-brakerbox-broker.conf \
      /etc/sysctl.d/95-rvdk-deeptune.conf \
      /etc/udev/rules.d/95-rvdk-deeptune-io.rules \
      /etc/udev/rules.d/99-brakerrak-usb-raid.rules \
      /etc/systemd/system/rvdk-thp-tune.service \
      /etc/rvdk/deeptune.env \
      /var/lib/rvdk/deeptune.conf
systemctl daemon-reload

sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1 || true
udevadm control --reload-rules && udevadm trigger

if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$RESET_HOSTNAME"
else
    echo "$RESET_HOSTNAME" > /etc/hostname
    hostname "$RESET_HOSTNAME"
fi
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${RESET_HOSTNAME}/g" /etc/hosts 2>/dev/null || true

if [[ "$PURGE_CONFIG" == "true" && -f "$USER_NODE_ENV" ]]; then
    rm -f "$USER_NODE_ENV"
    echo "  [OK] Purged ${USER_NODE_ENV} (--purge-config)"
elif [[ -f "$USER_NODE_ENV" ]]; then
    echo "  [SKIP] Preserved ${USER_NODE_ENV} (pass --purge-config to delete)"
fi

echo ""
echo "=== [OK] Option A Day-0 Rollback Complete (Hostname: $(hostname), NVMe LBA: ${CUR_LBA}B) ==="
