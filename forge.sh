#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Config-Driven RVDK Harness & CLI (`brakerrak`)
# Path: brakerrak/forge.sh
#
# Usage (Remote Curl Bootstrap):
#   curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databroker --hostname jakebase-vf2
#   curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databench
#
# Usage (Local CLI after bootstrap):
#   sudo brakerrak [forge] [--role databroker|databench|devbench] [--hostname <name>] [--force-rebuild-pg]
#   sudo brakerrak ort [--stage day0-pre-forge|day1-post-forge]
#   sudo brakerrak verify [--role databroker|databench] [--force-rebuild-pg]
#   sudo brakerrak reset --confirm-destroy [--keep-pg-cache] [--skip-raid-wipe] [--purge-config]
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[BRAKERRAK:FATAL] Pipe into 'sudo bash': curl -fsSL https://brakerrak.dev/forge.sh | sudo bash" >&2
        exit 1
    fi
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6 2>/dev/null || eval echo "~${REAL_USER}")"
[[ -z "$REAL_HOME" ]] && REAL_HOME="/root"

BRAKER_DIR="${REAL_HOME}/.brakerrak"
ENGINE_DIR="${BRAKER_DIR}/engine"
NODE_ENV="${BRAKER_DIR}/node.env"
REPO_URL="${BRAKERRAK_REPO_URL:-https://github.com/drewv-labs/brakerrak.git}"
REPO_BRANCH="${BRAKERRAK_BRANCH:-main}"
RVDK_BASE_URL="${RVDK_BASE_URL:-https://rvdk.drewv-labs.dev}"

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
        forge|ort|verify|reset|update)
            ACTION="$1"
            shift
            ;;
    esac
fi

# ==============================================================================
# 2. Sync ~/.brakerrak/engine & Link /usr/local/bin/brakerrak
# ==============================================================================
SCRIPT_SELF="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SELF" ]]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_SELF" 2>/dev/null || realpath "$SCRIPT_SELF" 2>/dev/null || echo "$SCRIPT_SELF")"
    CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
else
    CANDIDATE_ROOT=""
fi

if [[ -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/soc-drawer" && "$ACTION" != "update" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
else
    if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || true
        apt-get -o DPkg::Lock::Timeout=120 install -y git ca-certificates curl
    fi
    install -d -m 0750 -o "$REAL_USER" -g "$REAL_USER" "$BRAKER_DIR"
    if [[ -d "${ENGINE_DIR}/.git" ]]; then
        log_brak "Syncing BrakerRak engine in ${ENGINE_DIR}..."
        sudo -u "$REAL_USER" git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
        sudo -u "$REAL_USER" git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
    else
        log_brak "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
        rm -rf "$ENGINE_DIR"
        sudo -u "$REAL_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
    fi
    LOCAL_ROOT="$ENGINE_DIR"
fi

chmod +x "${LOCAL_ROOT}/forge.sh" "${LOCAL_ROOT}"/scripts/*.sh 2>/dev/null || true
ln -sf "${LOCAL_ROOT}/forge.sh" /usr/local/bin/brakerrak
[[ "$ACTION" == "update" ]] && { log_ok "BrakerRak engine updated."; exit 0; }

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
FORCE_WIPE_NVME="false"
FORCE_WIPE_RAID="false"
FORCE_REBUILD_PG="false"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)           TARGET_BOARD="${2:-}"; shift 2 ;;
        --role)             CLI_ROLE="${2:-}"; shift 2 ;;
        --hostname)         CLI_HOSTNAME="${2:-}"; shift 2 ;;
        --user)             CLI_USER="${2:-}"; shift 2 ;;
        --subnet)           CLI_SUBNET="${2:-}"; shift 2 ;;
        --nvme-dev)         CLI_NVME_DEV="${2:-}"; shift 2 ;;
        --mount-point)      CLI_MOUNT_POINT="${2:-}"; shift 2 ;;
        --with-raid)        CLI_WITH_RAID="true"; shift ;;
        --no-raid)          CLI_WITH_RAID="false"; shift ;;
        --with-mqtt)        CLI_ENABLE_MQTT="true"; shift ;;
        --no-mqtt)          CLI_ENABLE_MQTT="false"; shift ;;
        --with-nfs)         CLI_ENABLE_NFS="true"; shift ;;
        --no-nfs)           CLI_ENABLE_NFS="false"; shift ;;
        --force-wipe-nvme)  FORCE_WIPE_NVME="true"; shift ;;
        --force-wipe-raid)  FORCE_WIPE_RAID="true"; shift ;;
        --force-rebuild-pg|--force-build|--compile-pg|--no-pkg-cache)
                            FORCE_REBUILD_PG="true"; shift ;;
        --use-pkg-cache)    FORCE_REBUILD_PG="false"; shift ;;
        *)                  FORWARD_ARGS+=("$1"); shift ;;
    esac
done

# ==============================================================================
# 5. Auto-Detect Silicon Target & Short Tag from /proc/device-tree/model
# ==============================================================================
DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
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

log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) | Action: ${ACTION}"

# ==============================================================================
# 6. CONFIG RESOLUTION (Pass 1 Template Generation vs. Pass 2 node.env Load)
# ==============================================================================
install -d -m 0750 -o "$REAL_USER" -g "$REAL_USER" "$BRAKER_DIR"

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
SHARE_ORT_SNAPSHOT="${SHARE_ORT_SNAPSHOT:-false}"

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

# Opt-In Community RISC-V Telemetry Commons
SHARE_ORT_SNAPSHOT="${SHARE_ORT_SNAPSHOT}"
EOF
    chown "${REAL_USER}:${REAL_USER}" "$NODE_ENV"
    chmod 0640 "$NODE_ENV"
    log_ok "Generated Pass 1 node configuration: ${NODE_ENV}"
fi

export BRAKERRAK_NODE_ENV="$NODE_ENV"
export NODE_ROLE TARGET_HOSTNAME ADMIN_USER LAB_SUBNET NVME_DEV MOUNT_POINT WITH_RAID RAID_ARRAYS_JSON ENABLE_MQTT_BROKER MQTT_PORT ENABLE_NFS_SERVER

# ==============================================================================
# 7. ENSURE RVDK CLI IS INSTALLED & DISPATCH MODULAR RVDK PIPELINE
# ==============================================================================
if [[ ! -x /usr/local/bin/rvdk ]]; then
    log_step "0A. Installing RVDK Package Manager CLI (${RVDK_BASE_URL}/install-cli.sh)"
    curl -fsSL "${RVDK_BASE_URL}/install-cli.sh" | bash -s -- --quiet
fi

log_step "1. RVDK Day-0 OS & Silicon BSP Convergence (Hostname: ${TARGET_HOSTNAME})"
/usr/local/bin/rvdk day0 --user "$ADMIN_USER" --hostname "$TARGET_HOSTNAME" --nopasswd

log_step "2. RVDK Hot NVMe 4Kn Storage Provisioning (${NVME_DEV} -> ${MOUNT_POINT})"
NVME_FLAGS=(--device "$NVME_DEV" --mount "$MOUNT_POINT")
[[ "$FORCE_WIPE_NVME" == "true" ]] && NVME_FLAGS+=(--force-wipe)
/usr/local/bin/rvdk mods/nvme-4kn "${NVME_FLAGS[@]}"

log_step "3. RVDK PostgreSQL 18.6 Convergence (io_uring + Sv39 HugePages)"
PG_FLAGS=(--data-mount "$MOUNT_POINT" --subnet "$LAB_SUBNET")
[[ "$FORCE_REBUILD_PG" == "true" ]] && PG_FLAGS+=(--force-build)
/usr/local/bin/rvdk postgresql "${PG_FLAGS[@]}"

if [[ "$WITH_RAID" == "true" ]]; then
    log_step "4. RVDK Btrfs RAID 10 Vault Provisioning & Tablespace Binding"
    RAID_FLAGS=()
    [[ "$FORCE_WIPE_RAID" == "true" ]] && RAID_FLAGS+=(--force-wipe-raid)
    /usr/local/bin/rvdk mods/btrfs-raid ${RAID_FLAGS[@]+"${RAID_FLAGS[@]}"}
else
    log_step "4. Btrfs RAID 10 Vault Provisioning Skipped (WITH_RAID=false)"
fi

if [[ "$ENABLE_MQTT_BROKER" == "true" ]]; then
    log_step "5A. RVDK Eclipse Mosquitto MQTT Broker (:${MQTT_PORT} + Unix Socket)"
    /usr/local/bin/rvdk mods/mosquitto --port "$MQTT_PORT" --data-mount "$MOUNT_POINT"
else
    log_step "5A. Mosquitto MQTT Broker Skipped (ENABLE_MQTT_BROKER=false)"
fi

if [[ "$ENABLE_NFS_SERVER" == "true" ]]; then
    log_step "5B. RVDK NFSv4 Kernel Server Vault Exports (-> ${LAB_SUBNET})"
    /usr/local/bin/rvdk mods/nfs-vault --subnet "$LAB_SUBNET" --data-mount "$MOUNT_POINT"
else
    log_step "5B. NFSv4 Kernel Server Skipped (ENABLE_NFS_SERVER=false)"
    if systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
        systemctl disable --now nfs-kernel-server
        log_ok "Disabled nfs-kernel-server for benchmark isolation"
    fi
fi

# ==============================================================================
# 8. STAGE 6: POST-FLIGHT CONVERGENCE SUMMARY
# ==============================================================================
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
NFS_STATE="$(systemctl is-active nfs-kernel-server 2>/dev/null || true)"
[[ -z "$NFS_STATE" ]] && NFS_STATE="inactive"

log_step "6. Post-Flight Verification Summary (Pass ${FORGE_PASS})"
printf "  • Hostname           : %s (Role: %s | Pass: %s)\n" "$(hostname)" "$NODE_ROLE" "$FORGE_PASS"
printf "  • Kernel / Arch      : %s (%s)\n" "$(uname -r)" "$(uname -m)"
printf "  • NVMe LBA Block Sz  : %s bytes\n" "$LBA_SZ"
printf "  • Hot NVMe Mount     : %s\n" "$NVME_MNT_INFO"
printf "  • PG Data Directory  : %s\n" "$PG_DATA_DIR"
printf "  • PG 18 Async I/O    : io_method = %s\n" "$PG_IO_METHOD"
printf "  • PG Shared Buffers  : %s (HugePages in use: %s / %s)\n" "$PG_SHBUF" "$HP_USED" "$HP_TOTAL"
printf "  • Mosquitto MQTT     : %s (Port %s)\n" "$MQTT_STATE" "$MQTT_PORT"
printf "  • NFSv4 Vault Server : %s (Subnet %s)\n\n" "$NFS_STATE" "$LAB_SUBNET"
log_ok "${TARGET_HOSTNAME} PostgreSQL 18.6 (${NODE_ROLE}) Forge Complete!"
