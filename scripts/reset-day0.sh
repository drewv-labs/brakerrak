#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Shared Option A In-Place Day-0 Factory State Rollback
# Path: brakerrak/scripts/reset-day0.sh
# Description: Stops DataBroker services, unmounts NVMe & configured Btrfs RAID
#              vaults, resets NVMe to factory 512e (512-byte) LBA sectors, purges
#              PostgreSQL 18 & RVDK service drop-ins, and reverts Day-1 state.
#
# Usage:
#   sudo brakerrak reset --confirm-destroy                  # Full rollback (keeps node.env)
#   sudo brakerrak reset --confirm-destroy --keep-pg-cache  # Preserve local .deb cache
#   sudo brakerrak reset --confirm-destroy --skip-raid-wipe # Keep USB RAID vaults intact
#   sudo brakerrak reset --confirm-destroy --force-wipe-raid# Wipe non-OS rotational disks even without RAID config
#   sudo brakerrak reset --confirm-destroy --purge-config   # Also delete /etc/brakerrak/node.env
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-common.sh"
brak_log_init "RESET"

usage() {
    cat <<'EOF'
Usage: sudo brakerrak reset --confirm-destroy [options]

Options:
  --confirm-destroy         Required safety confirmation for destructive Day-0 rollback
  --config <path>           Load additional node configuration from key-value env file
  --keep-pg-cache           Preserve local PostgreSQL .deb cache across rollback
  --skip-raid-wipe          Leave all rotational USB/SATA RAID disks untouched
  --force-wipe-raid         Explicitly wipe non-OS rotational disks even if WITH_RAID!=true
  --purge-config            Also delete /etc/brakerrak/node.env (and legacy ~/.brakerrak/node.env)
  --hostname <name>         Override factory reset hostname
  -h, --help                Show this help message and exit
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        log_fatal "Run as root or via 'sudo brakerrak reset --confirm-destroy'."
    fi
fi

brak_resolve_user
brak_resolve_node_env
USER_NODE_ENV="$NODE_ENV"

NVME_DEV="/dev/nvme0n1"
MOUNT_POINT="/mnt/nvme_pgdata"
NFS_MOUNT_POINT="/mnt/nfs_vault"
FS_LABEL="PGDATA_NVME"
NFS_FS_LABEL="NFS_VAULT"
VG_NAME="vg_braker"
LV_NAME="lv_pgdata"
NFS_LV_NAME="lv_nfsvault"
WITH_RAID="false"
RAID_ARRAYS_JSON='[]'

if [[ -r "$USER_NODE_ENV" ]]; then
    brak_load_kv_env "$USER_NODE_ENV" || log_fatal "Failed to parse node config: ${USER_NODE_ENV}"
fi

# Auto-detect factory hostname default from Device Tree + /etc/os-release (safe non-executing parse)
DT_MODEL="Unknown"
if [[ -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi
OS_ID="debian"
if [[ -r /etc/os-release ]]; then
    OS_ID="$(awk -F= '/^ID=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print tolower($0); exit}' /etc/os-release 2>/dev/null || echo "debian")"
    [[ -z "$OS_ID" ]] && OS_ID="debian"
fi
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
FORCE_WIPE_RAID="false"
PURGE_CONFIG="false"
RESET_HOSTNAME="$DEFAULT_RESET_HOST"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            brak_require_arg "$1" "${2:-}"
            [[ ! -r "$2" ]] && log_fatal "Config file not found or unreadable: $2"
            brak_load_kv_env "$2" || log_fatal "Failed to parse config file: $2"
            shift 2
            ;;
        --config=*)
            _cfg="${1#*=}"
            brak_require_arg "--config" "$_cfg"
            [[ ! -r "$_cfg" ]] && log_fatal "Config file not found or unreadable: $_cfg"
            brak_load_kv_env "$_cfg" || log_fatal "Failed to parse config file: $_cfg"
            shift
            ;;
        --confirm-destroy) CONFIRM_DESTROY="true"; shift ;;
        --keep-pg-cache)   KEEP_CACHE="true"; shift ;;
        --skip-raid-wipe)  SKIP_RAID_WIPE="true"; shift ;;
        --force-wipe-raid) FORCE_WIPE_RAID="true"; shift ;;
        --purge-config)    PURGE_CONFIG="true"; shift ;;
        --hostname)
            brak_require_arg "$1" "${2:-}"
            RESET_HOSTNAME="$2"
            shift 2
            ;;
        --hostname=*)
            RESET_HOSTNAME="${1#*=}"
            brak_require_arg "--hostname" "$RESET_HOSTNAME"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_fatal "Unknown option: $1 (try --help)"
            ;;
    esac
done

if [[ "$CONFIRM_DESTROY" != "true" ]]; then
    log_fatal "Destructive Day-0 rollback requires --confirm-destroy flag."
fi

# ==============================================================================
# Safety Interlocks: Root / Boot / EFI / LVM Mapper / Multi-Mount / Swap Guards
# ==============================================================================
_reset_collect_leaf_disks() {
    local kname="$1"
    [[ -n "$kname" ]] || return 0

    local slave_dir="/sys/class/block/${kname}/slaves"
    if [[ -d "$slave_dir" ]] && compgen -G "${slave_dir}/*" >/dev/null 2>&1; then
        local s
        for s in "${slave_dir}"/*; do
            [[ -e "$s" ]] || continue
            _reset_collect_leaf_disks "$(basename "$s")"
        done
        return 0
    fi

    local pk=""
    if command -v lsblk >/dev/null 2>&1 && [[ -b "/dev/${kname}" ]]; then
        pk="$(lsblk -ndo PKNAME "/dev/${kname}" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    fi
    if [[ -z "$pk" && -L "/sys/class/block/${kname}" ]]; then
        local sys_real parent_base
        sys_real="$(readlink -f "/sys/class/block/${kname}" 2>/dev/null || true)"
        parent_base="$(basename "$(dirname "$sys_real")")"
        if [[ -n "$parent_base" && "$parent_base" != "block" && -e "/sys/block/${parent_base}" ]]; then
            pk="$parent_base"
        fi
    fi

    if [[ -n "$pk" && "$pk" != "$kname" ]]; then
        _reset_collect_leaf_disks "$pk"
    else
        printf '%s\n' "$kname"
    fi
}

_reset_source_touches_disk() {
    local src_dev="$1"
    local target_kname="$2"
    [[ -n "$src_dev" && -n "$target_kname" ]] || return 1

    # Strip Btrfs subvolume suffix e.g. /dev/nvme0n1p2[/@]
    src_dev="${src_dev%%\[*}"
    [[ "$src_dev" == /dev/* ]] || return 1

    local src_real src_kname
    src_real="$(readlink -f "$src_dev" 2>/dev/null || echo "$src_dev")"
    src_kname="$(basename "$src_real")"
    [[ -n "$src_kname" ]] || return 1

    if [[ "$src_kname" == "$target_kname" ]]; then
        return 0
    fi

    local leaf
    while IFS= read -r leaf; do
        [[ -n "$leaf" ]] || continue
        if [[ "$leaf" == "$target_kname" ]]; then
            return 0
        fi
    done < <(_reset_collect_leaf_disks "$src_kname")

    return 1
}

# Returns 0 if <dev> backs /, /boot, /boot/efi, critical OS paths, an active root/boot
# LVM/mapper/md volume, multi-mount, or any active swap device.
_reset_device_is_protected() {
    local dev="$1"
    [[ -b "$dev" ]] || return 1

    local dev_real target_kname
    dev_real="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
    target_kname="$(basename "$dev_real")"

    # 1. Inspect lsblk MOUNTPOINTS (with fallback to MOUNTPOINT on older util-linux)
    local mnt_list="" mnt
    mnt_list="$(lsblk -nr -o MOUNTPOINTS "$dev" 2>/dev/null || lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)"
    while IFS= read -r mnt; do
        [[ -n "$mnt" ]] || continue
        case "$mnt" in
            /|/boot|/boot/*|/usr|/var|/var/log|/home|"[SWAP]")
                return 0
                ;;
        esac
    done <<< "$mnt_list"

    # 2. Inspect findmnt SOURCE for /, /boot, /boot/efi (catches LVM/dm-crypt/mapper stacks)
    if command -v findmnt >/dev/null 2>&1; then
        local crit_src
        while IFS= read -r crit_src; do
            [[ -n "$crit_src" ]] || continue
            if _reset_source_touches_disk "$crit_src" "$target_kname"; then
                return 0
            fi
        done < <(findmnt -rn -o SOURCE / /boot /boot/efi 2>/dev/null || true)
    fi

    # 3. Inspect /proc/swaps (direct partitions AND LVM/dm swap volumes)
    if [[ -r /proc/swaps ]]; then
        local swap_src
        while IFS= read -r swap_src; do
            [[ -n "$swap_src" ]] || continue
            if _reset_source_touches_disk "$swap_src" "$target_kname"; then
                return 0
            fi
        done < <(awk 'NR > 1 && $1 ~ /^\/dev\// {print $1}' /proc/swaps 2>/dev/null || true)
    fi

    return 1
}

if [[ -b "$NVME_DEV" ]] && _reset_device_is_protected "$NVME_DEV"; then
    log_fatal "Safety Interlock: ${NVME_DEV} backs an active OS filesystem (/, /boot, /boot/efi), root LVM/mapper volume, or active swap! Aborting."
fi

export DEBIAN_FRONTEND=noninteractive
NVME_SHORT="$(basename "$NVME_DEV")"

RAID_MOUNTS=()
RAID_LABELS=()
RAID_MDS=()
RAID_EXPLICIT_DEVS=()
RAID_MIN_BYTES=()
RAID_MAX_BYTES=()
RAID_ARRAY_COUNT=0

if command -v jq >/dev/null 2>&1; then
    RAID_ARRAY_COUNT="$(jq 'if type=="array" then length else 0 end' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || echo 0)"
    if [[ "$RAID_ARRAY_COUNT" =~ ^[0-9]+$ ]] && (( RAID_ARRAY_COUNT > 0 )); then
        mapfile -t RAID_MOUNTS        < <(jq -r '.[].mount // empty' <<< "$RAID_ARRAYS_JSON")
        mapfile -t RAID_LABELS        < <(jq -r '.[].label // empty' <<< "$RAID_ARRAYS_JSON")
        mapfile -t RAID_MDS           < <(jq -r '.[].md_dev // empty' <<< "$RAID_ARRAYS_JSON")
        mapfile -t RAID_EXPLICIT_DEVS < <(jq -r '.[].devices[]? // empty' <<< "$RAID_ARRAYS_JSON")
        mapfile -t RAID_MIN_BYTES     < <(jq -r '.[] | (.min_bytes // 0) | tostring' <<< "$RAID_ARRAYS_JSON")
        mapfile -t RAID_MAX_BYTES     < <(jq -r '.[] | (.max_bytes // 0) | tostring' <<< "$RAID_ARRAYS_JSON")
    else
        RAID_ARRAY_COUNT=0
    fi
fi

RUNTIME_DIR="$(brak_runtime_dir)"
PGDG_BACKUP_DIR="${RUNTIME_DIR}/pgdg-deb-backup"

echo "=== 1. Stopping DataBroker Services & Handling .deb Cache (keep_cache=${KEEP_CACHE}) ==="
systemctl stop postgresql "postgresql@*" mosquitto nfs-kernel-server nfs-server.service nfs-ganesha.service rvdk-thp-tune.service 2>/dev/null || true
systemctl disable nfs-kernel-server nfs-server.service nfs-ganesha.service mosquitto rvdk-thp-tune.service 2>/dev/null || true
systemctl reset-failed proc-fs-nfsd.mount nfs-server.service nfs-ganesha.service nfs-ganesha-lock.service mosquitto.service 2>/dev/null || true
pkill -9 -u postgres 2>/dev/null || true

RVDK_PG_DEBS="/var/lib/rvdk/pgdg-riscv64/debs"
if [[ "$KEEP_CACHE" == "true" ]]; then
    install -d -m 0700 -o 0 -g 0 "$PGDG_BACKUP_DIR"
    cp -a "${RVDK_PG_DEBS}/"*.deb "${PGDG_BACKUP_DIR}/" 2>/dev/null || \
    cp -a /opt/drewv-pgdg-riscv64/debs/*.deb "${PGDG_BACKUP_DIR}/" 2>/dev/null || \
    cp -a "${MOUNT_POINT}/.pkg-cache/pgdg-riscv64/"*.deb "${PGDG_BACKUP_DIR}/" 2>/dev/null || true
else
    rm -rf "$PGDG_BACKUP_DIR"
fi

echo "=== 2. Unmounting Storage Tiers & Handling Rotational RAID Disks ==="
for mp in "$NFS_MOUNT_POINT" "$MOUNT_POINT" ${RAID_MOUNTS[@]+"${RAID_MOUNTS[@]}"}; do
    [[ -z "$mp" ]] && continue
    if mountpoint -q "$mp" 2>/dev/null; then
        fuser -km "$mp" 2>/dev/null || true
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        log_ok "Unmounted $mp"
    fi
done

if [[ "$SKIP_RAID_WIPE" == "true" ]]; then
    log_skip "Preserved rotational USB RAID disks (--skip-raid-wipe)"
elif [[ "$WITH_RAID" != "true" && "$RAID_ARRAY_COUNT" -eq 0 && "$FORCE_WIPE_RAID" != "true" ]]; then
    log_skip "No RAID arrays configured (WITH_RAID=${WITH_RAID}, RAID_ARRAYS_JSON=[]); rotational disks left untouched (pass --force-wipe-raid to override)"
else
    # Record member leaf disks of configured md arrays BEFORE stopping them
    MD_MEMBER_DISKS=()
    for md in ${RAID_MDS[@]+"${RAID_MDS[@]}"}; do
        [[ -n "$md" && -b "$md" ]] || continue
        _md_real="$(readlink -f "$md" 2>/dev/null || echo "$md")"
        _md_kname="$(basename "$_md_real")"
        while IFS= read -r _leaf; do
            [[ -n "$_leaf" ]] && MD_MEMBER_DISKS+=("/dev/${_leaf}")
        done < <(_reset_collect_leaf_disks "$_md_kname")
    done

    for md in ${RAID_MDS[@]+"${RAID_MDS[@]}"}; do
        [[ -n "$md" ]] && mdadm --stop "$md" 2>/dev/null || true
    done

    while IFS= read -r _disk_line; do
        [[ -n "$_disk_line" ]] || continue
        d_path="$(awk '{print $1}' <<< "$_disk_line")"
        d_size="$(awk '{print $2}' <<< "$_disk_line")"
        d_rota="$(awk '{print $3}' <<< "$_disk_line")"
        d_type="$(awk '{print $4}' <<< "$_disk_line")"
        [[ "$d_type" == "disk" && "$d_rota" == "1" ]] || continue
        [[ "$d_path" == /dev/nvme* || "$d_path" == /dev/mmcblk* || "$d_path" == /dev/zram* ]] && continue

        # NEVER wipe any disk backing /, /boot, /boot/efi, OS LVM, or active swap
        if _reset_device_is_protected "$d_path"; then
            log_skip "Safety Interlock: skipping protected rotational disk ${d_path}"
            continue
        fi

        d_real="$(readlink -f "$d_path" 2>/dev/null || echo "$d_path")"
        should_wipe="false"
        wipe_reason=""

        # (a) Explicit RAID_ARRAYS_JSON device, configured md_dev membership, or configured FS label
        for exp_d in ${RAID_EXPLICIT_DEVS[@]+"${RAID_EXPLICIT_DEVS[@]}"}; do
            [[ -n "$exp_d" ]] || continue
            exp_real="$(readlink -f "$exp_d" 2>/dev/null || echo "$exp_d")"
            if [[ "$d_path" == "$exp_d" || "$d_real" == "$exp_real" ]]; then
                should_wipe="true"
                wipe_reason="configured RAID_ARRAYS_JSON device"
                break
            fi
        done

        if [[ "$should_wipe" != "true" ]]; then
            for md_mem in ${MD_MEMBER_DISKS[@]+"${MD_MEMBER_DISKS[@]}"}; do
                [[ -n "$md_mem" ]] || continue
                md_mem_real="$(readlink -f "$md_mem" 2>/dev/null || echo "$md_mem")"
                if [[ "$d_path" == "$md_mem" || "$d_real" == "$md_mem_real" ]]; then
                    should_wipe="true"
                    wipe_reason="configured md_dev member"
                    break
                fi
            done
        fi

        if [[ "$should_wipe" != "true" && ${#RAID_LABELS[@]} -gt 0 ]]; then
            _disk_labels="$(lsblk -nr -o LABEL "$d_path" 2>/dev/null || true)"
            _blk_lbl="$(blkid -s LABEL -o value "$d_path" 2>/dev/null || true)"
            [[ -n "$_blk_lbl" ]] && _disk_labels+=$'\n'"${_blk_lbl}"
            for cfg_lbl in "${RAID_LABELS[@]}"; do
                [[ -n "$cfg_lbl" ]] || continue
                if grep -Fxq "$cfg_lbl" <<< "$_disk_labels"; then
                    should_wipe="true"
                    wipe_reason="configured RAID label '${cfg_lbl}'"
                    break
                fi
            done
        fi

        # (b) WITH_RAID=true configured capacity bounds + btrfs / linux_raid_member signature
        if [[ "$should_wipe" != "true" && "$WITH_RAID" == "true" && "$RAID_ARRAY_COUNT" -gt 0 ]]; then
            _disk_fstypes="$(lsblk -nr -o FSTYPE "$d_path" 2>/dev/null || true)"
            _blk_type="$(blkid -s TYPE -o value "$d_path" 2>/dev/null || true)"
            [[ -n "$_blk_type" ]] && _disk_fstypes+=$'\n'"${_blk_type}"
            if grep -Eq '^(btrfs|linux_raid_member)$' <<< "$_disk_fstypes"; then
                for (( idx=0; idx<RAID_ARRAY_COUNT; idx++ )); do
                    _min_b="${RAID_MIN_BYTES[$idx]:-0}"
                    _max_b="${RAID_MAX_BYTES[$idx]:-0}"
                    if [[ "$d_size" =~ ^[0-9]+$ && "$_min_b" =~ ^[0-9]+$ && "$_max_b" =~ ^[0-9]+$ ]] \
                       && (( _min_b > 0 && _max_b >= _min_b && d_size >= _min_b && d_size <= _max_b )); then
                        should_wipe="true"
                        wipe_reason="configured RAID capacity bounds + RAID/Btrfs signature"
                        break
                    fi
                done
            fi
        fi

        # (c) Explicit --force-wipe-raid override
        if [[ "$should_wipe" != "true" && "$FORCE_WIPE_RAID" == "true" ]]; then
            should_wipe="true"
            wipe_reason="--force-wipe-raid override"
        fi

        if [[ "$should_wipe" == "true" ]]; then
            mdadm --zero-superblock "$d_path" 2>/dev/null || true
            wipefs -af "$d_path" >/dev/null 2>&1 || true
            log_ok "Wiped Btrfs/RAID superblocks on rotational disk ${d_path} (${wipe_reason})"
        else
            log_skip "Preserved unrelated rotational disk ${d_path} (no configured RAID match)"
        fi
    done < <(lsblk -b -dn -o PATH,SIZE,ROTA,TYPE 2>/dev/null || true)
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
    log_ok "${NVME_DEV} logical sector size reset to: ${CUR_LBA}B"
else
    CUR_LBA="none"
    log_skip "Block device ${NVME_DEV} not present"
fi

echo "=== 4. Purging PostgreSQL 18, RVDK/BrakerRak Drop-Ins & Mount Directories ==="
apt-get -o DPkg::Lock::Timeout=120 purge -y "postgresql-18*" "postgresql-client-18*" "postgresql-common*" 2>/dev/null || true
apt-get -o DPkg::Lock::Timeout=120 autoremove -y --purge >/dev/null 2>&1 || true
rm -rf /etc/postgresql /etc/postgresql-common /var/lib/postgresql /var/log/postgresql
rm -rf /var/lib/rvdk/pgdg-riscv64 /opt/drewv-pgdg-riscv64 "$MOUNT_POINT" "$NFS_MOUNT_POINT"

if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
    for mp in ${RAID_MOUNTS[@]+"${RAID_MOUNTS[@]}"}; do
        [[ -n "$mp" ]] && rm -rf "${mp:?}"
    done
fi

rm -f /etc/apt/sources.list.d/pgdg.list \
      /etc/apt/sources.list.d/rvdk-local-pgdg.list \
      /etc/apt/sources.list.d/drewv-local-pgdg.list \
      /var/lib/apt/lists/_opt_drewv-pgdg-riscv64* \
      /var/lib/apt/lists/_var_lib_rvdk_pgdg-riscv64*
rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
rm -f /etc/needrestart/conf.d/90-rvdk-stateful.conf
rm -f /etc/mosquitto/conf.d/brakerrak.conf \
      /etc/mosquitto/conf.d/99-brakerrak.conf \
      /etc/mosquitto/conf.d/99-rvdk-broker.conf
rm -f /etc/exports.d/rvdk-vaults.exports \
      /etc/exports.d/brakerrak-vaults.exports
rm -f /etc/systemd/system/mosquitto.service.d/90-rvdk-runtime.conf \
      /etc/systemd/system/postgresql@.service.d/90-rvdk-qos.conf \
      /etc/systemd/system/nfs-ganesha.service.d/90-rvdk-qos.conf \
      /etc/systemd/system/nfs-server.service.d/90-rvdk-qos.conf
rmdir --ignore-fail-on-non-empty \
      /etc/systemd/system/mosquitto.service.d \
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

if [[ "$KEEP_CACHE" == "true" ]] && compgen -G "${PGDG_BACKUP_DIR}/*.deb" >/dev/null 2>&1; then
    mkdir -p /var/lib/rvdk /var/lib/rvdk/pgdg-riscv64 "$RVDK_PG_DEBS"
    chmod 0755 /var/lib/rvdk /var/lib/rvdk/pgdg-riscv64 "$RVDK_PG_DEBS"
    cp -a "${PGDG_BACKUP_DIR}/"*.deb "$RVDK_PG_DEBS/"
    chmod 0644 "${RVDK_PG_DEBS}/"*.deb 2>/dev/null || true
    rm -rf "$PGDG_BACKUP_DIR"
    log_ok "Restored cached PostgreSQL .deb packages to ${RVDK_PG_DEBS}"
else
    rm -rf "$PGDG_BACKUP_DIR"
fi
apt-get -o DPkg::Lock::Timeout=120 update -q || true

echo "=== 5. Reverting /etc/fstab, HugePages/DeepTune Sysctls & Hostname ==="
sed -i "\|${FS_LABEL}|d" /etc/fstab 2>/dev/null || true
sed -i "\|${NFS_FS_LABEL}|d" /etc/fstab 2>/dev/null || true
sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
sed -i "\|[[:space:]]${NFS_MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
    for lbl in ${RAID_LABELS[@]+"${RAID_LABELS[@]}"}; do
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

if [[ "$PURGE_CONFIG" == "true" ]]; then
    if [[ -f "$USER_NODE_ENV" ]]; then
        rm -f "$USER_NODE_ENV"
        log_ok "Purged ${USER_NODE_ENV} (--purge-config)"
    fi
    if [[ -z "${BRAKERRAK_NODE_ENV:-}" && -f "${REAL_HOME}/.brakerrak/node.env" ]]; then
        rm -f "${REAL_HOME}/.brakerrak/node.env"
        log_ok "Purged legacy ${REAL_HOME}/.brakerrak/node.env (--purge-config)"
    fi
elif [[ -f "$USER_NODE_ENV" ]]; then
    log_skip "Preserved ${USER_NODE_ENV} (pass --purge-config to delete)"
fi

echo ""
echo "=== [OK] Option A Day-0 Rollback Complete (Hostname: $(hostname), NVMe LBA: ${CUR_LBA}B) ==="
