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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-common.sh"

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

# ==============================================================================
# Safety Interlocks: Mountpoint Canonicalization, Root/Boot/Swap & LVM Guards
# ==============================================================================
_reset_lexical_normalize() {
    local raw="${1:-}"
    local IFS='/'
    local -a parts=() stack=()
    read -r -a parts <<< "$raw"
    local seg
    for seg in "${parts[@]}"; do
        case "$seg" in
            ""|".") continue ;;
            "..")
                if (( ${#stack[@]} > 0 )); then
                    unset 'stack[${#stack[@]}-1]'
                fi
                ;;
            *)
                stack+=("$seg")
                ;;
        esac
    done
    if (( ${#stack[@]} == 0 )); then
        printf '/\n'
    else
        local out=""
        for seg in "${stack[@]}"; do
            out+="/${seg}"
        done
        printf '%s\n' "$out"
    fi
}

_reset_canonicalize_path() {
    local raw="${1:-}"
    [[ -n "$raw" && "$raw" == /* ]] || return 1
    [[ "$raw" =~ [[:space:][:cntrl:]] ]] && return 1

    local canon=""
    if realpath -m / >/dev/null 2>&1; then
        canon="$(realpath -m -- "$raw" 2>/dev/null)" || return 1
    else
        # Pure-bash lexical normalization + prefix symlink resolution fallback
        canon="$(_reset_lexical_normalize "$raw")" || return 1
        local hop=0 resolved_changed="true"
        while [[ "$resolved_changed" == "true" ]]; do
            resolved_changed="false"
            local IFS='/'
            local -a segs=()
            read -r -a segs <<< "$canon"
            local prefix="" rest="" idx=0 seg tgt next_path j
            for (( idx = 0; idx < ${#segs[@]}; idx++ )); do
                seg="${segs[$idx]}"
                [[ -n "$seg" ]] || continue
                prefix+="/${seg}"
                if [[ "$prefix" == "/var" && "$(uname -s)" == "Darwin" ]]; then
                    continue
                fi
                if [[ -L "$prefix" ]]; then
                    hop=$(( hop + 1 ))
                    (( hop <= 32 )) || return 1
                    tgt="$(readlink "$prefix" 2>/dev/null)" || return 1
                    if [[ "$tgt" != /* ]]; then
                        local parent_dir="${prefix%/*}"
                        [[ -z "$parent_dir" ]] && parent_dir="/"
                        tgt="${parent_dir%/}/${tgt}"
                    fi
                    rest=""
                    for (( j = idx + 1; j < ${#segs[@]}; j++ )); do
                        [[ -n "${segs[$j]}" ]] && rest+="/${segs[$j]}"
                    done
                    next_path="${tgt}${rest}"
                    canon="$(_reset_lexical_normalize "$next_path")" || return 1
                    resolved_changed="true"
                    break
                fi
            done
        done
    fi

    if [[ "$(uname -s)" == "Darwin" && "$raw" == /var/lib/brakerrak/* && "$canon" == /private/var/lib/brakerrak/* ]]; then
        canon="${canon#/private}"
    fi
    printf '%s\n' "$canon"
}

# Returns 0 iff <path> canonicalizes under /mnt/<name>, /srv/<name>, or
# /var/lib/brakerrak/<name>, never targeting system roots or top-level dirs.
_reset_validate_rm_mountpoint() {
    local raw="${1:-}"
    [[ -n "$raw" && "$raw" == /* ]] || return 1
    [[ "$raw" =~ [[:space:][:cntrl:]] ]] && return 1

    local canon=""
    canon="$(_reset_canonicalize_path "$raw")" || return 1
    [[ -n "$canon" ]] || return 1
    [[ "$canon" =~ [[:space:][:cntrl:]] ]] && return 1

    case "$canon" in
        /|/mnt|/srv|/var|/home|/etc|/usr|/root|/boot)
            return 1
            ;;
    esac

    if [[ ! "$canon" =~ ^/(mnt|srv|var/lib/brakerrak)/[^/]+ ]]; then
        return 1
    fi

    return 0
}

_reset_safe_rm_mountpoint() {
    local mp="${1:-}"
    [[ -n "$mp" ]] || return 0

    if ! _reset_validate_rm_mountpoint "$mp"; then
        log_fatal "Safety Interlock: refusing rm -rf on unsafe mountpoint path '${mp}'."
    fi

    local trimmed_mp="${mp%/}"
    [[ -n "$trimmed_mp" ]] || trimmed_mp="/"
    if [[ -L "$trimmed_mp" ]]; then
        log_fatal "Safety Interlock: refusing rm -rf on symlink mountpoint '${mp}'."
    fi

    local canon_mp=""
    canon_mp="$(_reset_canonicalize_path "$mp")" || log_fatal "Safety Interlock: failed to canonicalize '${mp}'."
    if [[ -L "$canon_mp" ]]; then
        log_fatal "Safety Interlock: refusing rm -rf on symlink target '${canon_mp}'."
    fi
    if mountpoint -q "$canon_mp" 2>/dev/null; then
        log_fatal "Safety Interlock: refusing rm -rf while '${canon_mp}' is still mounted."
    fi
    if command -v findmnt >/dev/null 2>&1 && [[ -e "$canon_mp" ]]; then
        if [[ -n "$(findmnt -rn -R "$canon_mp" 2>/dev/null || true)" ]]; then
            log_fatal "Safety Interlock: refusing rm -rf while submounts exist under '${canon_mp}'."
        fi
    fi

    rm -rf -- "${canon_mp:?}"
}

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

    # Walk both slave devices (dm/md -> partition) and parent disks (partition -> whole disk)
    local -a queue=("$src_kname")
    local -a visited=()
    local cur s s_name pk sys_real parent_base seen v slave_dir
    while (( ${#queue[@]} > 0 )); do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        seen="false"
        for v in ${visited[@]+"${visited[@]}"}; do
            if [[ "$v" == "$cur" ]]; then
                seen="true"
                break
            fi
        done
        [[ "$seen" == "true" ]] && continue
        visited+=("$cur")

        if [[ "$cur" == "$target_kname" ]]; then
            return 0
        fi

        slave_dir="/sys/class/block/${cur}/slaves"
        if [[ -d "$slave_dir" ]] && compgen -G "${slave_dir}/*" >/dev/null 2>&1; then
            for s in "${slave_dir}"/*; do
                [[ -e "$s" ]] || continue
                s_name="$(basename "$s")"
                [[ -n "$s_name" ]] && queue+=("$s_name")
            done
        fi

        pk=""
        if command -v lsblk >/dev/null 2>&1 && [[ -b "/dev/${cur}" ]]; then
            pk="$(lsblk -ndo PKNAME "/dev/${cur}" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
        fi
        if [[ -z "$pk" && -L "/sys/class/block/${cur}" ]]; then
            sys_real="$(readlink -f "/sys/class/block/${cur}" 2>/dev/null || true)"
            parent_base="$(basename "$(dirname "$sys_real")")"
            if [[ -n "$parent_base" && "$parent_base" != "block" && -e "/sys/block/${parent_base}" ]]; then
                pk="$parent_base"
            fi
        fi
        if [[ -n "$pk" && "$pk" != "$cur" ]]; then
            queue+=("$pk")
        fi
    done

    return 1
}

_reset_is_block_device() {
    [[ -b "${1:-}" ]]
}

# Returns 0 if <dev> backs /, /boot, /boot/efi, critical OS paths, an active root/boot
# LVM/mapper/md volume, multi-mount, or any active swap device.
_reset_device_is_protected() {
    local dev="$1"
    _reset_is_block_device "$dev" || return 1

    local dev_real target_kname
    dev_real="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
    target_kname="$(basename "$dev_real")"

    # Check both the device itself and any underlying physical disks (catches sibling OS partitions)
    local -a target_knames=("$target_kname")
    local leaf
    while IFS= read -r leaf; do
        [[ -n "$leaf" && "$leaf" != "$target_kname" ]] && target_knames+=("$leaf")
    done < <(_reset_collect_leaf_disks "$target_kname")

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

    # 2. Inspect findmnt SOURCE per critical mountpoint + /proc/mounts fallback
    local -a crit_sources=()
    local _crit_mp crit_src tk
    if command -v findmnt >/dev/null 2>&1; then
        for _crit_mp in / /boot /boot/efi /usr /var /var/log /home; do
            crit_src="$(findmnt -rn -o SOURCE --target "$_crit_mp" 2>/dev/null || true)"
            [[ -n "$crit_src" ]] && crit_sources+=("$crit_src")
        done
    fi
    if [[ -r /proc/mounts ]]; then
        while IFS= read -r crit_src; do
            [[ -n "$crit_src" ]] && crit_sources+=("$crit_src")
        done < <(awk '$2 ~ /^\/(boot(\/.*)?|usr|var(\/log)?|home)?$/ && $1 ~ /^\/dev\// {print $1}' /proc/mounts 2>/dev/null || true)
    fi

    for crit_src in ${crit_sources[@]+"${crit_sources[@]}"}; do
        for tk in "${target_knames[@]}"; do
            if _reset_source_touches_disk "$crit_src" "$tk"; then
                return 0
            fi
        done
    done

    # 3. Inspect /proc/swaps (direct partitions AND LVM/dm swap volumes)
    if [[ -r /proc/swaps ]]; then
        local swap_src
        while IFS= read -r swap_src; do
            [[ -n "$swap_src" ]] || continue
            for tk in "${target_knames[@]}"; do
                if _reset_source_touches_disk "$swap_src" "$tk"; then
                    return 0
                fi
            done
        done < <(awk 'NR > 1 && $1 ~ /^\/dev\// {print $1}' /proc/swaps 2>/dev/null || true)
    fi

    return 1
}

# Validate single-label RFC 1123 hostname without spaces, slashes, or control chars.
_reset_validate_hostname() {
    local host="${1:-}"
    [[ -n "$host" ]] || return 1
    [[ "$host" =~ [[:space:][:cntrl:]] ]] && return 1
    (( ${#host} <= 63 )) || return 1

    local _rfc1123_re='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
    local _had_lc=0 _prev_lc=""
    if [[ -n "${LC_ALL+x}" ]]; then
        _had_lc=1
        _prev_lc="$LC_ALL"
    fi
    LC_ALL=C
    local _rc=1
    if [[ "$host" =~ $_rfc1123_re ]]; then
        _rc=0
    fi
    if (( _had_lc == 1 )); then
        LC_ALL="$_prev_lc"
    else
        unset LC_ALL
    fi
    return "$_rc"
}

# Safely rewrite 127.0.1.1 entries in hosts file via awk + brak_atomic_write.
_reset_update_hosts_file() {
    local new_hostname="${1:-}"
    local hosts_path="${2:-/etc/hosts}"
    if ! _reset_validate_hostname "$new_hostname"; then
        log_fatal "Invalid hostname '${new_hostname}' for hosts update: must match RFC 1123 (^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$)."
    fi
    [[ -f "$hosts_path" ]] || return 0

    local orig_mode="0644"
    orig_mode="$(stat -c '%a' "$hosts_path" 2>/dev/null || stat -f '%Lp' "$hosts_path" 2>/dev/null || echo "0644")"
    [[ "$orig_mode" =~ ^0?[0-7]{3,4}$ ]] || orig_mode="0644"

    local owner_group=""
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        owner_group="0:0"
    fi

    local tmp_hosts=""
    brak_mktemp -v tmp_hosts
    if ! BRAK_RESET_HOSTNAME="$new_hostname" awk '
        BEGIN { host = ENVIRON["BRAK_RESET_HOSTNAME"]; updated = 0 }
        /^[[:space:]]*(#|$)/ { print; next }
        $1 == "127.0.1.1" {
            if (!updated) {
                printf "127.0.1.1\t%s\n", host
                updated = 1
            }
            next
        }
        { print }
        END {
            if (!updated) {
                printf "127.0.1.1\t%s\n", host
            }
        }
    ' "$hosts_path" > "$tmp_hosts"; then
        rm -f -- "$tmp_hosts" 2>/dev/null || true
        log_fatal "Failed to rewrite hosts file '${hosts_path}'."
    fi

    brak_atomic_write "$hosts_path" "$orig_mode" "$owner_group" < "$tmp_hosts"
    rm -f -- "$tmp_hosts" 2>/dev/null || true
}

_reset_dev_is_mounted() {
    local dev="${1:-}"
    local proc_mounts_path="${2:-/proc/mounts}"
    [[ -n "$dev" ]] || return 1

    local dev_real
    dev_real="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"

    if command -v findmnt >/dev/null 2>&1; then
        local mnts=""
        mnts="$(findmnt -rn -o TARGET --source "$dev" 2>/dev/null || true)"
        if [[ -z "$mnts" && "$dev_real" != "$dev" ]]; then
            mnts="$(findmnt -rn -o TARGET --source "$dev_real" 2>/dev/null || true)"
        fi
        [[ -n "$mnts" ]] && return 0
    fi

    if command -v lsblk >/dev/null 2>&1; then
        local mnt_lines="" line=""
        mnt_lines="$(lsblk -nr -d -o MOUNTPOINTS "$dev" 2>/dev/null || lsblk -nr -d -o MOUNTPOINT "$dev" 2>/dev/null || true)"
        while IFS= read -r line; do
            [[ -n "$line" && "$line" != "[SWAP]" ]] && return 0
        done <<< "$mnt_lines"
    fi

    if [[ -r "$proc_mounts_path" ]]; then
        local src src_clean src_real
        while IFS= read -r src; do
            src_clean="${src%%\[*}"
            [[ "$src_clean" == /dev/* ]] || continue
            src_real="$(readlink -f "$src_clean" 2>/dev/null || echo "$src_clean")"
            if [[ "$src_clean" == "$dev" || "$src_real" == "$dev_real" ]]; then
                return 0
            fi
        done < <(awk '{print $1}' "$proc_mounts_path" 2>/dev/null || true)
    fi

    return 1
}

_reset_dev_tree_is_mounted() {
    local dev="${1:-}"
    local proc_mounts_path="${2:-/proc/mounts}"
    [[ -n "$dev" ]] || return 1

    if _reset_dev_is_mounted "$dev" "$proc_mounts_path"; then
        return 0
    fi

    if command -v lsblk >/dev/null 2>&1; then
        local mnt_lines="" line=""
        mnt_lines="$(lsblk -nr -o MOUNTPOINTS "$dev" 2>/dev/null || lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)"
        while IFS= read -r line; do
            [[ -n "$line" && "$line" != "[SWAP]" ]] && return 0
        done <<< "$mnt_lines"
    fi

    if [[ -r "$proc_mounts_path" ]]; then
        local dev_real target_kname
        dev_real="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
        target_kname="$(basename "$dev_real")"
        local src
        while IFS= read -r src; do
            [[ -n "$src" ]] || continue
            if _reset_source_touches_disk "$src" "$target_kname"; then
                return 0
            fi
        done < <(awk '$1 ~ /^\/dev\// {print $1}' "$proc_mounts_path" 2>/dev/null || true)
    fi

    return 1
}

_reset_report_active_holders() {
    local target="${1:-}"
    [[ -n "$target" ]] || return 0
    if command -v fuser >/dev/null 2>&1; then
        log_warn "Active holders on '${target}':"
        fuser -vm "$target" >&2 || true
    fi
}

_reset_strict_umount() {
    local target="${1:-}"
    [[ -n "$target" ]] || return 0

    local max_attempts=5
    local retry_sleep="${BRAKERRAK_UMOUNT_RETRY_SLEEP:-0.5}"
    local attempt=1
    local umount_err=""

    if command -v fuser >/dev/null 2>&1; then
        fuser -km "$target" 2>/dev/null || true
    fi

    while (( attempt <= max_attempts )); do
        if umount_err="$(umount "$target" 2>&1)"; then
            return 0
        fi
        if (( attempt < max_attempts )); then
            if command -v udevadm >/dev/null 2>&1; then
                udevadm settle 2>/dev/null || true
            fi
            if command -v sleep >/dev/null 2>&1; then
                sleep "$retry_sleep" 2>/dev/null || true
            fi
            if command -v fuser >/dev/null 2>&1; then
                fuser -km "$target" 2>/dev/null || true
            fi
        fi
        attempt=$(( attempt + 1 ))
    done

    [[ -n "$umount_err" ]] && log_warn "umount(${target}): ${umount_err}"
    _reset_report_active_holders "$target"
    log_fatal "Safety Interlock: failed to unmount '${target}' after ${max_attempts} attempts; aborting before destructive cleanup."
}

_reset_unmount_vg_devices() {
    local cand_vg="${1:-}"
    local mapper_dir="${2:-/dev/mapper}"
    local dev_root="${3:-/dev}"
    [[ -n "$cand_vg" ]] || return 0

    local vg_dm_prefix="${cand_vg//-/--}"
    local _had_nullglob=0
    shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    local -a dm_devs=("${mapper_dir}/${vg_dm_prefix}-"* "${dev_root}/${cand_vg}/"*)
    if (( _had_nullglob == 0 )); then
        shopt -u nullglob
    fi

    local dm_dev
    for dm_dev in ${dm_devs[@]+"${dm_devs[@]}"}; do
        _reset_is_block_device "$dm_dev" || continue
        if _reset_dev_is_mounted "$dm_dev"; then
            _reset_strict_umount "$dm_dev"
        fi
        if _reset_dev_tree_is_mounted "$dm_dev"; then
            _reset_report_active_holders "$dm_dev"
            log_fatal "Safety Interlock: '${dm_dev}' remains mounted after umount; aborting before vgremove."
        fi
    done
}

# Collect exact NVMe device + numeric partition nodes (never sibling namespaces like nvme0n10)
# and filter out any protected OS/swap device.
_reset_nvme_wipe_candidates() {
    local nvme_dev="${1:-}"
    [[ -n "$nvme_dev" ]] || return 0

    local _had_nullglob=0
    shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    local -a part_globs=("${nvme_dev}"p[0-9]*)
    if (( _had_nullglob == 0 )); then
        shopt -u nullglob
    fi

    local -a raw_candidates=("$nvme_dev")
    local part_cand part_suffix
    for part_cand in ${part_globs[@]+"${part_globs[@]}"}; do
        part_suffix="${part_cand#"${nvme_dev}p"}"
        if [[ "$part_suffix" =~ ^[0-9]+$ ]]; then
            raw_candidates+=("$part_cand")
        fi
    done

    local cand
    for cand in "${raw_candidates[@]}"; do
        _reset_is_block_device "$cand" || continue
        if _reset_device_is_protected "$cand"; then
            log_warn "Safety Interlock: excluding protected block device '${cand}' from NVMe wipe candidates."
            continue
        fi
        printf '%s\n' "$cand"
    done
}

_reset_wipe_nvme_targets() {
    local nvme_dev="${1:-}"
    [[ -n "$nvme_dev" ]] || return 0

    local -a wipe_cands=()
    local cand
    while IFS= read -r cand; do
        [[ -n "$cand" ]] && wipe_cands+=("$cand")
    done < <(_reset_nvme_wipe_candidates "$nvme_dev")

    # Phase 1: Validate protection and strictly unmount partitions BEFORE whole disk,
    # then verify no direct or descendant mounts remain on ANY candidate before wiping.
    for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
        if _reset_device_is_protected "$cand"; then
            log_fatal "Safety Interlock: refusing wipe on protected block device '${cand}'."
        fi
    done
    for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
        [[ "$cand" == "$nvme_dev" ]] && continue
        if _reset_dev_is_mounted "$cand"; then
            _reset_strict_umount "$cand"
        fi
    done
    for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
        [[ "$cand" == "$nvme_dev" ]] || continue
        if _reset_dev_is_mounted "$cand"; then
            _reset_strict_umount "$cand"
        fi
    done
    for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
        if _reset_dev_tree_is_mounted "$cand"; then
            _reset_report_active_holders "$cand"
            log_fatal "Safety Interlock: '${cand}' (or a descendant volume) remains mounted; aborting before NVMe wipe."
        fi
    done

    # Phase 2: Remove LVM PV labels (partitions before whole disk)
    if command -v pvremove >/dev/null 2>&1; then
        for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
            [[ "$cand" == "$nvme_dev" ]] && continue
            pvremove -ff -y "$cand" 2>/dev/null || true
        done
        for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
            [[ "$cand" == "$nvme_dev" ]] || continue
            pvremove -ff -y "$cand" 2>/dev/null || true
        done
    fi

    # Phase 3: Wipe partition signatures before whole-disk label metadata
    for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
        [[ "$cand" == "$nvme_dev" ]] && continue
        wipefs -af "$cand" >/dev/null 2>&1 || true
    done
    for cand in ${wipe_cands[@]+"${wipe_cands[@]}"}; do
        [[ "$cand" == "$nvme_dev" ]] || continue
        wipefs -af "$cand" >/dev/null 2>&1 || true
    done
}

# Atomically strip exact LABEL=<lbl> ($1) and mountpoint ($2) entries from /etc/fstab,
# creating a timestamped backup and preserving original file permissions without touching comments.
_reset_clean_fstab() {
    local fstab_path="${1:-/etc/fstab}"
    [[ -f "$fstab_path" ]] || return 0

    local -a target_labels=()
    local -a target_mounts=()
    [[ -n "${FS_LABEL:-}" ]] && target_labels+=("LABEL=${FS_LABEL}")
    [[ -n "${NFS_FS_LABEL:-}" ]] && target_labels+=("LABEL=${NFS_FS_LABEL}")

    local _raw_mp _norm_mp
    for _raw_mp in "${MOUNT_POINT:-}" "${NFS_MOUNT_POINT:-}"; do
        [[ -n "$_raw_mp" ]] || continue
        _norm_mp="${_raw_mp%/}"
        [[ -z "$_norm_mp" ]] && _norm_mp="/"
        case "$_norm_mp" in
            /|/boot|/boot/*|/usr|/var|/var/log|/home|/etc|/root)
                log_warn "Safety Interlock: ignoring protected mountpoint '${_raw_mp}' in fstab cleanup."
                continue
                ;;
        esac
        target_mounts+=("$_norm_mp")
    done

    if [[ "${SKIP_RAID_WIPE:-false}" == "false" ]]; then
        local lbl mp
        for lbl in ${RAID_LABELS[@]+"${RAID_LABELS[@]}"}; do
            [[ -n "$lbl" ]] && target_labels+=("LABEL=${lbl}")
        done
        for mp in ${RAID_MOUNTS[@]+"${RAID_MOUNTS[@]}"}; do
            [[ -n "$mp" ]] || continue
            _norm_mp="${mp%/}"
            [[ -z "$_norm_mp" ]] && _norm_mp="/"
            case "$_norm_mp" in
                /|/boot|/boot/*|/usr|/var|/var/log|/home|/etc|/root)
                    log_warn "Safety Interlock: ignoring protected RAID mountpoint '${mp}' in fstab cleanup."
                    continue
                    ;;
            esac
            target_mounts+=("$_norm_mp")
        done
    fi

    local orig_mode="0644"
    orig_mode="$(stat -c '%a' "$fstab_path" 2>/dev/null || stat -f '%Lp' "$fstab_path" 2>/dev/null || echo "0644")"
    [[ "$orig_mode" =~ ^0?[0-7]{3,4}$ ]] || orig_mode="0644"

    local ts bak_path fstab_dir tmp_fstab
    ts="$(date +%Y%m%d%H%M%S)"
    bak_path="${fstab_path}.brakerrak.bak.${ts}"
    cp -p "$fstab_path" "$bak_path"

    fstab_dir="$(dirname "$fstab_path")"
    tmp_fstab="$(mktemp "${fstab_dir}/.fstab.brak.XXXXXX")"
    _BRAK_OWNED_TMPFILES+=("${BASHPID:-$$}:${tmp_fstab}")
    brak_register_exit_hook _brak_cleanup_tmpfiles

    local labels_joined="" mounts_joined=""
    local IFS=$'\n'
    labels_joined="${target_labels[*]-}"
    mounts_joined="${target_mounts[*]-}"

    BRAK_FSTAB_LABELS="$labels_joined" BRAK_FSTAB_MOUNTS="$mounts_joined" awk '
        BEGIN {
            n_lbl = split(ENVIRON["BRAK_FSTAB_LABELS"], lbl_arr, "\n")
            for (i = 1; i <= n_lbl; i++) {
                if (lbl_arr[i] != "") drop_fs[lbl_arr[i]] = 1
            }
            n_mp = split(ENVIRON["BRAK_FSTAB_MOUNTS"], mp_arr, "\n")
            for (i = 1; i <= n_mp; i++) {
                mp_v = mp_arr[i]
                if (length(mp_v) > 1) sub(/\/+$/, "", mp_v)
                if (mp_v != "" && mp_v !~ /^\/(boot(\/.*)?|usr|var(\/log)?|home|etc|root)?$/) {
                    drop_mp[mp_v] = 1
                }
            }
        }
        /^[[:space:]]*($|#)/ { print; next }
        {
            if ($1 in drop_fs) next
            mp2 = $2
            if (length(mp2) > 1) sub(/\/+$/, "", mp2)
            if (mp2 in drop_mp) next
            print
        }
    ' "$fstab_path" > "$tmp_fstab"

    chmod "$orig_mode" "$tmp_fstab"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        chown 0:0 "$tmp_fstab" 2>/dev/null || true
    fi
    mv -f "$tmp_fstab" "$fstab_path"
}

# Parse `nvme id-ns` output (from device $1 or stdin) and select the 512-byte LBA format
# index (`lbads:9`) with zero metadata (`ms:0`) and the lowest `rp:` (best relative performance).
_reset_select_512_lbaf() {
    local id_ns_out=""
    if (( $# > 0 )) && [[ -n "${1:-}" ]]; then
        id_ns_out="$(nvme id-ns "$1" 2>/dev/null || true)"
    else
        id_ns_out="$(cat)"
    fi
    [[ -n "$id_ns_out" ]] || return 0

    awk '
        function parse_num(raw,    s, val, i, ch, d) {
            s = tolower(raw)
            if (s ~ /^0x[0-9a-f]+$/) {
                sub(/^0x/, "", s)
                val = 0
                for (i = 1; i <= length(s); i++) {
                    ch = substr(s, i, 1)
                    d = index("0123456789abcdef", ch) - 1
                    if (d < 0) return 999999
                    val = val * 16 + d
                }
                return val
            }
            if (s ~ /^[0-9]+$/) {
                return s + 0
            }
            return 999999
        }
        BEGIN { best_idx = ""; best_rp = 999999 }
        /^[[:space:]]*lbaf[[:space:]]+[0-9]+[[:space:]]*:/ {
            line = $0
            sub(/^[[:space:]]*lbaf[[:space:]]+/, "", line)
            idx = line
            sub(/[^0-9].*$/, "", idx)

            has_ms0 = 0
            has_lbads9 = 0
            rp_val = 999999
            n = split($0, toks, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                t = toks[i]
                if (t ~ /^ms:/) {
                    if (parse_num(substr(t, 4)) == 0) has_ms0 = 1
                } else if (t == "lbads:9") {
                    has_lbads9 = 1
                } else if (t ~ /^rp:/) {
                    rp_val = parse_num(substr(t, 4))
                }
            }
            if (has_ms0 && has_lbads9) {
                if (best_idx == "" || rp_val < best_rp) {
                    best_idx = idx
                    best_rp = rp_val
                }
            }
        }
        END {
            if (best_idx != "") print best_idx
        }
    ' <<< "$id_ns_out"
}

_reset_is_mcu_target() {
    local dt_model="${1:-${DT_MODEL:-}}"
    local target_arch="${2:-${TARGET_ARCH:-riscv64}}"
    local node_role="${3:-${NODE_ROLE:-}}"
    local target_board="${4:-${TARGET_BOARD:-}}"
    local stage_dir="${5:-${CLI_STAGE_DIR:-}}"

    if brak_is_riscv32_mcu_target "$target_board" "$target_arch" "$stage_dir"; then
        return 0
    fi
    if [[ "$node_role" == "snitchbench" || "$node_role" == "lilsnitch" ]]; then
        return 0
    fi
    local dt_lc=""
    dt_lc="$(tr '[:upper:]' '[:lower:]' <<< "$dt_model")"
    if [[ "$dt_lc" == *"esp32-p4"* || "$dt_lc" == *"esp32p4"* ]]; then
        return 0
    fi
    if [[ -z "$target_board" ]] && brak_resolve_silicon "${BRAKERRAK_TARGET:-}" "$dt_model" >/dev/null 2>&1; then
        if brak_is_riscv32_mcu_target "${TARGET_BOARD:-}" "$target_arch" "$stage_dir"; then
            return 0
        fi
    fi
    return 1
}

_reset_stop_databroker_services() {
    local is_mcu="${1:-false}"
    if [[ "$is_mcu" == "true" ]]; then
        log_skip "MCU/riscv32 target; skipped DataBroker service teardown"
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl stop postgresql "postgresql@*" mosquitto nfs-kernel-server nfs-server.service nfs-ganesha.service rvdk-thp-tune.service 2>/dev/null || true
        systemctl disable nfs-kernel-server nfs-server.service nfs-ganesha.service mosquitto rvdk-thp-tune.service 2>/dev/null || true
        systemctl reset-failed proc-fs-nfsd.mount nfs-server.service nfs-ganesha.service nfs-ganesha-lock.service mosquitto.service 2>/dev/null || true
        pkill -9 -u postgres 2>/dev/null || true
    fi
}

_reset_legacy_compat_enabled() {
    local raw="${BRAKERRAK_LEGACY_RVDK_COMPAT:-true}"
    case "$raw" in
        1|true|TRUE|yes|YES) return 0 ;;
        *)                   return 1 ;;
    esac
}

# Quarantined legacy RVDK cleanup used only when `rvdk reset` is unavailable and
# BRAKERRAK_LEGACY_RVDK_COMPAT=true (scheduled for removal).
_reset_legacy_rvdk_compat() {
    if ! _reset_legacy_compat_enabled; then
        log_fatal "Refusing _reset_legacy_rvdk_compat execution while BRAKERRAK_LEGACY_RVDK_COMPAT=false."
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=120 purge -y "postgresql-18*" "postgresql-client-18*" "postgresql-common*" 2>/dev/null || true
        apt-get -o DPkg::Lock::Timeout=120 autoremove -y --purge >/dev/null 2>&1 || true
    fi
    rm -rf /etc/postgresql /etc/postgresql-common /var/lib/postgresql /var/log/postgresql
    rm -rf /var/lib/rvdk/pgdg-riscv64 /opt/drewv-pgdg-riscv64

    rm -f /etc/apt/sources.list.d/pgdg.list \
          /etc/apt/sources.list.d/rvdk-local-pgdg.list \
          /etc/apt/sources.list.d/drewv-local-pgdg.list \
          /var/lib/apt/lists/_opt_drewv-pgdg-riscv64* \
          /var/lib/apt/lists/_var_lib_rvdk_pgdg-riscv64*
    rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    rm -f /etc/needrestart/conf.d/90-rvdk-stateful.conf
    rm -f /etc/mosquitto/conf.d/99-rvdk-broker.conf
    rm -f /etc/exports.d/rvdk-vaults.exports
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
    rm -f /etc/sysctl.d/90-rvdk-pg18-hugepages.conf \
          /etc/sysctl.d/95-rvdk-deeptune.conf \
          /etc/udev/rules.d/95-rvdk-deeptune-io.rules \
          /etc/systemd/system/rvdk-thp-tune.service \
          /etc/rvdk/deeptune.env \
          /var/lib/rvdk/deeptune.conf
}

_reset_rvdk_teardown() {
    local rvdk_cmd=""
    if [[ -n "${RVDK_BIN+x}" ]]; then
        if [[ -n "${RVDK_BIN}" && -x "${RVDK_BIN}" ]]; then
            rvdk_cmd="${RVDK_BIN}"
        fi
    elif command -v rvdk >/dev/null 2>&1; then
        rvdk_cmd="$(command -v rvdk)"
    fi

    if [[ -n "$rvdk_cmd" ]]; then
        log_brak "Delegating RVDK service & drop-in teardown to '${rvdk_cmd} reset'..."
        if "$rvdk_cmd" reset; then
            log_ok "Completed RVDK teardown via 'rvdk reset'"
            return 0
        fi
        if ! _reset_legacy_compat_enabled; then
            log_fatal "RVDK teardown failed: '${rvdk_cmd} reset' is unavailable or returned non-zero and BRAKERRAK_LEGACY_RVDK_COMPAT=false."
        fi
        log_warn "DEPRECATED: BRAKERRAK_LEGACY_RVDK_COMPAT fallback active (scheduled for removal; 'rvdk reset' delegation is canonical) — 'rvdk reset' failed or unsupported; running _reset_legacy_rvdk_compat."
    else
        if ! _reset_legacy_compat_enabled; then
            log_fatal "RVDK teardown failed: 'rvdk' CLI is unavailable and BRAKERRAK_LEGACY_RVDK_COMPAT=false (refusing direct mutation of RVDK internal paths)."
        fi
        log_warn "DEPRECATED: BRAKERRAK_LEGACY_RVDK_COMPAT fallback active (scheduled for removal; 'rvdk reset' delegation is canonical) — 'rvdk' CLI not found; running _reset_legacy_rvdk_compat."
    fi

    _reset_legacy_rvdk_compat
}

_reset_prevalidate_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                brak_require_arg "$1" "${2:-}"
                shift 2
                ;;
            --config=*)
                brak_require_arg "--config" "${1#*=}"
                shift
                ;;
            --hostname)
                brak_require_arg "$1" "${2:-}"
                if ! _reset_validate_hostname "$2"; then
                    log_fatal "Invalid --hostname '${2}': must match RFC 1123 (^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$)."
                fi
                shift 2
                ;;
            --hostname=*)
                local _hval="${1#*=}"
                brak_require_arg "--hostname" "$_hval"
                if ! _reset_validate_hostname "$_hval"; then
                    log_fatal "Invalid --hostname '${_hval}': must match RFC 1123 (^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$)."
                fi
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
}

_reset_main() {
    brak_log_init "RESET"

    local _arg
    for _arg in "$@"; do
        if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    _reset_prevalidate_cli_args "$@"

    if [[ $EUID -ne 0 ]]; then
        if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
            local _sudo_preserve_env="BRAKERRAK_NODE_ENV,BRAKERRAK_RUNTIME_DIR,BRAKERRAK_NO_PROGBAR,BRAKERRAK_TARGET,BRAKERRAK_ENGINE_DIR,BRAKERRAK_REPO_URL,BRAKERRAK_BRANCH,BRAKERRAK_BASE_URL,BRAKERRAK_LEGACY_RVDK_COMPAT,BRAKERRAK_PGDG_BACKUP_DIR,BRAKERRAK_UMOUNT_RETRY_SLEEP,RVDK_BIN,RVDK_ENV_FILE,RVDK_BASE_URL,RVDK_NO_PROGBAR,NO_PROGBAR,APT_UPDATED,TERM,COLORTERM,LINES,COLUMNS,LANG,LC_ALL"
            exec sudo --preserve-env="$_sudo_preserve_env" bash "${BASH_SOURCE[0]}" "$@"
        else
            log_fatal "Run as root or via 'sudo brakerrak reset --confirm-destroy'."
        fi
    fi

    brak_resolve_user
    brak_resolve_node_env
    USER_NODE_ENV="$NODE_ENV"

    TARGET_ARCH="riscv64"
    STORAGE_MEDIA="nvme"
    NODE_ROLE="databroker"
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

    local _cfg=""
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
                if ! _reset_validate_hostname "$2"; then
                    log_fatal "Invalid --hostname '${2}': must match RFC 1123 (^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$)."
                fi
                RESET_HOSTNAME="$2"
                shift 2
                ;;
            --hostname=*)
                RESET_HOSTNAME="${1#*=}"
                brak_require_arg "--hostname" "$RESET_HOSTNAME"
                if ! _reset_validate_hostname "$RESET_HOSTNAME"; then
                    log_fatal "Invalid --hostname '${RESET_HOSTNAME}': must match RFC 1123 (^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$)."
                fi
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

    if ! _reset_validate_hostname "$RESET_HOSTNAME"; then
        log_fatal "Invalid factory reset hostname '${RESET_HOSTNAME}': must match RFC 1123 (^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$)."
    fi

    if [[ "$CONFIRM_DESTROY" != "true" ]]; then
        log_fatal "Destructive Day-0 rollback requires --confirm-destroy flag."
    fi

    local _is_mcu_target="false"
    if _reset_is_mcu_target "$DT_MODEL" "${TARGET_ARCH:-riscv64}" "${NODE_ROLE:-}" "${TARGET_BOARD:-}"; then
        _is_mcu_target="true"
    fi
    local _skip_nvme_wipe="false"
    if [[ "$_is_mcu_target" == "true" || "${STORAGE_MEDIA:-nvme}" == "sd" ]]; then
        _skip_nvme_wipe="true"
    fi

    if [[ "$_skip_nvme_wipe" != "true" ]] && _reset_is_block_device "$NVME_DEV" && _reset_device_is_protected "$NVME_DEV"; then
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

    local _raid_json_compact="${RAID_ARRAYS_JSON//[[:space:]]/}"
    if [[ "$WITH_RAID" == "true" || ( -n "$_raid_json_compact" && "$_raid_json_compact" != "[]" ) ]]; then
        if ! command -v jq >/dev/null 2>&1; then
            log_fatal "RAID configuration active (WITH_RAID=${WITH_RAID}) but 'jq' is not installed; cannot parse RAID_ARRAYS_JSON."
        fi
    fi

    if command -v jq >/dev/null 2>&1; then
        if ! RAID_ARRAY_COUNT="$(jq -e 'if type=="array" then length else error("not an array") end' <<< "$RAID_ARRAYS_JSON" 2>/dev/null)"; then
            if [[ "$WITH_RAID" == "true" || ( -n "$_raid_json_compact" && "$_raid_json_compact" != "[]" ) ]]; then
                log_fatal "Invalid RAID_ARRAYS_JSON; cannot safely determine RAID targets."
            fi
            RAID_ARRAY_COUNT=0
        fi
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
    export BRAKERRAK_RUNTIME_DIR="$RUNTIME_DIR"
    PGDG_BACKUP_DIR="${BRAKERRAK_PGDG_BACKUP_DIR:-/var/cache/brakerrak/pgdg-deb-backup}"
    case "$PGDG_BACKUP_DIR" in
        ""|/|/var|/var/cache|/run|/run/*|/tmp|/etc|/usr|/home|/root|/boot)
            log_fatal "Safety Interlock: refusing unsafe or tmpfs PGDG_BACKUP_DIR '${PGDG_BACKUP_DIR}'."
            ;;
    esac

    echo "=== 1. Stopping DataBroker Services & Handling .deb Cache (keep_cache=${KEEP_CACHE}) ==="
    _reset_stop_databroker_services "$_is_mcu_target"

    RVDK_PG_DEBS="/var/lib/rvdk/pgdg-riscv64/debs"
    if [[ "$KEEP_CACHE" == "true" ]]; then
        if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
            install -d -m 0755 -o 0 -g 0 "$(dirname "$PGDG_BACKUP_DIR")"
            rm -rf -- "${PGDG_BACKUP_DIR:?}"
            install -d -m 0700 -o 0 -g 0 "$PGDG_BACKUP_DIR"
        else
            install -d -m 0755 "$(dirname "$PGDG_BACKUP_DIR")"
            rm -rf -- "${PGDG_BACKUP_DIR:?}"
            install -d -m 0700 "$PGDG_BACKUP_DIR"
        fi
        cp -a "${RVDK_PG_DEBS}/"*.deb "${PGDG_BACKUP_DIR}/" 2>/dev/null || \
        cp -a /opt/drewv-pgdg-riscv64/debs/*.deb "${PGDG_BACKUP_DIR}/" 2>/dev/null || \
        cp -a "${MOUNT_POINT}/.pkg-cache/pgdg-riscv64/"*.deb "${PGDG_BACKUP_DIR}/" 2>/dev/null || true
    else
        rm -rf -- "${PGDG_BACKUP_DIR:?}"
        rmdir --ignore-fail-on-non-empty /var/cache/brakerrak 2>/dev/null || true
    fi

    echo "=== 2. Unmounting Storage Tiers & Handling Rotational RAID Disks ==="
    local mp umount_target
    for mp in "$NFS_MOUNT_POINT" "$MOUNT_POINT" ${RAID_MOUNTS[@]+"${RAID_MOUNTS[@]}"}; do
        [[ -z "$mp" ]] && continue
        umount_target="$mp"
        if _reset_validate_rm_mountpoint "$mp"; then
            umount_target="$(_reset_canonicalize_path "$mp")"
        fi
        if mountpoint -q "$umount_target" 2>/dev/null; then
            _reset_strict_umount "$umount_target"
            if mountpoint -q "$umount_target" 2>/dev/null; then
                _reset_report_active_holders "$umount_target"
                log_fatal "Safety Interlock: '${umount_target}' remains mounted after umount! Aborting before destructive cleanup."
            fi
            log_ok "Unmounted $umount_target"
        fi
    done

    if [[ "$SKIP_RAID_WIPE" == "true" ]]; then
        log_skip "Preserved rotational USB RAID disks (--skip-raid-wipe)"
    elif [[ "$WITH_RAID" != "true" && "$RAID_ARRAY_COUNT" -eq 0 && "$FORCE_WIPE_RAID" != "true" ]]; then
        log_skip "No RAID arrays configured (WITH_RAID=${WITH_RAID}, RAID_ARRAYS_JSON=[]); rotational disks left untouched (pass --force-wipe-raid to override)"
    else
        # Record member leaf disks of configured md arrays BEFORE stopping them
        local -a MD_MEMBER_DISKS=()
        local md _md_real _md_kname _leaf
        for md in ${RAID_MDS[@]+"${RAID_MDS[@]}"}; do
            [[ -n "$md" ]] || continue
            _reset_is_block_device "$md" || continue
            if _reset_dev_is_mounted "$md"; then
                _reset_strict_umount "$md"
            fi
            if _reset_dev_tree_is_mounted "$md"; then
                _reset_report_active_holders "$md"
                log_fatal "Safety Interlock: '${md}' remains mounted after umount! Aborting before mdadm stop."
            fi
            _md_real="$(readlink -f "$md" 2>/dev/null || echo "$md")"
            _md_kname="$(basename "$_md_real")"
            while IFS= read -r _leaf; do
                [[ -n "$_leaf" ]] && MD_MEMBER_DISKS+=("/dev/${_leaf}")
            done < <(_reset_collect_leaf_disks "$_md_kname")
        done

        for md in ${RAID_MDS[@]+"${RAID_MDS[@]}"}; do
            [[ -n "$md" ]] && mdadm --stop "$md" 2>/dev/null || true
        done

        local _disk_line d_path d_size d_rota d_type d_real should_wipe wipe_reason
        local exp_d exp_real md_mem md_mem_real _disk_labels _blk_lbl cfg_lbl _disk_fstypes _blk_type idx _min_b _max_b
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
    if [[ "$_skip_nvme_wipe" == "true" ]]; then
        CUR_LBA="n/a (sd)"
        log_skip "SD media target (STORAGE_MEDIA=${STORAGE_MEDIA}, TARGET_ARCH=${TARGET_ARCH}); skipping LVM (${VG_NAME}) and NVMe 512e teardown"
    elif _reset_is_block_device "$NVME_DEV"; then
        local cand_vg pv_list pv_line pv_trimmed pv_count
        for cand_vg in "$VG_NAME" "vg_rvdk"; do
            [[ -z "$cand_vg" ]] && continue
            if command -v vgs >/dev/null 2>&1 && vgs "$cand_vg" >/dev/null 2>&1; then
                if ! pv_list="$(pvs --noheadings -o pv_name -S "vg_name=${cand_vg}" 2>/dev/null)"; then
                    log_fatal "Safety Interlock: unable to enumerate PVs for VG '${cand_vg}'. Aborting vgremove."
                fi
                pv_count=0
                while IFS= read -r pv_line; do
                    pv_trimmed="$(awk '{$1=$1; print}' <<< "$pv_line")"
                    [[ -n "$pv_trimmed" ]] || continue
                    pv_count=$(( pv_count + 1 ))
                    if ! _reset_is_block_device "$pv_trimmed"; then
                        log_fatal "Safety Interlock: VG '${cand_vg}' references unreadable/non-block PV '${pv_trimmed}'. Aborting vgremove."
                    fi
                    if _reset_device_is_protected "$pv_trimmed"; then
                        log_fatal "Safety Interlock: PV '${pv_trimmed}' in VG '${cand_vg}' backs a protected OS filesystem (/, /boot, /boot/efi) or active swap! Aborting vgremove."
                    fi
                done <<< "$pv_list"
                if (( pv_count == 0 )); then
                    log_fatal "Safety Interlock: VG '${cand_vg}' returned an empty PV list. Aborting vgremove."
                fi

                _reset_unmount_vg_devices "$cand_vg"
                lvchange -an "$cand_vg" 2>/dev/null || true
                vgchange -an "$cand_vg" 2>/dev/null || true
                vgremove -ff -y "$cand_vg" 2>/dev/null || true
            fi
            dmsetup remove "${cand_vg}-${LV_NAME}" "${cand_vg}-${NFS_LV_NAME}" 2>/dev/null || true
        done
        _reset_wipe_nvme_targets "$NVME_DEV"
        udevadm settle 2>/dev/null || true
        sleep 1

        if command -v nvme >/dev/null 2>&1; then
            if _reset_device_is_protected "$NVME_DEV"; then
                log_fatal "Safety Interlock: refusing nvme format on protected block device '${NVME_DEV}'."
            fi
            if _reset_dev_tree_is_mounted "$NVME_DEV"; then
                _reset_report_active_holders "$NVME_DEV"
                log_fatal "Safety Interlock: refusing nvme format while '${NVME_DEV}' or a descendant volume is mounted."
            fi
            LBA_512_INDEX="$(_reset_select_512_lbaf "$NVME_DEV" || true)"
            if [[ -n "$LBA_512_INDEX" ]]; then
                nvme format "$NVME_DEV" -l "$LBA_512_INDEX" -s 1 --force 2>/dev/null || nvme format "$NVME_DEV" -l "$LBA_512_INDEX" --force
                partprobe "$NVME_DEV" 2>/dev/null || true
                udevadm settle 2>/dev/null || true
                sleep 2
            else
                log_warn "No metadata-free 512B LBA format (ms:0 lbads:9) advertised by ${NVME_DEV}; skipping nvme format."
            fi
        else
            log_skip "nvme-cli not installed; skipping 512e LBA format on ${NVME_DEV}"
        fi
        CUR_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size" 2>/dev/null || echo "unknown")"
        log_ok "${NVME_DEV} logical sector size reset to: ${CUR_LBA}B"
    else
        CUR_LBA="none"
        log_skip "Block device ${NVME_DEV} not present; skipping LVM and NVMe 512e teardown"
    fi

    echo "=== 4. Purging PostgreSQL 18, RVDK/BrakerRak Drop-Ins & Mount Directories ==="
    _reset_rvdk_teardown

    _reset_safe_rm_mountpoint "$MOUNT_POINT"
    _reset_safe_rm_mountpoint "$NFS_MOUNT_POINT"

    if [[ "$SKIP_RAID_WIPE" == "false" ]]; then
        for mp in ${RAID_MOUNTS[@]+"${RAID_MOUNTS[@]}"}; do
            [[ -n "$mp" ]] && _reset_safe_rm_mountpoint "$mp"
        done
    fi

    rm -f /etc/mosquitto/conf.d/brakerrak.conf \
          /etc/mosquitto/conf.d/99-brakerrak.conf
    rm -f /etc/exports.d/brakerrak-vaults.exports
    if [[ -f /etc/exports ]]; then
        sed -i '/# BRAKERRAK_NFS_BEGIN/,/# BRAKERRAK_NFS_END/d' /etc/exports 2>/dev/null || true
    fi
    exportfs -ra 2>/dev/null || true

    if [[ "$KEEP_CACHE" == "true" ]] && compgen -G "${PGDG_BACKUP_DIR}/*.deb" >/dev/null 2>&1; then
        mkdir -p /var/lib/rvdk /var/lib/rvdk/pgdg-riscv64 "$RVDK_PG_DEBS"
        chmod 0755 /var/lib/rvdk /var/lib/rvdk/pgdg-riscv64 "$RVDK_PG_DEBS"
        cp -a "${PGDG_BACKUP_DIR}/"*.deb "$RVDK_PG_DEBS/"
        chmod 0644 "${RVDK_PG_DEBS}/"*.deb 2>/dev/null || true
        rm -rf -- "${PGDG_BACKUP_DIR:?}"
        rmdir --ignore-fail-on-non-empty /var/cache/brakerrak 2>/dev/null || true
        log_ok "Restored cached PostgreSQL .deb packages to ${RVDK_PG_DEBS}"
    else
        rm -rf -- "${PGDG_BACKUP_DIR:?}"
        rmdir --ignore-fail-on-non-empty /var/cache/brakerrak 2>/dev/null || true
    fi
    if [[ "$_is_mcu_target" != "true" ]] && command -v apt-get >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=120 update -q || true
    fi

    echo "=== 5. Reverting /etc/fstab, HugePages/DeepTune Sysctls & Hostname ==="
    _reset_clean_fstab /etc/fstab

    rm -f /etc/sysctl.d/90-brakerbox-broker.conf \
          /etc/udev/rules.d/99-brakerrak-usb-raid.rules
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1 || true
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null && udevadm trigger 2>/dev/null || true
    fi

    if [[ "$_is_mcu_target" == "true" ]]; then
        log_skip "MCU/riscv32 target; skipped host hostname mutation"
    elif command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$RESET_HOSTNAME"
    else
        local _hn_owner=""
        [[ "${EUID:-$(id -u)}" -eq 0 ]] && _hn_owner="0:0"
        printf '%s\n' "$RESET_HOSTNAME" | brak_atomic_write /etc/hostname 0644 "$_hn_owner"
        hostname "$RESET_HOSTNAME"
    fi
    if [[ "$_is_mcu_target" != "true" ]]; then
        _reset_update_hosts_file "$RESET_HOSTNAME" /etc/hosts
    fi

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

    local lba_disp="$CUR_LBA"
    if [[ "$lba_disp" =~ ^[0-9]+$ ]]; then
        lba_disp="${lba_disp}B"
    fi
    echo ""
    echo "=== [OK] Option A Day-0 Rollback Complete (Hostname: $(hostname), NVMe LBA: ${lba_disp}) ==="
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    set -Eeuo pipefail
    _reset_main "$@"
fi
