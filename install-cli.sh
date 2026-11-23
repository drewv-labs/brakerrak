#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak CLI & Engine Installer
# Path: brakerrak/install-cli.sh
# Description: Clones or updates the brakerrak engine in ~/.brakerrak/engine
#              and links /usr/local/bin/brakerrak (+ /usr/bin/brakerrak on Linux)
#              without modifying OS/PG18 state.
#
# Usage:
#   curl -fsSL https://brakerrak.dev/install-cli.sh | sudo bash
#   curl -fsSL https://brakerrak.dev/install-cli.sh | sudo zsh
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash` (including `curl ... | sudo zsh`)
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
        echo "[BRAKERRAK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://brakerrak.dev/install-cli.sh | sudo bash" >&2
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
SNAP_DIR="${BRAKER_DIR}/snapshots"
ENGINE_DIR="${BRAKER_DIR}/engine"
REPO_URL="${BRAKERRAK_REPO_URL:-https://github.com/drewv-labs/brakerrak.git}"
REPO_BRANCH="${BRAKERRAK_BRANCH:-main}"
QUIET_MODE="false"

for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET_MODE="true" ;;
    esac
done

log_info()  { printf "\033[1;35m[BRAKERRAK:CLI]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[BRAKERRAK:FATAL]\033[0m %s\n" "$1"; }

# 1. Ensure git and curl are installed
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        log_info "Installing git and curl prerequisites..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || true
        apt-get -o DPkg::Lock::Timeout=120 install -y git ca-certificates curl
    else
        log_fatal "Missing git or curl. On macOS, run 'xcode-select --install' or 'brew install git curl'."
        exit 1
    fi
fi

# 2. Clone or update ~/.brakerrak/engine
install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$BRAKER_DIR" "$SNAP_DIR"

if [[ -d "${ENGINE_DIR}/.git" ]]; then
    log_info "Updating BrakerRak engine in ${ENGINE_DIR} (${REPO_BRANCH})..."
    sudo -u "$REAL_USER" git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
    sudo -u "$REAL_USER" git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
else
    log_info "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
    rm -rf "$ENGINE_DIR"
    sudo -u "$REAL_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
fi

chmod +x "${ENGINE_DIR}/forge.sh" "${ENGINE_DIR}/install-cli.sh" "${ENGINE_DIR}"/scripts/*.sh "${ENGINE_DIR}"/benchmarks/*.sh 2>/dev/null || true

# 3. Link /usr/local/bin/brakerrak (plus /usr/bin/brakerrak on Linux for Debian sudo secure_path)
install -d -m 0755 /usr/local/bin
ln -sf "${ENGINE_DIR}/forge.sh" /usr/local/bin/brakerrak
if [[ "$(uname -s)" == "Linux" && -d /usr/bin ]]; then
    ln -sf "${ENGINE_DIR}/forge.sh" /usr/bin/brakerrak
fi
COMMIT_SHA="$(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo "main")"
log_ok "Linked /usr/local/bin/brakerrak -> ${ENGINE_DIR}/forge.sh (${COMMIT_SHA})"

if [[ "$QUIET_MODE" == "false" ]]; then
    DT_MODEL="Unknown"
    if [[ -r /proc/device-tree/model ]]; then
        DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        DT_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m) (macOS Host)"
    fi

    OS_PRETTY="Unknown"
    if [[ -f /etc/os-release ]]; then
        OS_PRETTY="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}" || echo "Unknown")"
    elif command -v sw_vers >/dev/null 2>&1; then
        OS_PRETTY="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    fi

    RVDK_ENGINE_DIR="/usr/local/share/rvdk/engine"
    if [[ -d "${RVDK_ENGINE_DIR}/.git" ]]; then
        RVDK_SHA="$(git -C "$RVDK_ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo "main")"
        RVDK_STATUS="${RVDK_ENGINE_DIR} (${RVDK_SHA})"
    else
        RVDK_STATUS="auto-installed on forge/update"
    fi

    cat <<EOF

======================================================================
 DREW-V Labs // BrakerRak CLI Installed (${COMMIT_SHA})
   Board : ${DT_MODEL}
   OS    : ${OS_PRETTY}
   Root  : ${ENGINE_DIR}
   RVDK  : ${RVDK_STATUS}

 Usage:
   sudo brakerrak                           # Converge node using ~/.brakerrak/node.env
   sudo brakerrak --role databroker         # Converge as DataBroker (PG18 + MQTT + NFSv4)
   sudo brakerrak --role databench          # Converge as DataBench (Isolated PG18)
   sudo brakerrak deeptune                  # Apply role-mapped Kit DeepTune
   sudo brakerrak storage [status|autotune] # Manage Dual-LVM elastic pool (grow-psql, grow-nfs, shrink-nfs)
   sudo brakerrak ort [--stage <tag>]       # Capture read-only ORT & CTD snapshot
   sudo brakerrak verify [--use-pkg-cache]  # Run 5-stage convergence & idempotency harness
   sudo brakerrak reset --confirm-destroy   # Roll back NVMe to factory 512e & Day-0 state
   sudo brakerrak update                    # Pull latest RVDK + BrakerRak engines from GitHub
======================================================================
EOF
fi
