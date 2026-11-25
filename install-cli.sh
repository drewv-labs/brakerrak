#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak CLI & Engine Installer
# Path: brakerrak/install-cli.sh
# Description: Stages the brakerrak engine in /usr/local/share/brakerrak/engine
#              (0755), migrates legacy ~/.brakerrak/node.env to
#              /etc/brakerrak/node.env (0640, root:$REAL_GRP), ensures user
#              snapshots directory ~/.brakerrak/snapshots (0750), and links
#              /usr/local/bin/brakerrak (+ /usr/bin/brakerrak on Linux) without
#              modifying OS/PG18 state.
#
# Usage:
#   curl -fsSL https://brakerrak.dev/install-cli.sh | sudo bash
#   curl -fsSL https://brakerrak.dev/install-cli.sh | sudo zsh
#   sudo ./install-cli.sh [--quiet] [--force]
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash` (including `curl ... | sudo zsh`)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_SELF="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" && "${0:-}" != "zsh" && "${0:-}" != "-zsh" && -f "${0:-}" ]]; then
    SCRIPT_SELF="$0"
else
    SCRIPT_SELF=""
fi

usage() {
    cat <<'EOF'
Usage:
  curl -fsSL https://brakerrak.dev/install-cli.sh | sudo bash [-s -- [options]]
  sudo ./install-cli.sh [options]

Options:
  -q, --quiet   Suppress post-install banner
      --force   Discard uncommitted local changes in /usr/local/share/brakerrak/engine
  -h, --help    Show this help message and exit
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

if [[ $EUID -ne 0 ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]] && command -v sudo >/dev/null 2>&1; then
        _BRAK_SUDO_KEEP_ENV="BRAKERRAK_ENGINE_DIR,BRAKERRAK_REPO_URL,BRAKERRAK_BRANCH,BRAKERRAK_NODE_ENV,BRAKERRAK_SYSTEM_ENGINE_DIR,BRAKERRAK_SYSTEM_ETC_DIR,BRAKERRAK_SYSTEM_NODE_ENV,TERM,COLORTERM,NO_COLOR"
        exec sudo --preserve-env="$_BRAK_SUDO_KEEP_ENV" bash "$SCRIPT_SELF" "$@"
    else
        echo "[BRAKERRAK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://brakerrak.dev/install-cli.sh | sudo bash" >&2
        exit 1
    fi
fi

# Re-exec under bash if invoked directly as a file under zsh
if [[ -n "${ZSH_VERSION:-}" && -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]] && command -v bash >/dev/null 2>&1; then
    exec bash "$SCRIPT_SELF" "$@"
fi

# Enforce 022 umask so system engine files remain 0755/0644 even on hardened root umasks
umask 022

_REPO_ROOT=""
if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]]; then
    _REPO_ROOT="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)"
fi

if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/scripts/lib-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${_REPO_ROOT}/scripts/lib-common.sh"
else
    BRAKERRAK_SYSTEM_ENGINE_DIR="/usr/local/share/brakerrak/engine"
    BRAKERRAK_SYSTEM_ETC_DIR="/etc/brakerrak"
    BRAKERRAK_SYSTEM_NODE_ENV="/etc/brakerrak/node.env"
    brak_log_init() { :; }
    log_info()  { printf "\033[1;35m[BRAKERRAK:CLI]\033[0m %s\n" "$1"; }
    log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
    log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1" >&2; }
    log_fatal() { printf "\033[1;31m[BRAKERRAK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
    brak_sanitize_locale() {
        local avail
        avail="$(locale -a 2>/dev/null || true)"
        if grep -qiE '^en_US\.utf-?8$' <<< "$avail"; then
            export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
        elif grep -qiE '^C\.utf-?8$' <<< "$avail"; then
            export LANG="C.UTF-8" LC_ALL="C.UTF-8"
        else
            export LANG="C" LC_ALL="C"
        fi
    }
    brak_resolve_user() {
        REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
        [[ ! "$REAL_USER" =~ ^[a-zA-Z0-9._-]+$ ]] && REAL_USER="root"
        REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
        REAL_HOME=""
        if command -v getent >/dev/null 2>&1; then
            REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
        elif command -v dscl >/dev/null 2>&1; then
            REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
        fi
        if [[ -z "$REAL_HOME" ]]; then
            if [[ "$REAL_USER" == "root" ]]; then
                REAL_HOME="/root"
            elif [[ -d "/Users/${REAL_USER}" ]]; then
                REAL_HOME="/Users/${REAL_USER}"
            elif [[ -d "/home/${REAL_USER}" ]]; then
                REAL_HOME="/home/${REAL_USER}"
            else
                REAL_HOME="/root"
            fi
        fi
        export REAL_USER REAL_GRP REAL_HOME
    }
fi

brak_log_init "BRAKERRAK:CLI"
brak_sanitize_locale
brak_resolve_user

BRAKER_DIR="${REAL_HOME}/.brakerrak"
SNAP_DIR="${BRAKER_DIR}/snapshots"
SYS_ETC_DIR="${BRAKERRAK_SYSTEM_ETC_DIR:-/etc/brakerrak}"
ENGINE_DIR="${BRAKERRAK_ENGINE_DIR:-${BRAKERRAK_SYSTEM_ENGINE_DIR:-/usr/local/share/brakerrak/engine}}"
ENGINE_PARENT="$(dirname "$ENGINE_DIR")"
REPO_URL="${BRAKERRAK_REPO_URL:-https://github.com/drewv-labs/brakerrak.git}"
REPO_BRANCH="${BRAKERRAK_BRANCH:-main}"
QUIET_MODE="false"
FORCE_UPDATE="false"

for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET_MODE="true" ;;
        --force)    FORCE_UPDATE="true" ;;
        -h|--help)  usage; exit 0 ;;
        *)          log_fatal "Unknown argument: ${arg} (try --help)" ;;
    esac
done

if [[ ! "$REPO_BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
    log_fatal "Invalid BRAKERRAK_BRANCH name: '${REPO_BRANCH}'."
fi

# 1. Ensure git and curl are installed
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        log_info "Installing git and curl prerequisites..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || true
        apt-get -o DPkg::Lock::Timeout=120 install -y git ca-certificates curl
    else
        log_fatal "Missing git or curl. On macOS, run 'xcode-select --install' or 'brew install git curl'."
    fi
fi

# 2. Stage system-wide engine (/usr/local/share/brakerrak/engine), /etc/brakerrak, and user snapshots
install -d -m 0755 -o 0 -g 0 "$SYS_ETC_DIR" "$ENGINE_PARENT"
chmod 0755 /usr/local /usr/local/share "$ENGINE_PARENT" 2>/dev/null || true
install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$BRAKER_DIR" "$SNAP_DIR"

if [[ -d "${ENGINE_DIR}/.git" ]]; then
    if [[ "$FORCE_UPDATE" != "true" ]] && [[ -n "$(git -C "$ENGINE_DIR" status --porcelain 2>/dev/null || true)" ]]; then
        log_fatal "Local modifications detected in ${ENGINE_DIR}. Commit/stash changes or re-run with --force to overwrite."
    fi
    log_info "Updating BrakerRak engine in ${ENGINE_DIR} (${REPO_BRANCH})..."
    chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
    git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
    git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
else
    log_info "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
    rm -rf "$ENGINE_DIR"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
fi

chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
chmod -R a+rX "$ENGINE_DIR" 2>/dev/null || true
chmod 0755 "$ENGINE_DIR"
chmod +x \
    "${ENGINE_DIR}/forge.sh" \
    "${ENGINE_DIR}/install-cli.sh" \
    "${ENGINE_DIR}"/scripts/*.sh \
    "${ENGINE_DIR}"/benchmarks/*.sh 2>/dev/null || true

# Sync clean-room Python runtime (.venv) when uv + pyproject.toml + uv.lock are present
UV_BIN=""
if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
elif [[ -x /root/.local/bin/uv ]]; then
    UV_BIN="/root/.local/bin/uv"
elif [[ -x /root/.cargo/bin/uv ]]; then
    UV_BIN="/root/.cargo/bin/uv"
fi

if [[ -n "$UV_BIN" && -f "${ENGINE_DIR}/pyproject.toml" ]]; then
    if [[ -f "${ENGINE_DIR}/uv.lock" ]]; then
        log_info "Syncing clean-room Python runtime in ${ENGINE_DIR}/.venv..."
        if "$UV_BIN" sync --project "$ENGINE_DIR" --frozen --no-dev; then
            chown -R 0:0 "${ENGINE_DIR}/.venv" 2>/dev/null || true
            chmod -R a+rX "${ENGINE_DIR}/.venv" 2>/dev/null || true
            log_ok "Synced ${ENGINE_DIR}/.venv (world-readable a+rX)"
        else
            log_warn "uv sync --project '${ENGINE_DIR}' --frozen --no-dev failed; 'brakerrak bench analyze' may require manual sync."
        fi
    else
        log_warn "uv.lock missing in ${ENGINE_DIR}; skipping frozen .venv sync."
    fi
fi

# Source the freshly staged lib-common.sh when bootstrapped via `curl | sudo bash`
if [[ "${_BRAKERRAK_COMMON_SOURCED:-0}" != "1" && -f "${ENGINE_DIR}/scripts/lib-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${ENGINE_DIR}/scripts/lib-common.sh"
    brak_log_init "BRAKERRAK:CLI"
fi

# Transparently migrate legacy ~/.brakerrak/node.env -> /etc/brakerrak/node.env
if declare -F brak_resolve_node_env >/dev/null 2>&1; then
    brak_resolve_node_env --migrate
fi

# Retire clean legacy ~/.brakerrak/engine checkout once system engine is active
LEGACY_ENGINE="${BRAKER_DIR}/engine"
if [[ -d "$LEGACY_ENGINE" && "$ENGINE_DIR" != "$LEGACY_ENGINE" ]]; then
    if [[ -d "${LEGACY_ENGINE}/.git" ]] && [[ -n "$(git -C "$LEGACY_ENGINE" status --porcelain 2>/dev/null || true)" ]]; then
        log_warn "Legacy ${LEGACY_ENGINE} has uncommitted changes; preserving it (system engine is now at ${ENGINE_DIR})."
    else
        rm -rf "$LEGACY_ENGINE" 2>/dev/null || true
        log_ok "Retired legacy user-home checkout ${LEGACY_ENGINE}"
    fi
fi

# 3. Link /usr/local/bin/brakerrak (plus /usr/bin/brakerrak on Linux for Debian sudo secure_path)
install -d -m 0755 /usr/local/bin
chmod 0755 /usr/local /usr/local/bin 2>/dev/null || true
ln -sf "${ENGINE_DIR}/forge.sh" /usr/local/bin/brakerrak
LINKED_PATHS="/usr/local/bin/brakerrak"
if [[ "$(uname -s)" == "Linux" && -d /usr/bin ]]; then
    if ln -sf "${ENGINE_DIR}/forge.sh" /usr/bin/brakerrak 2>/dev/null; then
        LINKED_PATHS="/usr/bin/brakerrak & /usr/local/bin/brakerrak"
    fi
fi
COMMIT_SHA="$(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo "main")"
log_ok "Linked ${LINKED_PATHS} -> ${ENGINE_DIR}/forge.sh (${COMMIT_SHA})"

if [[ "$QUIET_MODE" == "false" ]]; then
    DT_MODEL="Unknown"
    if [[ -r /proc/device-tree/model ]]; then
        DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        DT_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m) (macOS Host)"
    fi

    OS_PRETTY="Unknown"
    if [[ -r /etc/os-release ]]; then
        OS_PRETTY="$(awk -F= '/^PRETTY_NAME=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/os-release 2>/dev/null || echo "Unknown")"
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
   Board  : ${DT_MODEL}
   OS     : ${OS_PRETTY}
   Engine : ${ENGINE_DIR}
   Config : ${NODE_ENV:-${BRAKERRAK_SYSTEM_NODE_ENV}}
   RVDK   : ${RVDK_STATUS}

 Usage:
   sudo brakerrak                           # Converge node using /etc/brakerrak/node.env
   sudo brakerrak --role databroker         # Converge as DataBroker (PG18 + MQTT + NFSv4)
   sudo brakerrak --role databench          # Converge as DataBench (Isolated PG18)
   sudo brakerrak deeptune                  # Apply role-mapped Kit DeepTune
   sudo brakerrak storage [status|autotune] # Manage Dual-LVM elastic pool (grow-psql, grow-nfs, shrink-nfs)
   sudo brakerrak ort [--stage <tag>]       # Capture read-only ORT & CTD snapshot
   sudo brakerrak bench [seed|showdown|analyze] # Run PG18 io_uring torture benchmarks & PyArrow analysis
   sudo brakerrak verify [--use-pkg-cache]  # Run 5-stage convergence & idempotency harness
   sudo brakerrak reset --confirm-destroy   # Roll back NVMe to factory 512e & Day-0 state
   sudo brakerrak update [--force]          # Pull latest RVDK + BrakerRak engines from GitHub
======================================================================
EOF
fi
