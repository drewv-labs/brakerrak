#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Config-Driven RVDK Harness & CLI (`brakerrak`)
# Path: brakerrak/forge.sh
#
# Usage (Remote Curl Bootstrap):
#   curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databroker --hostname jakebase-vf2
#   curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databench
#
# Usage (Local CLI after bootstrap or install-cli.sh):
#   sudo brakerrak [forge] [--role databroker|databench|devbench] [--hostname <name>] [--nfs-kernel|--nfs-ganesha|--nfs-auto] [--with-tailscale] [--no-apt-update] [--force-rebuild-pg] [--noprogbar]
#   sudo brakerrak ort [--stage day0-pre-forge|day1-post-forge]
#   sudo brakerrak verify [--role databroker|databench] [--force-rebuild-pg] [--noprogbar]
#   sudo brakerrak reset --confirm-destroy [--keep-pg-cache] [--skip-raid-wipe] [--purge-config]
#   sudo brakerrak update [--skip-rvdk]
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash`
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

SCRIPT_SELF="${BASH_SOURCE[0]:-}"
if [[ $EUID -ne 0 ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]]; then
        exec sudo -E bash "$SCRIPT_SELF" "$@"
    else
        echo "[BRAKERRAK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://brakerrak.dev/forge.sh | sudo bash" >&2
        exit 1
    fi
fi

# Sanitize SSH-forwarded LC_* (e.g. ZedBook / macOS SendEnv) before Day-0 locale-gen
if { locale -a 2>/dev/null || true; } | grep -qiE '^en_US\.utf-?8$'; then
    export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
elif { locale -a 2>/dev/null || true; } | grep -qiE '^C\.utf-?8$'; then
    export LANG="C.UTF-8" LC_ALL="C.UTF-8"
else
    export LANG="C" LC_ALL="C"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

if command -v getent >/dev/null 2>&1; then
    REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
elif command -v dscl >/dev/null 2>&1; then
    REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
else
    REAL_HOME=""
fi
[[ -z "$REAL_HOME" ]] && REAL_HOME="$(eval echo "~${REAL_USER}" 2>/dev/null || true)"
[[ -z "$REAL_HOME" || "$REAL_HOME" == "~"* ]] && REAL_HOME="/root"

BRAKER_DIR="${REAL_HOME}/.brakerrak"
ENGINE_DIR="${BRAKER_DIR}/engine"
NODE_ENV="${BRAKER_DIR}/node.env"
REPO_URL="${BRAKERRAK_REPO_URL:-https://github.com/drewv-labs/brakerrak.git}"
REPO_BRANCH="${BRAKERRAK_BRANCH:-main}"
BRAKERRAK_BASE_URL="${BRAKERRAK_BASE_URL:-https://brakerrak.dev}"
RVDK_BASE_URL="${RVDK_BASE_URL:-https://rvdk.drewv-labs.dev}"

# Track whether `apt-get update` has already run during this forge session (true|false)
# so subsequent RVDK modules receive `--no-apt-update`.
APT_UPDATED="${APT_UPDATED:-false}"
case "$APT_UPDATED" in
    1|true|TRUE|yes|YES) APT_UPDATED="true" ;;
    *)                   APT_UPDATED="false" ;;
esac

log_brak()  { printf "\033[1;35m[BRAKERRAK]\033[0m %s\n" "$1"; }
log_step()  { printf "\n\033[1;36m=== [%s] %s ===\033[0m\n" "$(date +%H:%M:%S)" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[BRAKERRAK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

# ==============================================================================
# 1. Parse Subcommand (forge | ort | verify | reset | update)
# ==============================================================================
ACTION="forge"
if [[ $# -gt 0 ]]; then
    case "$1" in
        forge|ort|verify|reset|update|self-update)
            ACTION="$1"
            shift
            ;;
    esac
fi

# ==============================================================================
# 2. Sync ~/.brakerrak/engine & Link /usr/local/bin/brakerrak
# ==============================================================================
if [[ -n "$SCRIPT_SELF" ]]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_SELF" 2>/dev/null || realpath "$SCRIPT_SELF" 2>/dev/null || echo "$SCRIPT_SELF")"
    CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
else
    CANDIDATE_ROOT=""
fi

if [[ "$ACTION" == "update" || "$ACTION" == "self-update" ]]; then
    RVDK_QUIET_ARGS=("--quiet")
    SKIP_RVDK_UPDATE="false"
    BRAK_UPDATE_ARGS=()
    for uarg in "$@"; do
        case "$uarg" in
            --skip-rvdk|--only-brakerrak) SKIP_RVDK_UPDATE="true" ;;
            -v|--verbose)                 RVDK_QUIET_ARGS=() ;;
            *)                            BRAK_UPDATE_ARGS+=("$uarg") ;;
        esac
    done

    if [[ "$SKIP_RVDK_UPDATE" != "true" ]]; then
        if [[ -x /usr/local/bin/rvdk ]]; then
            /usr/local/bin/rvdk update ${RVDK_QUIET_ARGS[@]+"${RVDK_QUIET_ARGS[@]}"}
        elif [[ -f "${REAL_HOME}/.rvdk/engine/install-cli.sh" ]]; then
            bash "${REAL_HOME}/.rvdk/engine/install-cli.sh" ${RVDK_QUIET_ARGS[@]+"${RVDK_QUIET_ARGS[@]}"}
        else
            curl -fsSL "${RVDK_BASE_URL}/install-cli.sh" | bash -s -- ${RVDK_QUIET_ARGS[@]+"${RVDK_QUIET_ARGS[@]}"}
        fi
    fi

    if [[ -f "${CANDIDATE_ROOT}/install-cli.sh" ]]; then
        exec bash "${CANDIDATE_ROOT}/install-cli.sh" ${BRAK_UPDATE_ARGS[@]+"${BRAK_UPDATE_ARGS[@]}"}
    else
        curl -fsSL "${BRAKERRAK_BASE_URL}/install-cli.sh" | bash -s -- ${BRAK_UPDATE_ARGS[@]+"${BRAK_UPDATE_ARGS[@]}"}
        exit 0
    fi
fi

# If symlinked into a different user's ~/.brakerrak/engine (e.g. factory 'user' after switching to admin user),
# clone/copy into the active user's ~/.brakerrak/engine so purging the factory user never breaks /usr/local/bin/brakerrak.
if [[ -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/soc-drawer" ]] && ! [[ "$CANDIDATE_ROOT" == */.brakerrak/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
else
    if [[ "$CANDIDATE_ROOT" == */.brakerrak/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" && -d "${CANDIDATE_ROOT}/.git" && ! -d "${ENGINE_DIR}/.git" ]]; then
        install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$BRAKER_DIR" "${BRAKER_DIR}/snapshots"
        cp -a "$CANDIDATE_ROOT" "$ENGINE_DIR"
        chown -R "${REAL_USER}:${REAL_GRP}" "$ENGINE_DIR"
    elif [[ -f "${CANDIDATE_ROOT}/install-cli.sh" ]]; then
        bash "${CANDIDATE_ROOT}/install-cli.sh" --quiet
    else
        if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                if [[ "$APT_UPDATED" != "true" ]]; then
                    apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || true
                    APT_UPDATED="true"
                fi
                apt-get -o DPkg::Lock::Timeout=120 install -y git ca-certificates curl
            else
                log_fatal "Missing git or curl."
            fi
        fi
        install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$BRAKER_DIR"
        if [[ -d "${ENGINE_DIR}/.git" ]]; then
            log_brak "Syncing BrakerRak engine in ${ENGINE_DIR}..."
            sudo -u "$REAL_USER" git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
            sudo -u "$REAL_USER" git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
        else
            log_brak "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
            rm -rf "$ENGINE_DIR"
            sudo -u "$REAL_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
        fi
    fi
    LOCAL_ROOT="$ENGINE_DIR"
fi

chmod +x "${LOCAL_ROOT}/forge.sh" "${LOCAL_ROOT}/install-cli.sh" "${LOCAL_ROOT}"/scripts/*.sh 2>/dev/null || true
install -d -m 0755 /usr/local/bin
ln -sf "${LOCAL_ROOT}/forge.sh" /usr/local/bin/brakerrak

# ==============================================================================
# 3. Route Shared Lifecycle Subcommands Immediately (ort | verify | reset)
# ==============================================================================
case "$ACTION" in
    ort)
        exec bash "${LOCAL_ROOT}/scripts/ort-snapshot.sh" "$@"
        ;;
    verify)
        exec bash "${LOCAL_ROOT}/scripts/verify-convergence.sh" "$@"
        ;;
    reset)
        exec bash "${LOCAL_ROOT}/scripts/reset-day0.sh" "$@"
        ;;
esac

# ==============================================================================
# 4. Parse CLI Flags & Overrides for 'forge'
# ==============================================================================
TARGET_BOARD="${BRAKERRAK_TARGET:-}"
CLI_ROLE=""
CLI_HOSTNAME=""
CLI_USER=""
CLI_SUBNET=""
CLI_NVME_DEV=""
CLI_MOUNT_POINT=""
CLI_WITH_RAID=""
CLI_ENABLE_MQTT=""
CLI_ENABLE_NFS=""
CLI_NFS_BACKEND=""
CLI_WITH_TAILSCALE="false"
CLI_TS_AUTHKEY=""
CLI_TS_FLAGS=()
FORCE_WIPE_NVME="false"
FORCE_WIPE_RAID="false"
FORCE_REBUILD_PG="false"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)                   TARGET_BOARD="${2:-}"; shift 2 ;;
        --role)                     CLI_ROLE="${2:-}"; shift 2 ;;
        --hostname)                 CLI_HOSTNAME="${2:-}"; shift 2 ;;
        --user)                     CLI_USER="${2:-}"; shift 2 ;;
        --subnet)                   CLI_SUBNET="${2:-}"; shift 2 ;;
        --nvme-dev)                 CLI_NVME_DEV="${2:-}"; shift 2 ;;
        --mount-point)              CLI_MOUNT_POINT="${2:-}"; shift 2 ;;
        --with-raid)                CLI_WITH_RAID="true"; shift ;;
        --no-raid)                  CLI_WITH_RAID="false"; shift ;;
        --with-mqtt)                CLI_ENABLE_MQTT="true"; shift ;;
        --no-mqtt)                  CLI_ENABLE_MQTT="false"; shift ;;
        --with-nfs)                 CLI_ENABLE_NFS="true"; shift ;;
        --no-nfs)                   CLI_ENABLE_NFS="false"; shift ;;
        --nfs-backend)              CLI_NFS_BACKEND="${2:-}"; shift 2 ;;
        --nfs-ganesha)              CLI_NFS_BACKEND="ganesha"; shift ;;
        --nfs-kernel|--nfs-kernal)  CLI_NFS_BACKEND="kernel"; shift ;;
        --nfs-auto)                 CLI_NFS_BACKEND="auto"; shift ;;
        --with-tailscale|--tailscale)
                                    CLI_WITH_TAILSCALE="true"; shift ;;
        --tailscale-up|--ts-up)
                                    CLI_WITH_TAILSCALE="true"; CLI_TS_FLAGS+=("--up"); shift ;;
        --tailscale-ssh|--ts-ssh)
                                    CLI_WITH_TAILSCALE="true"; CLI_TS_FLAGS+=("--ssh"); shift ;;
        --tailscale-authkey|--ts-authkey)
                                    CLI_WITH_TAILSCALE="true"; CLI_TS_AUTHKEY="${2:-}"; shift 2 ;;
        --tailscale-routes)
                                    CLI_WITH_TAILSCALE="true"; CLI_TS_FLAGS+=("--advertise-routes" "${2:-}"); shift 2 ;;
        --tailscale-userspace)
                                    CLI_WITH_TAILSCALE="true"; CLI_TS_FLAGS+=("--userspace"); shift ;;
        --no-apt-update|--skip-apt-update)
                                    APT_UPDATED="true"; shift ;;
        --force-wipe-nvme)          FORCE_WIPE_NVME="true"; shift ;;
        --force-wipe-raid)          FORCE_WIPE_RAID="true"; shift ;;
        --force-rebuild-pg|--force-build|--compile-pg|--no-pkg-cache)
                                    FORCE_REBUILD_PG="true"; shift ;;
        --use-pkg-cache)            FORCE_REBUILD_PG="false"; shift ;;
        --noprogbar|--no-progbar)   export BRAKERRAK_NO_PROGBAR="1"
                                    export RVDK_NO_PROGBAR="1"
                                    shift ;;
        *)                          FORWARD_ARGS+=("$1"); shift ;;
    esac
done

APT_STAMP_FILE="/run/brakerrak-apt-$$.stamp"
export RVDK_APT_STAMP_FILE="$APT_STAMP_FILE"
if [[ "$APT_UPDATED" != "true" ]]; then
    rm -f "$APT_STAMP_FILE" 2>/dev/null || true
fi

# Dispatch an RVDK subcommand while propagating `--no-apt-update` once APT_UPDATED=true
run_rvdk() {
    local subcmd="$1"
    shift
    if [[ "$APT_UPDATED" == "true" ]]; then
        /usr/local/bin/rvdk "$subcmd" --no-apt-update "$@"
    else
        /usr/local/bin/rvdk "$subcmd" "$@"
        if [[ -f "$APT_STAMP_FILE" ]]; then
            APT_UPDATED="true"
        fi
    fi
}

# ==============================================================================
# 5. Auto-Detect Silicon Target & Short Tag from /proc/device-tree/model
# ==============================================================================
DT_MODEL="Unknown"
if [[ -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi
if [[ -z "$TARGET_BOARD" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"EIC7700"*|*"Megrez"*)
            TARGET_BOARD="eswin-eic7700x"; TARGET_TAG="p550" ;;
        *"VisionFive 2"*|*"JH7110"*|*"Mars"*|*"OrangePi RV"*)
            TARGET_BOARD="starfive-jh7110"; TARGET_TAG="vf2" ;;
        *"Jupiter 2"*|*"SpacemiT K3"*|*"K3"*)
            TARGET_BOARD="spacemit-k3"; TARGET_TAG="jptr2" ;;
        *"Jupiter"*|*"SpacemiT"*|*"K1"*|*"M1"*|*"Ky X1"*|*"OrangePi RV2"*)
            TARGET_BOARD="spacemit-k1"; TARGET_TAG="jptr1" ;;
        *"Titan"*|*"DP1000"*)
            TARGET_BOARD="ultrarisc-dp1000"; TARGET_TAG="titan" ;;
        *)
            log_fatal "Could not auto-detect silicon target from Device Tree: '${DT_MODEL}'. Pass --target <board>." ;;
    esac
else
    case "$TARGET_BOARD" in
        eswin-eic7700x|sifive-p550) TARGET_BOARD="eswin-eic7700x"; TARGET_TAG="p550" ;;
        starfive-jh7110)            TARGET_TAG="vf2" ;;
        spacemit-k1)                TARGET_TAG="jptr1" ;;
        spacemit-k3)                TARGET_TAG="jptr2" ;;
        ultrarisc-dp1000)           TARGET_TAG="titan" ;;
        *)                          TARGET_TAG="node" ;;
    esac
fi

FACTORY_USER=""
case "$TARGET_BOARD" in
    starfive-jh7110) FACTORY_USER="user" ;;
esac

if [[ -f "${LOCAL_ROOT}/scripts/lib-progbar.sh" ]]; then
    # shellcheck disable=SC1091
    source "${LOCAL_ROOT}/scripts/lib-progbar.sh"
else
    brak_prog_init()    { :; }
    brak_prog()         { :; }
    brak_prog_cleanup() { :; }
fi

brak_prog_init "Resolving ${TARGET_BOARD} node configuration..."
log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) | Action: ${ACTION}"

# ==============================================================================
# 6. CONFIG RESOLUTION (Pass 1 Template Generation vs. Pass 2 node.env Load)
# ==============================================================================
install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$BRAKER_DIR"

# If Pass 1 was run from the factory default user (e.g. 'user' on JH7110) and we are now
# running as the designated admin user before purging 'user', pre-seed node.env from /home/<factory_user>
if [[ -n "$FACTORY_USER" && "$REAL_USER" != "$FACTORY_USER" && ! -f "$NODE_ENV" && -f "/home/${FACTORY_USER}/.brakerrak/node.env" ]]; then
    cp -a "/home/${FACTORY_USER}/.brakerrak/node.env" "$NODE_ENV"
    sed -i "s/^ADMIN_USER=\"${FACTORY_USER}\"/ADMIN_USER=\"${REAL_USER}\"/" "$NODE_ENV" 2>/dev/null || true
    chown "${REAL_USER}:${REAL_GRP}" "$NODE_ENV"
    chmod 0640 "$NODE_ENV"
    log_ok "Adopted Pass 1 node.env from /home/${FACTORY_USER}/.brakerrak/node.env -> ${NODE_ENV}"
fi

if [[ -f "$NODE_ENV" ]]; then
    FORGE_PASS="2"
    log_brak "Pass 2 Detected: Loading node configuration from ${NODE_ENV}"
    # shellcheck disable=SC1090
    source "$NODE_ENV"
else
    FORGE_PASS="1"
    NODE_ROLE="${CLI_ROLE:-databroker}"
fi

case "${CLI_ROLE:-$NODE_ROLE}" in
    prod|broker|databroker)
        NODE_ROLE="databroker"
        DEFAULT_HOST="brakerbox-${TARGET_TAG}"
        DEFAULT_MQTT="true"
        DEFAULT_NFS="true"
        ;;
    bench|databench)
        NODE_ROLE="databench"
        DEFAULT_HOST="brakerbench-${TARGET_TAG}"
        DEFAULT_MQTT="false"
        DEFAULT_NFS="false"
        ;;
    devbench)
        NODE_ROLE="devbench"
        DEFAULT_HOST="devbench-${TARGET_TAG}"
        DEFAULT_MQTT="true"
        DEFAULT_NFS="false"
        ;;
    *)
        log_fatal "Unknown role '${CLI_ROLE:-$NODE_ROLE}' (expected: databroker | databench | devbench)"
        ;;
esac

TARGET_HOSTNAME="${CLI_HOSTNAME:-${TARGET_HOSTNAME:-$DEFAULT_HOST}}"
ADMIN_USER="${CLI_USER:-${ADMIN_USER:-$REAL_USER}}"
LAB_SUBNET="${CLI_SUBNET:-${LAB_SUBNET:-10.0.10.0/24}}"
NVME_DEV="${CLI_NVME_DEV:-${NVME_DEV:-/dev/nvme0n1}}"
MOUNT_POINT="${CLI_MOUNT_POINT:-${MOUNT_POINT:-/mnt/nvme_pgdata}}"
WITH_RAID="${CLI_WITH_RAID:-${WITH_RAID:-false}}"
RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"
ENABLE_MQTT_BROKER="${CLI_ENABLE_MQTT:-${ENABLE_MQTT_BROKER:-$DEFAULT_MQTT}}"
MQTT_PORT="${MQTT_PORT:-1883}"
ENABLE_NFS_SERVER="${CLI_ENABLE_NFS:-${ENABLE_NFS_SERVER:-$DEFAULT_NFS}}"
NFS_BACKEND="${CLI_NFS_BACKEND:-${NFS_BACKEND:-ganesha}}"
SHARE_ORT_SNAPSHOT="${SHARE_ORT_SNAPSHOT:-false}"

NFS_BACKEND="$(tr '[:upper:]' '[:lower:]' <<< "$NFS_BACKEND")"
case "$NFS_BACKEND" in
    ganesha|nfs-ganesha|userspace)           NFS_BACKEND="ganesha" ;;
    kernel|nfs-kernel|nfs-kernal|knfsd|nfsd) NFS_BACKEND="kernel" ;;
    auto)                                    NFS_BACKEND="auto" ;;
    *)
        log_fatal "Unknown NFS_BACKEND '${NFS_BACKEND}' (expected: ganesha | kernel | auto)"
        ;;
esac

if [[ "$FORGE_PASS" == "1" ]]; then
    cat <<EOF > "$NODE_ENV"
# ==============================================================================
# DREW-V Labs // BrakerRak User Node Config (~/.brakerrak/node.env)
# Generated on Pass 1. Customize values below and re-run 'sudo brakerrak' for Pass 2.
# ==============================================================================
NODE_ROLE="${NODE_ROLE}"
TARGET_HOSTNAME="${TARGET_HOSTNAME}"
ADMIN_USER="${ADMIN_USER}"
LAB_SUBNET="${LAB_SUBNET}"

# Hot NVMe Storage
NVME_DEV="${NVME_DEV}"
MOUNT_POINT="${MOUNT_POINT}"

# Optional USB/SATA Btrfs RAID 10 Arrays (Default: false / empty array)
WITH_RAID="${WITH_RAID}"
RAID_ARRAYS_JSON='${RAID_ARRAYS_JSON}'

# DataBroker Network Services (When ENABLE_NFS_SERVER=true and WITH_RAID=false, exports \${MOUNT_POINT}/nfs_vault)
ENABLE_MQTT_BROKER="${ENABLE_MQTT_BROKER}"
MQTT_PORT="${MQTT_PORT}"
ENABLE_NFS_SERVER="${ENABLE_NFS_SERVER}"
# NFSv4 Server Backend: ganesha (default) | kernel (nfs-kernel-server override) | auto
NFS_BACKEND="${NFS_BACKEND}"

# Opt-In Community RISC-V Telemetry Commons
SHARE_ORT_SNAPSHOT="${SHARE_ORT_SNAPSHOT}"
EOF
    chown "${REAL_USER}:${REAL_GRP}" "$NODE_ENV"
    chmod 0640 "$NODE_ENV"
    log_ok "Generated Pass 1 node configuration: ${NODE_ENV}"
elif ! grep -q '^NFS_BACKEND=' "$NODE_ENV" 2>/dev/null; then
    printf '\n# NFSv4 Server Backend: ganesha (default) | kernel (nfs-kernel-server override) | auto\nNFS_BACKEND="%s"\n' "$NFS_BACKEND" >> "$NODE_ENV"
fi

export BRAKERRAK_NODE_ENV="$NODE_ENV"
export NODE_ROLE TARGET_HOSTNAME ADMIN_USER LAB_SUBNET NVME_DEV MOUNT_POINT WITH_RAID RAID_ARRAYS_JSON ENABLE_MQTT_BROKER MQTT_PORT ENABLE_NFS_SERVER NFS_BACKEND

# ==============================================================================
# 7. ENSURE RVDK CLI IS INSTALLED & DISPATCH MODULAR RVDK PIPELINE
# ==============================================================================
if [[ ! -x /usr/local/bin/rvdk ]]; then
    brak_prog 5 "Stage 0A: Installing RVDK CLI..." 0 "Cloning RVDK engine..."
    log_step "0A. Installing RVDK Package Manager CLI (${RVDK_BASE_URL}/install-cli.sh)"
    curl -fsSL "${RVDK_BASE_URL}/install-cli.sh" | bash -s -- --quiet
fi

brak_prog 8 "Stage 1/7: Day-0 OS & Silicon BSP (${TARGET_HOSTNAME})" 0 "Launching rvdk day0..."
log_step "1. RVDK Day-0 OS & Silicon BSP Convergence (Hostname: ${TARGET_HOSTNAME})"
run_rvdk day0 --user "$ADMIN_USER" --hostname "$TARGET_HOSTNAME" --nopasswd

brak_prog 28 "Stage 2/7: Hot NVMe 4Kn Storage (${NVME_DEV} -> ${MOUNT_POINT})" 0 "Launching rvdk mods/nvme-4kn..."
log_step "2. RVDK Hot NVMe 4Kn Storage Provisioning (${NVME_DEV} -> ${MOUNT_POINT})"
NVME_FLAGS=(--device "$NVME_DEV" --mount "$MOUNT_POINT")
[[ "$FORCE_WIPE_NVME" == "true" ]] && NVME_FLAGS+=(--force-wipe)
run_rvdk mods/nvme-4kn "${NVME_FLAGS[@]}"

brak_prog 45 "Stage 3/7: PostgreSQL 18.6 (io_uring + Sv39 HugePages)" 0 "Launching rvdk postgresql..."
log_step "3. RVDK PostgreSQL 18.6 Convergence (io_uring + Sv39 HugePages)"
PG_FLAGS=(--data-mount "$MOUNT_POINT" --subnet "$LAB_SUBNET")
[[ "$FORCE_REBUILD_PG" == "true" ]] && PG_FLAGS+=(--force-build)
run_rvdk postgresql "${PG_FLAGS[@]}"

if [[ "$WITH_RAID" == "true" ]]; then
    brak_prog 70 "Stage 4/7: Btrfs RAID 10 Vault Provisioning" 0 "Launching rvdk mods/btrfs-raid..."
    log_step "4. RVDK Btrfs RAID 10 Vault Provisioning & Tablespace Binding"
    RAID_FLAGS=()
    [[ "$FORCE_WIPE_RAID" == "true" ]] && RAID_FLAGS+=(--force-wipe-raid)
    run_rvdk mods/btrfs-raid ${RAID_FLAGS[@]+"${RAID_FLAGS[@]}"}
else
    brak_prog 74 "Stage 4/7: Btrfs RAID 10 Skipped (WITH_RAID=false)" 100 "mods/btrfs-raid skipped"
    log_step "4. Btrfs RAID 10 Vault Provisioning Skipped (WITH_RAID=false)"
fi

if [[ "$ENABLE_MQTT_BROKER" == "true" ]]; then
    brak_prog 78 "Stage 5A/7: Eclipse Mosquitto MQTT Broker (:${MQTT_PORT})" 0 "Launching rvdk mods/mosquitto..."
    log_step "5A. RVDK Eclipse Mosquitto MQTT Broker (:${MQTT_PORT} + Unix Socket)"
    run_rvdk mods/mosquitto --port "$MQTT_PORT" --data-mount "$MOUNT_POINT"
else
    brak_prog 82 "Stage 5A/7: Mosquitto MQTT Skipped (ENABLE_MQTT_BROKER=false)" 100 "mods/mosquitto skipped"
    log_step "5A. Mosquitto MQTT Broker Skipped (ENABLE_MQTT_BROKER=false)"
fi

if [[ "$ENABLE_NFS_SERVER" == "true" ]]; then
    brak_prog 86 "Stage 5B/7: NFSv4 Vault Exports (${NFS_BACKEND} -> ${LAB_SUBNET})" 0 "Launching rvdk mods/nfs-vault..."
    log_step "5B. RVDK NFSv4 Vault Exports (${NFS_BACKEND} -> ${LAB_SUBNET})"
    run_rvdk mods/nfs-vault --subnet "$LAB_SUBNET" --data-mount "$MOUNT_POINT" --backend "$NFS_BACKEND"
else
    brak_prog 90 "Stage 5B/7: NFSv4 Vault Server Skipped (ENABLE_NFS_SERVER=false)" 100 "mods/nfs-vault skipped"
    log_step "5B. NFSv4 Vault Server Skipped (ENABLE_NFS_SERVER=false)"
    if systemctl is-active --quiet nfs-server.service 2>/dev/null || systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
        systemctl disable --now nfs-kernel-server 2>/dev/null || systemctl disable --now nfs-server.service 2>/dev/null || true
        log_ok "Disabled nfs-kernel-server for benchmark isolation"
    fi
    if systemctl is-active --quiet nfs-ganesha.service 2>/dev/null; then
        systemctl disable --now nfs-ganesha.service 2>/dev/null || true
        log_ok "Disabled nfs-ganesha for benchmark isolation"
    fi
fi

if [[ "$CLI_WITH_TAILSCALE" == "true" ]]; then
    brak_prog 92 "Stage 5C: Tailscale Mesh VPN (--with-tailscale)" 0 "Launching rvdk mods/tailscale..."
    log_step "5C. RVDK Tailscale Mesh VPN (--with-tailscale)"
    if [[ -n "$CLI_TS_AUTHKEY" ]]; then
        TS_AUTHKEY="$CLI_TS_AUTHKEY" run_rvdk mods/tailscale --hostname "$TARGET_HOSTNAME" ${CLI_TS_FLAGS[@]+"${CLI_TS_FLAGS[@]}"}
    else
        run_rvdk mods/tailscale --hostname "$TARGET_HOSTNAME" ${CLI_TS_FLAGS[@]+"${CLI_TS_FLAGS[@]}"}
    fi
fi

# ==============================================================================
# 8. STAGE 6: POST-FLIGHT CONVERGENCE SUMMARY
# ==============================================================================
brak_prog 95 "Stage 6/7: Collecting Post-Flight Convergence Summary..." 100 "RVDK pipeline converged"
CPU_HARTS="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "?")"
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    CPU_GOV="$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor 2>/dev/null | sort -u | paste -sd/ -)"
else
    CPU_GOV="firmware-fixed"
fi
CPU_KHZ=""
for freq_file in \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq \
    /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq \
    /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq; do
    if [[ -r "$freq_file" ]]; then
        CPU_KHZ="$(tr -dc '0-9' < "$freq_file" 2>/dev/null || true)"
        [[ -n "$CPU_KHZ" ]] && break
    fi
done
if [[ -n "$CPU_KHZ" && "$CPU_KHZ" -gt 0 ]]; then
    CPU_CLOCK_INFO="${CPU_GOV} @ $(( CPU_KHZ / 1000 )) MHz (${CPU_HARTS} Harts)"
elif [[ -r /proc/device-tree/cpus/cpu@0/clock-frequency ]] && command -v python3 >/dev/null 2>&1; then
    DT_MHZ="$(python3 -c 'import pathlib; b=pathlib.Path("/proc/device-tree/cpus/cpu@0/clock-frequency").read_bytes(); print(int.from_bytes(b, "big") // 1000000)' 2>/dev/null || true)"
    if [[ -n "$DT_MHZ" && "$DT_MHZ" -gt 0 ]]; then
        CPU_CLOCK_INFO="${CPU_GOV} @ ${DT_MHZ} MHz (${CPU_HARTS} Harts)"
    else
        CPU_CLOCK_INFO="${CPU_GOV} (${CPU_HARTS} Harts)"
    fi
else
    CPU_CLOCK_INFO="${CPU_GOV} (${CPU_HARTS} Harts)"
fi

NVME_SHORT="$(basename "$NVME_DEV")"
LBA_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size" 2>/dev/null || echo "unknown")"
NVME_MNT_INFO="$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT" 2>/dev/null || echo "unmounted")"
PG_DATA_DIR="$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null | xargs || echo "unknown")"
PG_IO_METHOD="$(sudo -u postgres psql -tAc "SHOW io_method;" 2>/dev/null | xargs || echo "unknown")"
PG_SHBUF="$(sudo -u postgres psql -tAc "SHOW shared_buffers;" 2>/dev/null | xargs || echo "unknown")"
HP_TOTAL="$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
HP_FREE="$(awk '/HugePages_Free:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
HP_USED=$(( HP_TOTAL - HP_FREE ))
MQTT_STATE="$(systemctl is-active mosquitto 2>/dev/null || true)"
[[ -z "$MQTT_STATE" ]] && MQTT_STATE="inactive"
if systemctl is-active --quiet nfs-server.service 2>/dev/null; then
    NFS_STATE="active (kernel nfsd)"
elif systemctl is-active --quiet nfs-ganesha.service 2>/dev/null; then
    NFS_STATE="active (userspace nfs-ganesha)"
else
    NFS_STATE="inactive"
fi

TS_SUMMARY=""
if [[ "$CLI_WITH_TAILSCALE" == "true" ]] || systemctl is-active --quiet tailscaled.service 2>/dev/null; then
    if systemctl is-active --quiet tailscaled.service 2>/dev/null; then
        TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
        TS_SUMMARY="active (${TS_IP:-needs 'sudo tailscale up'})"
    else
        TS_SUMMARY="inactive"
    fi
fi

log_step "6. Post-Flight Verification Summary (Pass ${FORGE_PASS})"
printf "  • Hostname           : %s (Role: %s | Pass: %s)\n" "$(hostname)" "$NODE_ROLE" "$FORGE_PASS"
printf "  • Kernel / Arch      : %s (%s)\n" "$(uname -r)" "$(uname -m)"
printf "  • CPU Governor/Clock : %s\n" "$CPU_CLOCK_INFO"
printf "  • NVMe LBA Block Sz  : %s bytes\n" "$LBA_SZ"
printf "  • Hot NVMe Mount     : %s\n" "$NVME_MNT_INFO"
printf "  • PG Data Directory  : %s\n" "$PG_DATA_DIR"
printf "  • PG 18 Async I/O    : io_method = %s\n" "$PG_IO_METHOD"
printf "  • PG Shared Buffers  : %s (HugePages in use: %s / %s)\n" "$PG_SHBUF" "$HP_USED" "$HP_TOTAL"
printf "  • Mosquitto MQTT     : %s (Port %s)\n" "$MQTT_STATE" "$MQTT_PORT"
if [[ -n "$TS_SUMMARY" ]]; then
    printf "  • NFSv4 Vault Server : %s (Subnet %s)\n" "$NFS_STATE" "$LAB_SUBNET"
    printf "  • Tailscale Mesh VPN : %s\n\n" "$TS_SUMMARY"
else
    printf "  • NFSv4 Vault Server : %s (Subnet %s)\n\n" "$NFS_STATE" "$LAB_SUBNET"
fi

# ==============================================================================
# 9. STAGE 7: FACTORY DEFAULT USER MIGRATION & PURGE
# ==============================================================================
if [[ -n "$FACTORY_USER" && "$FACTORY_USER" != "$ADMIN_USER" ]]; then
    if id -u "$FACTORY_USER" >/dev/null 2>&1 || [[ -d "/home/${FACTORY_USER}" ]]; then
        if [[ "$REAL_USER" == "$ADMIN_USER" ]]; then
            brak_prog 98 "Stage 7/7: Purging factory user '${FACTORY_USER}' -> '${ADMIN_USER}'" 50 "utils/purge-user.sh ${FACTORY_USER}"
            log_step "7. Migrating Artifacts & Purging Factory Default User ('${FACTORY_USER}' -> '${ADMIN_USER}')"
            /usr/local/bin/rvdk utils/purge-user.sh "$FACTORY_USER" --to-user "$ADMIN_USER"
            echo ""
        else
            log_brak "Factory user '${FACTORY_USER}' still exists (active session: '${REAL_USER}'). Log in as '${ADMIN_USER}' and re-run 'sudo brakerrak' to migrate ~/.brakerrak & purge '${FACTORY_USER}'."
        fi
    fi
fi

rm -f "$APT_STAMP_FILE" 2>/dev/null || true
brak_prog 100 "${TARGET_HOSTNAME} (${NODE_ROLE}) Forge Complete!" 100 "All RVDK stages complete"
brak_prog_cleanup
log_ok "${TARGET_HOSTNAME} PostgreSQL 18.6 (${NODE_ROLE}) Forge Complete!"
