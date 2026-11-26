#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Config-Driven RVDK Harness & CLI (`brakerrak`)
# Path: brakerrak/forge.sh
#
# Usage (Remote Curl Bootstrap):
#   curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databroker --hostname brakerbox-vf2
#   curl -fsSL https://brakerrak.dev/forge.sh | sudo bash -s -- --role databench
#
# Usage (Local CLI after bootstrap or install-cli.sh):
#   sudo brakerrak [forge] [--role databroker|databench|babbagebox|babbagebench|visionbox|visionbench|devbench|snitchbench|lilsnitch] [--target <board>] [--media <nvme|sd>] [--stage-dir <dir>] [--hostname <name>] [--with-pg|--no-pg] [--nfs-kernel|--nfs-ganesha|--nfs-auto] [--deeptune|--tune data|ai|iot] [--with-tailscale] [--tailscale-authkey-file <path>] [--no-apt-update] [--force-rebuild-pg] [--noprogbar]
#   sudo brakerrak deeptune [--role databroker|databench|babbagebox|babbagebench|visionbox|visionbench|devbench|snitchbench|lilsnitch] [--tune data|ai|iot]
#   sudo brakerrak storage [status|grow-psql|grow-nfs|shrink-nfs|autotune] [--gb <N>|--mb <N>]
#   sudo brakerrak ort [--stage day0-pre-forge|day1-post-forge] [--telemetry-json <path>|--serial-port <dev>]
#   sudo brakerrak bench [seed|showdown|analyze] [args...]
#   sudo brakerrak verify [--role databroker|databench|babbagebox|babbagebench|visionbox|visionbench|devbench|snitchbench|lilsnitch] [--force-rebuild-pg] [--noprogbar]
#   sudo brakerrak reset --confirm-destroy [--keep-pg-cache] [--skip-raid-wipe] [--purge-config]
#   sudo brakerrak update [--force] [--skip-rvdk]
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash`
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

if [[ -n "$SCRIPT_SELF" ]]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_SELF" 2>/dev/null || realpath "$SCRIPT_SELF" 2>/dev/null || echo "$SCRIPT_SELF")"
    CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
else
    CANDIDATE_ROOT=""
fi

print_usage() {
    cat <<'EOF'
Usage: sudo brakerrak [subcommand] [options]

Subcommands:
  forge (default)                     Converge OS/BSP, 4Kn NVMe, PG18, MQTT, NFSv4 & role services
  deeptune [--role <r>] [--tune <t>]  Apply role-mapped RVDK silicon & OS DeepTune
  storage [status|grow-psql|grow-nfs|shrink-nfs|autotune]
                                      Manage Dual-LVM elastic pool via RVDK
  ort [--stage <tag>] [--out-dir <d>] Capture read-only Day-0/Day-1 ORT & CTD provenance snapshot
  bench [seed|showdown|analyze]       Run PG18 io_uring torture benchmarks & PyArrow telemetry analysis
  verify [forge-options]              Run end-to-end convergence & Pass-2 idempotency harness
  reset --confirm-destroy [options]   Roll back NVMe to factory 512e & Day-0 state
  update [--force] [--skip-rvdk]      Pull latest RVDK + BrakerRak engine from GitHub

Forge Options (all value flags also accept --flag=value):
  --target <slug>                     Override silicon target (e.g. eswin-eic7700x, starfive-jh7110, espressif-esp32p4)
  --role <role>                       databroker | databench | babbagebox | babbagebench |
                                      visionbox | visionbench | devbench | snitchbench | lilsnitch
  --media <nvme|sd>                   Override target storage medium (default: nvme on riscv64, sd on riscv32)
  --stage-dir <dir>                   Host-assisted SD staging root (writes <dir>/config/node.env & ESP32-P4 artifacts)
  --hostname <name>                   Target RFC-1123 node hostname
  --user <username>                   Target admin POSIX user
  --subnet <CIDR>                     Authorized LAN CIDR (default: 10.0.0.0/24; empty "" preserved from node.env)
  --nvme-dev <device>                 Hot NVMe block device (default: /dev/nvme0n1)
  --mount-point <path>                Primary NVMe mountpoint (default: /mnt/nvme_pgdata)
  --nfs-mount <path>                  Dedicated Dual-LVM NFS mountpoint (default: /mnt/nfs_vault)
  --with-raid | --no-raid             Enable or disable USB/SATA Btrfs RAID 10 provisioning
  --with-pg | --no-pg                 Enable or disable PostgreSQL 18.6 (+ Sv39 HugePages reclamation on --no-pg)
  --with-mqtt | --no-mqtt             Enable or disable Eclipse Mosquitto broker
  --with-nfs | --no-nfs               Enable or disable NFSv4 vault exports
  --nfs-backend <ganesha|kernel|auto> Select NFSv4 backend (aliases: --nfs-ganesha, --nfs-kernel, --nfs-auto)
  --deeptune | --tune <data|ai|iot>   Run RVDK DeepTune at end of forge (persists tune profile on --tune)
  --with-tailscale                    Install & configure Tailscale mesh VPN
  --tailscale-up | --tailscale-ssh    Run `tailscale up` / enable Tailscale SSH
  --tailscale-authkey-file <path>     Read Tailscale auth key from a 0600 file (or set TS_AUTHKEY env)
  --tailscale-routes <CIDRs>          Advertise subnet routes via Tailscale
  --tailscale-userspace               Force userspace networking for Tailscale
  --no-apt-update                     Skip redundant apt-get update calls
  --force-wipe-nvme                   Force wipe/reformat hot NVMe block device
  --force-wipe-raid                   Force wipe/recreate declared Btrfs RAID arrays
  --force-rebuild-pg | --use-pkg-cache
                                      Compile PG18 from source vs prebuilt bundle cache
  --noprogbar                         Disable 2-row stacked VT100 progress bar
  --version                           Print BrakerRak engine version and exit
  -h, --help                          Show this help message and exit

Paths:
  Engine : /usr/local/share/brakerrak/engine (0755)
  Config : /etc/brakerrak/node.env (0640, root:$REAL_GRP; override via BRAKERRAK_NODE_ENV)
  Snaps  : ~/.brakerrak/snapshots (0750)
EOF
}

print_bench_help() {
    cat <<'EOF'
Usage:
  sudo brakerrak bench seed [options]      Seed deterministic PG18 I/O torture table
                                           (/usr/local/share/brakerrak/engine/benchmarks/seed-io-torture.sh)
  sudo brakerrak bench [showdown] [opts]   Run cold-cache sync/worker/io_uring ablation showdown
                                           (/usr/local/share/brakerrak/engine/benchmarks/run-iouring-showdown.sh)
  brakerrak bench analyze <run_dir> [opts] Aggregate showdown telemetry via PyArrow to Parquet/IPC
                                           (/usr/local/share/brakerrak/engine/benchmarks/analyze_showdown.py)
EOF
}

print_version() {
    local engine_root="${CANDIDATE_ROOT:-/usr/local/share/brakerrak/engine}"
    local commit_sha="unknown"
    if [[ -d "${engine_root}/.git" ]] && command -v git >/dev/null 2>&1; then
        commit_sha="$(git -C "$engine_root" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    fi
    printf "brakerrak (%s) [%s]\n" "$commit_sha" "$engine_root"
}

_brak_run_bench_analyze() {
    local bench_root="$1"
    shift
    local analyzer="${bench_root}/benchmarks/analyze_showdown.py"
    if [[ ! -f "$analyzer" ]]; then
        printf '[BRAKERRAK:FATAL] Showdown analyzer script not found: %s\n' "$analyzer" >&2
        exit 1
    fi

    if [[ -x "${bench_root}/.venv/bin/python" ]]; then
        if "${bench_root}/.venv/bin/python" -c 'import pyarrow' >/dev/null 2>&1; then
            exec "${bench_root}/.venv/bin/python" "$analyzer" "$@"
        fi
    fi

    if command -v uv >/dev/null 2>&1 && [[ -f "${bench_root}/pyproject.toml" ]] && [[ -d "${bench_root}/.venv" || -n "${UV_PROJECT_ENVIRONMENT:-}" ]]; then
        if uv run --project "$bench_root" --no-sync python -c 'import pyarrow' >/dev/null 2>&1; then
            exec uv run --project "$bench_root" --no-sync python "$analyzer" "$@"
        fi
    fi

    if command -v python3 >/dev/null 2>&1 && python3 -c 'import pyarrow' >/dev/null 2>&1; then
        exec python3 "$analyzer" "$@"
    fi

    cat >&2 <<EOF
[BRAKERRAK:FATAL] Python 'pyarrow' is unavailable for 'brakerrak bench analyze' (engine: ${bench_root}).
Remediate by syncing the engine virtualenv as root with world-readable permissions:
  sudo uv sync --project "${bench_root}" --frozen --no-dev && sudo chmod -R a+rX "${bench_root}/.venv"
Or reinstall the BrakerRak CLI:
  curl -fsSL https://brakerrak.dev/install-cli.sh | sudo bash
EOF
    exit 1
}

# Handle unprivileged --help / --version and read-only `bench analyze` before sudo escalation
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        --version|-V)
            print_version
            exit 0
            ;;
        forge)
            for _fa in "${@:2}"; do
                case "$_fa" in
                    -h|--help)    print_usage; exit 0 ;;
                    --version|-V) print_version; exit 0 ;;
                esac
            done
            ;;
        bench)
            case "${2:-}" in
                -h|--help|help)
                    print_bench_help
                    exit 0
                    ;;
                analyze|report)
                    _BENCH_ROOT="${BRAKERRAK_ENGINE_DIR:-${CANDIDATE_ROOT:-/usr/local/share/brakerrak/engine}}"
                    shift 2
                    _brak_run_bench_analyze "$_BENCH_ROOT" "$@"
                    ;;
            esac
            ;;
    esac
fi

_HAS_STAGE_DIR="false"
for _sa in "$@"; do
    case "$_sa" in
        --stage-dir|--stage-dir=*) _HAS_STAGE_DIR="true"; break ;;
    esac
done

if [[ $EUID -ne 0 && "$_HAS_STAGE_DIR" != "true" ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]] && command -v sudo >/dev/null 2>&1; then
        _BRAK_SUDO_KEEP_ENV="BRAKERRAK_ENGINE_DIR,BRAKERRAK_REPO_URL,BRAKERRAK_BRANCH,BRAKERRAK_BASE_URL,BRAKERRAK_NODE_ENV,BRAKERRAK_TARGET,BRAKERRAK_NO_PROGBAR,BRAKERRAK_RUNTIME_DIR,BRAKERRAK_INSTALL_SHA256,BRAKERRAK_SYSTEM_ENGINE_DIR,BRAKERRAK_SYSTEM_ETC_DIR,BRAKERRAK_SYSTEM_NODE_ENV,NO_PROGBAR,RVDK_BIN,RVDK_BASE_URL,RVDK_INSTALL_SHA256,RVDK_NO_PROGBAR,RVDK_ENV_FILE,APT_UPDATED,TS_AUTHKEY,TERM,COLORTERM,NO_COLOR"
        exec sudo --preserve-env="$_BRAK_SUDO_KEEP_ENV" bash "$SCRIPT_SELF" "$@"
    else
        echo "[BRAKERRAK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://brakerrak.dev/forge.sh | sudo bash" >&2
        exit 1
    fi
fi

# Re-exec under bash if invoked directly as a file under zsh
if [[ -n "${ZSH_VERSION:-}" && -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]] && command -v bash >/dev/null 2>&1; then
    exec bash "$SCRIPT_SELF" "$@"
fi

# Load shared core library if local checkout is already available; otherwise provide
# minimal bootstrap helpers (ZERO `eval`) until the engine is staged.
if [[ -n "$CANDIDATE_ROOT" && -f "${CANDIDATE_ROOT}/scripts/lib-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${CANDIDATE_ROOT}/scripts/lib-common.sh"
else
    BRAKERRAK_SYSTEM_ENGINE_DIR="/usr/local/share/brakerrak/engine"
    brak_log_init() { :; }
    log_brak()  { printf "\033[1;35m[BRAKERRAK]\033[0m %s\n" "$1"; }
    log_step()  { printf "\n\033[1;36m=== [%s] %s ===\033[0m\n" "$(date +%H:%M:%S)" "$1"; }
    log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
    log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
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

brak_log_init "BRAKERRAK"
brak_sanitize_locale
brak_resolve_user

BRAKER_DIR="${REAL_HOME}/.brakerrak"
SNAP_DIR="${BRAKER_DIR}/snapshots"
ENGINE_DIR="${BRAKERRAK_ENGINE_DIR:-${BRAKERRAK_SYSTEM_ENGINE_DIR:-/usr/local/share/brakerrak/engine}}"
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

RVDK_BIN="${RVDK_BIN:-/usr/local/bin/rvdk}"
if [[ ! -x "$RVDK_BIN" ]]; then
    if [[ -x /usr/bin/rvdk ]]; then
        RVDK_BIN="/usr/bin/rvdk"
    elif command -v rvdk >/dev/null 2>&1; then
        RVDK_BIN="$(command -v rvdk)"
    fi
fi

_brak_resolve_rvdk_cmd() {
    if command -v rvdk >/dev/null 2>&1; then
        command -v rvdk
    elif [[ -x "${RVDK_BIN:-}" ]]; then
        printf '%s\n' "$RVDK_BIN"
    else
        return 1
    fi
}

# Download a remote shell script to a 0700 temp file, validate non-empty + valid
# shell shebang (+ optional SHA-256 verification), execute it, and clean up.
# Usage: _brak_fetch_and_exec_script <url> [expected_sha256] [script_args...]
_brak_fetch_and_exec_script() {
    local url="$1"
    local expected_sha256="${2:-}"
    shift 2

    if ! command -v curl >/dev/null 2>&1; then
        log_fatal "Missing curl; cannot fetch ${url}."
    fi

    local tmp_dir="${BRAKERRAK_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local tmp_script=""
    if declare -F brak_mktemp >/dev/null 2>&1; then
        brak_mktemp -v tmp_script "${tmp_dir%/}/brakerrak-fetch.XXXXXX" || log_fatal "Failed to create temporary file for ${url}."
    else
        tmp_script="$(
            umask 077
            mktemp "${tmp_dir%/}/brakerrak-fetch.XXXXXX"
        )" || log_fatal "Failed to create temporary file for ${url}."
        if declare -p _BRAK_TMPFILES >/dev/null 2>&1; then
            _BRAK_TMPFILES+=("$tmp_script")
        fi
        if declare -F brak_register_exit_hook >/dev/null 2>&1; then
            brak_register_exit_hook _brak_cleanup_tmpfiles
        elif [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
            _BRAK_FETCH_TMPFILE="$tmp_script"
            trap 'rm -f "${_BRAK_FETCH_TMPFILE:-}" 2>/dev/null || true' EXIT
            trap 'rm -f "${_BRAK_FETCH_TMPFILE:-}" 2>/dev/null || true; trap - INT; kill -INT $$' INT
            trap 'rm -f "${_BRAK_FETCH_TMPFILE:-}" 2>/dev/null || true; trap - TERM; kill -TERM $$' TERM
        fi
    fi
    if ! chmod 0700 "$tmp_script"; then
        rm -f "$tmp_script" 2>/dev/null || true
        _BRAK_FETCH_TMPFILE=""
        log_fatal "Failed to chmod 0700 temporary script ${tmp_script}."
    fi

    local curl_args=(-fsSL)
    if [[ "$url" == https://* ]]; then
        curl_args+=(--proto '=https' --tlsv1.2)
    fi
    if ! curl "${curl_args[@]}" -o "$tmp_script" "$url"; then
        rm -f "$tmp_script" 2>/dev/null || true
        log_fatal "Failed to download script: ${url}"
    fi

    if [[ ! -s "$tmp_script" ]]; then
        rm -f "$tmp_script" 2>/dev/null || true
        log_fatal "Downloaded script is empty: ${url}"
    fi

    local first_line=""
    IFS= read -r first_line < "$tmp_script" || true
    first_line="${first_line%$'\r'}"
    if [[ ! "$first_line" =~ ^#! ]] || [[ ! "$first_line" =~ (sh|bash|zsh) ]]; then
        rm -f "$tmp_script" 2>/dev/null || true
        log_fatal "Downloaded file from ${url} lacks a valid shell shebang (got: '${first_line:0:64}')."
    fi

    if [[ -n "$expected_sha256" ]]; then
        local norm_expected actual_sha=""
        norm_expected="$(tr '[:upper:]' '[:lower:]' <<< "$expected_sha256")"
        if [[ ! "$norm_expected" =~ ^[0-9a-f]{64}$ ]]; then
            rm -f "$tmp_script" 2>/dev/null || true
            log_fatal "Invalid expected SHA-256 digest for ${url}: '${expected_sha256}'"
        fi
        if command -v sha256sum >/dev/null 2>&1; then
            actual_sha="$(sha256sum "$tmp_script" | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
            actual_sha="$(shasum -a 256 "$tmp_script" | awk '{print $1}')"
        else
            rm -f "$tmp_script" 2>/dev/null || true
            log_fatal "Cannot verify SHA-256 for ${url}: neither sha256sum nor shasum is installed."
        fi
        actual_sha="$(tr '[:upper:]' '[:lower:]' <<< "$actual_sha")"
        if [[ "$actual_sha" != "$norm_expected" ]]; then
            rm -f "$tmp_script" 2>/dev/null || true
            log_fatal "SHA-256 mismatch for ${url}: expected ${norm_expected}, got ${actual_sha}"
        fi
    fi

    local rc=0
    bash "$tmp_script" "$@" || rc=$?
    rm -f "$tmp_script" 2>/dev/null || true
    _BRAK_FETCH_TMPFILE=""
    return "$rc"
}

# ==============================================================================
# 1. Parse Subcommand (forge | deeptune | storage | ort | bench | verify | reset | update)
# ==============================================================================
ACTION="forge"
if [[ $# -gt 0 ]]; then
    case "$1" in
        forge|deeptune|deep-tune|storage|ort|bench|verify|reset|update|self-update)
            ACTION="$1"
            shift
            ;;
    esac
fi

# ==============================================================================
# 2. Resolve Engine Path (/usr/local/share/brakerrak/engine) & Handle `update`
# ==============================================================================
if [[ "$ACTION" == "update" || "$ACTION" == "self-update" ]]; then
    RVDK_QUIET_ARGS=("--quiet")
    SKIP_RVDK_UPDATE="false"
    BRAK_UPDATE_ARGS=()
    for uarg in "$@"; do
        case "$uarg" in
            --skip-rvdk|--only-brakerrak) SKIP_RVDK_UPDATE="true" ;;
            -v|--verbose)                 RVDK_QUIET_ARGS=() ;;
            -q|--quiet|--force)           BRAK_UPDATE_ARGS+=("$uarg") ;;
            -h|--help)
                cat <<'EOF'
Usage: sudo brakerrak update [options]

Options:
  --skip-rvdk   Only update BrakerRak engine (skip RVDK update)
  --force       Discard uncommitted local changes in /usr/local/share/brakerrak/engine
  -q, --quiet   Suppress post-update banner
  -v, --verbose Show verbose RVDK update banner
  -h, --help    Show this help message and exit
EOF
                exit 0
                ;;
            *)
                log_fatal "Unknown update option: ${uarg} (try 'brakerrak update --help')"
                ;;
        esac
    done

    if [[ "$SKIP_RVDK_UPDATE" != "true" ]]; then
        if [[ -x "$RVDK_BIN" ]]; then
            "$RVDK_BIN" update ${RVDK_QUIET_ARGS[@]+"${RVDK_QUIET_ARGS[@]}"}
        elif [[ -f "/usr/local/share/rvdk/engine/install-cli.sh" ]]; then
            bash "/usr/local/share/rvdk/engine/install-cli.sh" ${RVDK_QUIET_ARGS[@]+"${RVDK_QUIET_ARGS[@]}"}
        else
            _brak_fetch_and_exec_script "${RVDK_BASE_URL}/install-cli.sh" "${RVDK_INSTALL_SHA256:-}" ${RVDK_QUIET_ARGS[@]+"${RVDK_QUIET_ARGS[@]}"}
        fi
    fi

    if [[ -n "$CANDIDATE_ROOT" && -f "${CANDIDATE_ROOT}/install-cli.sh" ]]; then
        exec bash "${CANDIDATE_ROOT}/install-cli.sh" ${BRAK_UPDATE_ARGS[@]+"${BRAK_UPDATE_ARGS[@]}"}
    elif [[ -f "${ENGINE_DIR}/install-cli.sh" ]]; then
        exec bash "${ENGINE_DIR}/install-cli.sh" ${BRAK_UPDATE_ARGS[@]+"${BRAK_UPDATE_ARGS[@]}"}
    else
        _brak_fetch_and_exec_script "${BRAKERRAK_BASE_URL}/install-cli.sh" "${BRAKERRAK_INSTALL_SHA256:-}" ${BRAK_UPDATE_ARGS[@]+"${BRAK_UPDATE_ARGS[@]}"}
        exit 0
    fi
fi

# Resolve LOCAL_ROOT without ever running `git fetch`/`git reset --hard` outside `update`/`install-cli.sh`.
if [[ -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/soc-drawer" && -f "${CANDIDATE_ROOT}/scripts/lib-common.sh" ]]; then
    if [[ "$CANDIDATE_ROOT" == */.brakerrak/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" ]]; then
        # Promote legacy ~/.brakerrak/engine into system-wide /usr/local/share/brakerrak/engine
        if [[ ! -d "${ENGINE_DIR}/.git" ]]; then
            install -d -m 0755 -o 0 -g 0 "$(dirname "$ENGINE_DIR")"
            rm -rf "$ENGINE_DIR"
            cp -a "$CANDIDATE_ROOT" "$ENGINE_DIR"
            chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
            chmod -R a+rX "$ENGINE_DIR" 2>/dev/null || true
            chmod 0755 "$ENGINE_DIR"
            log_ok "Promoted legacy checkout ${CANDIDATE_ROOT} -> ${ENGINE_DIR}"
        fi
        LOCAL_ROOT="$ENGINE_DIR"
    else
        LOCAL_ROOT="$CANDIDATE_ROOT"
    fi
elif [[ -d "${ENGINE_DIR}/.git" && -f "${ENGINE_DIR}/scripts/lib-common.sh" ]]; then
    LOCAL_ROOT="$ENGINE_DIR"
else
    # First-time bootstrap (e.g. `curl -fsSL https://brakerrak.dev/forge.sh | sudo bash`)
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
    install -d -m 0755 -o 0 -g 0 "$(dirname "$ENGINE_DIR")"
    log_brak "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
    rm -rf "$ENGINE_DIR"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
    chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
    chmod -R a+rX "$ENGINE_DIR" 2>/dev/null || true
    chmod 0755 "$ENGINE_DIR"
    LOCAL_ROOT="$ENGINE_DIR"
fi

# Ensure shared core library is sourced from LOCAL_ROOT
if [[ "${_BRAKERRAK_COMMON_SOURCED:-0}" != "1" ]]; then
    if [[ ! -f "${LOCAL_ROOT}/scripts/lib-common.sh" ]]; then
        log_fatal "Core library missing: ${LOCAL_ROOT}/scripts/lib-common.sh"
    fi
    # shellcheck disable=SC1091
    source "${LOCAL_ROOT}/scripts/lib-common.sh"
    brak_log_init "BRAKERRAK"
    brak_resolve_user
fi

# Refresh CLI symlinks on forge, if missing, or if pointing into a legacy ~/.brakerrak/engine path
_cur_bin_target="$(readlink -f /usr/local/bin/brakerrak 2>/dev/null || true)"
if [[ $EUID -eq 0 ]] && [[ "$ACTION" == "forge" || ! -L /usr/local/bin/brakerrak || "$_cur_bin_target" == */.brakerrak/engine/* ]]; then
    chmod +x "${LOCAL_ROOT}/forge.sh" "${LOCAL_ROOT}/install-cli.sh" "${LOCAL_ROOT}"/scripts/*.sh "${LOCAL_ROOT}"/benchmarks/*.sh 2>/dev/null || true
    install -d -m 0755 /usr/local/bin
    ln -sf "${LOCAL_ROOT}/forge.sh" /usr/local/bin/brakerrak
    if [[ "$(uname -s)" == "Linux" && -d /usr/bin ]]; then
        ln -sf "${LOCAL_ROOT}/forge.sh" /usr/bin/brakerrak
    fi
fi

# Resolve /etc/brakerrak/node.env (transparently migrating legacy ~/.brakerrak/node.env)
if [[ "$_HAS_STAGE_DIR" == "true" ]]; then
    brak_resolve_node_env
else
    brak_resolve_node_env --migrate
fi

# Delegate pre-FHS `/opt/drewv-pgdg-riscv64` APT repo migration to RVDK when present;
# strictly gated behind `ACTION == "forge"` so read-only/utility commands never mutate APT state.
_brak_delegate_legacy_pgdg_migration() {
    [[ "$ACTION" == "forge" ]] || return 0
    [[ -d /opt/drewv-pgdg-riscv64 || -f /etc/apt/sources.list.d/drewv-local-pgdg.list ]] || return 0

    local rvdk_cmd=""
    rvdk_cmd="$(_brak_resolve_rvdk_cmd || true)"
    if [[ -n "$rvdk_cmd" ]]; then
        if [[ -f /usr/local/share/rvdk/engine/utils/migrate-pgdg.sh ]]; then
            "$rvdk_cmd" utils/migrate-pgdg.sh
            log_ok "Delegated legacy /opt/drewv-pgdg-riscv64 APT migration to RVDK"
            return 0
        elif "$rvdk_cmd" --help 2>/dev/null | grep -qE '(^|[[:space:]])migrate-pgdg([[:space:]]|$)'; then
            "$rvdk_cmd" migrate-pgdg
            log_ok "Delegated legacy /opt/drewv-pgdg-riscv64 APT migration to RVDK"
            return 0
        elif "$rvdk_cmd" postgresql --help 2>/dev/null | grep -qE -- '--migrate-legacy'; then
            "$rvdk_cmd" postgresql --migrate-legacy
            log_ok "Delegated legacy /opt/drewv-pgdg-riscv64 APT migration to RVDK"
            return 0
        fi
        log_warn "Legacy /opt/drewv-pgdg-riscv64 detected; delegating PGDG APT repo setup to RVDK (removing stale drewv-local-pgdg.list)."
    else
        log_warn "Legacy /opt/drewv-pgdg-riscv64 detected before RVDK CLI install; removing stale drewv-local-pgdg.list."
    fi
    rm -f /etc/apt/sources.list.d/drewv-local-pgdg.list /var/lib/apt/lists/_opt_drewv-pgdg-riscv64* 2>/dev/null || true
}

# Quarantined fallback for reclaiming PG18 Sv39 HugePages when RVDK is absent or lacks a hook.
_brak_reclaim_hugepages_compat() {
    local _hp_reclaimed="false"
    if [[ -f /etc/sysctl.d/90-rvdk-pg18-hugepages.conf ]]; then
        rm -f /etc/sysctl.d/90-rvdk-pg18-hugepages.conf
        _hp_reclaimed="true"
    fi
    local _cur_hp
    _cur_hp="$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$_hp_reclaimed" == "true" ]] || { [[ "$_cur_hp" =~ ^[0-9]+$ ]] && (( _cur_hp > 0 )); }; then
        sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1 || true
        log_ok "Reclaimed static 2MB Sv39 HugePages (removed 90-rvdk-pg18-hugepages.conf & set vm.nr_hugepages=0)"
    fi
}

# Delegate HugePages disablement to RVDK CLI/hooks when available.
_brak_disable_hugepages() {
    local rvdk_cmd=""
    rvdk_cmd="$(_brak_resolve_rvdk_cmd || true)"
    if [[ -n "$rvdk_cmd" ]]; then
        if [[ -f /usr/local/share/rvdk/engine/utils/reclaim-hugepages.sh ]]; then
            "$rvdk_cmd" utils/reclaim-hugepages.sh
            log_ok "Delegated HugePages disablement to RVDK"
            return 0
        elif "$rvdk_cmd" postgresql --help 2>/dev/null | grep -qE -- '--disable'; then
            run_rvdk postgresql --disable
            log_ok "Delegated PostgreSQL/HugePages disablement to RVDK"
            return 0
        elif "$rvdk_cmd" postgresql --help 2>/dev/null | grep -qE -- '--reclaim-hugepages'; then
            run_rvdk postgresql --reclaim-hugepages
            log_ok "Delegated HugePages disablement to RVDK"
            return 0
        elif "$rvdk_cmd" deeptune --help 2>/dev/null | grep -qE -- '--reclaim-hugepages'; then
            run_rvdk deeptune --reclaim-hugepages
            log_ok "Delegated HugePages disablement to RVDK"
            return 0
        fi
    fi
    _brak_reclaim_hugepages_compat
}

# ==============================================================================
# 3. Route Shared Lifecycle Subcommands Immediately (deeptune | storage | ort | bench | verify | reset)
# ==============================================================================
case "$ACTION" in
    deeptune|deep-tune)
        DT_ROLE=""
        DT_TARGET="${BRAKERRAK_TARGET:-}"
        DT_STAGE_DIR=""
        DT_EXPLICIT_TUNE=""
        DT_PASS_ARGS=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --role)    brak_require_arg "$1" "${2:-}"; DT_ROLE="$2"; shift 2 ;;
                --role=*)  DT_ROLE="${1#*=}"; brak_require_arg "--role" "$DT_ROLE"; shift ;;
                --target)  brak_require_arg "$1" "${2:-}"; DT_TARGET="$2"; shift 2 ;;
                --target=*) DT_TARGET="${1#*=}"; brak_require_arg "--target" "$DT_TARGET"; shift ;;
                --stage-dir) brak_require_arg "$1" "${2:-}"; DT_STAGE_DIR="$2"; shift 2 ;;
                --stage-dir=*) DT_STAGE_DIR="${1#*=}"; brak_require_arg "--stage-dir" "$DT_STAGE_DIR"; shift ;;
                -t|--tune) brak_require_arg "$1" "${2:-}"; DT_EXPLICIT_TUNE="$2"; shift 2 ;;
                --tune=*)  DT_EXPLICIT_TUNE="${1#*=}"; brak_require_arg "--tune" "$DT_EXPLICIT_TUNE"; shift ;;
                *)         DT_PASS_ARGS+=("$1"); shift ;;
            esac
        done
        if [[ -n "$DT_STAGE_DIR" ]]; then
            DT_STAGE_DIR="${DT_STAGE_DIR%/}"
            [[ -n "$DT_STAGE_DIR" ]] || log_fatal "Refusing '/' as --stage-dir."
            NODE_ENV="${DT_STAGE_DIR}/config/node.env"
        fi
        if [[ -z "$DT_EXPLICIT_TUNE" ]]; then
            if [[ -z "$DT_ROLE" && -r "$NODE_ENV" ]]; then
                NODE_ROLE=""
                brak_load_kv_env "$NODE_ENV" NODE_ROLE RVDK_TUNE_PROFILE || true
                DT_ROLE="$NODE_ROLE"
                [[ -n "${RVDK_TUNE_PROFILE:-}" ]] && DT_EXPLICIT_TUNE="$(brak_normalize_tune "$RVDK_TUNE_PROFILE")"
            fi
            if [[ -z "$DT_EXPLICIT_TUNE" ]]; then
                DT_EXPLICIT_TUNE="$(brak_role_to_rvdk_tune "${DT_ROLE:-databroker}")"
            fi
        else
            _norm_dt_tune="$(brak_normalize_tune "$DT_EXPLICIT_TUNE")"
            if [[ -z "$_norm_dt_tune" ]]; then
                log_fatal "Unknown --tune profile '${DT_EXPLICIT_TUNE}' (expected: data | ai | iot)"
            fi
            DT_EXPLICIT_TUNE="$_norm_dt_tune"
        fi
        RVDK_BIN="$(_brak_resolve_rvdk_cmd || echo "$RVDK_BIN")"
        [[ -x "$RVDK_BIN" ]] || log_fatal "RVDK CLI not found at '${RVDK_BIN}'."
        if [[ -n "$DT_TARGET" ]] && ! brak_resolve_silicon "$DT_TARGET"; then
            log_fatal "Unknown --target '${DT_TARGET}'."
        elif [[ -z "$DT_TARGET" ]]; then
            brak_resolve_silicon "" >/dev/null 2>&1 || true
        fi
        for a in ${DT_PASS_ARGS[@]+"${DT_PASS_ARGS[@]}"}; do
            if [[ "$a" == "status" || "$a" == "--status" ]]; then
                if [[ "${TARGET_BOARD:-}" == "espressif-esp32p4" || -n "$DT_STAGE_DIR" ]]; then
                    _dt_sargs=()
                    [[ -n "$DT_STAGE_DIR" ]] && _dt_sargs=(--stage-dir "$DT_STAGE_DIR")
                    "$RVDK_BIN" bsp/espressif/esp32p4/deeptune.sh status ${_dt_sargs[@]+"${_dt_sargs[@]}"}
                    exec "$RVDK_BIN" boards/waveshare/esp32-p4-wifi6/deeptune.sh status ${_dt_sargs[@]+"${_dt_sargs[@]}"}
                fi
                exec "$RVDK_BIN" deeptune "${DT_PASS_ARGS[@]}"
            fi
        done
        if [[ "${TARGET_BOARD:-}" == "espressif-esp32p4" || -n "$DT_STAGE_DIR" ]]; then
            _dt_sargs=()
            [[ -n "$DT_STAGE_DIR" ]] && _dt_sargs=(--stage-dir "$DT_STAGE_DIR")
            "$RVDK_BIN" bsp/espressif/esp32p4/deeptune.sh --tune "$DT_EXPLICIT_TUNE" ${_dt_sargs[@]+"${_dt_sargs[@]}"} ${DT_PASS_ARGS[@]+"${DT_PASS_ARGS[@]}"}
            exec "$RVDK_BIN" boards/waveshare/esp32-p4-wifi6/deeptune.sh --tune "$DT_EXPLICIT_TUNE" ${_dt_sargs[@]+"${_dt_sargs[@]}"} ${DT_PASS_ARGS[@]+"${DT_PASS_ARGS[@]}"}
        fi
        exec "$RVDK_BIN" deeptune --tune "$DT_EXPLICIT_TUNE" ${DT_PASS_ARGS[@]+"${DT_PASS_ARGS[@]}"}
        ;;
    storage)
        if [[ -r "$NODE_ENV" ]]; then
            brak_load_kv_env "$NODE_ENV" VG_NAME LV_NAME NFS_LV_NAME MOUNT_POINT NFS_MOUNT_POINT || true
            export RVDK_ENV_FILE="$NODE_ENV"
        fi
        VG_NAME="${VG_NAME:-vg_braker}"
        LV_NAME="${LV_NAME:-lv_pgdata}"
        NFS_LV_NAME="${NFS_LV_NAME:-lv_nfsvault}"
        MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
        NFS_MOUNT_POINT="${NFS_MOUNT_POINT:-/mnt/nfs_vault}"
        if [[ ! -b "/dev/${VG_NAME}/${LV_NAME}" && -b "/dev/${VG_NAME}/lv_data" ]]; then
            LV_NAME="lv_data"
        fi
        export VG_NAME LV_NAME NFS_LV_NAME MOUNT_POINT NFS_MOUNT_POINT
        STORAGE_SUB="${1:-}"
        case "$STORAGE_SUB" in
            grow-psql|extend-psql|add-psql)
                shift
                exec "$RVDK_BIN" storage grow --lv "$LV_NAME" "$@"
                ;;
            grow-nfs|extend-nfs|add-nfs)
                shift
                exec "$RVDK_BIN" storage grow --lv "$NFS_LV_NAME" "$@"
                ;;
            shrink-nfs|reduce-nfs|reclaim-nfs)
                shift
                exec "$RVDK_BIN" storage shrink --lv "$NFS_LV_NAME" "$@"
                ;;
            *)
                exec "$RVDK_BIN" storage "$@"
                ;;
        esac
        ;;
    ort)
        exec bash "${LOCAL_ROOT}/scripts/ort-snapshot.sh" "$@"
        ;;
    bench)
        BENCH_SUB="${1:-showdown}"
        case "$BENCH_SUB" in
            -h|--help|help)
                print_bench_help
                exit 0
                ;;
            seed|seed-io-torture)
                shift
                exec bash "${LOCAL_ROOT}/benchmarks/seed-io-torture.sh" "$@"
                ;;
            showdown|run|io-showdown)
                shift
                exec bash "${LOCAL_ROOT}/benchmarks/run-iouring-showdown.sh" "$@"
                ;;
            analyze|report)
                shift
                _brak_run_bench_analyze "$LOCAL_ROOT" "$@"
                ;;
            -*)
                exec bash "${LOCAL_ROOT}/benchmarks/run-iouring-showdown.sh" "$@"
                ;;
            *)
                log_fatal "Unknown bench subcommand '${BENCH_SUB}' (expected: seed | showdown | analyze)"
                ;;
        esac
        ;;
    verify)
        exec bash "${LOCAL_ROOT}/scripts/verify-convergence.sh" "$@"
        ;;
    reset)
        exec bash "${LOCAL_ROOT}/scripts/reset-day0.sh" "$@"
        ;;
esac

# ==============================================================================
# 4. Parse CLI Flags & Overrides for 'forge' (Strict Fail-Fast Validation)
# ==============================================================================
TARGET_BOARD="${BRAKERRAK_TARGET:-}"
CLI_ROLE=""
CLI_MEDIA=""
CLI_STAGE_DIR=""
CLI_HOSTNAME=""
CLI_USER=""
CLI_SUBNET=""
CLI_NVME_DEV=""
CLI_MOUNT_POINT=""
CLI_NFS_MOUNT=""
CLI_WITH_RAID=""
CLI_ENABLE_PG=""
CLI_ENABLE_MQTT=""
CLI_ENABLE_NFS=""
CLI_NFS_BACKEND=""
CLI_WITH_DEEPTUNE="false"
CLI_DEEPTUNE_TUNE=""
CLI_WITH_TAILSCALE="false"
CLI_TS_AUTHKEY=""
CLI_TS_AUTHKEY_FILE=""
CLI_TS_FLAGS=()
CLI_TOPOLOGY_OVERRIDE="false"
FORCE_WIPE_NVME="false"
FORCE_WIPE_RAID="false"
FORCE_REBUILD_PG="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            brak_require_arg "$1" "${2:-}"
            TARGET_BOARD="$2"
            shift 2 ;;
        --target=*)
            TARGET_BOARD="${1#*=}"
            brak_require_arg "--target" "$TARGET_BOARD"
            shift ;;
        --role)
            brak_require_arg "$1" "${2:-}"
            CLI_ROLE="$2"
            shift 2 ;;
        --role=*)
            CLI_ROLE="${1#*=}"
            brak_require_arg "--role" "$CLI_ROLE"
            shift ;;
        --media)
            brak_require_arg "$1" "${2:-}"
            CLI_MEDIA="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --media=*)
            CLI_MEDIA="${1#*=}"
            brak_require_arg "--media" "$CLI_MEDIA"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --stage-dir)
            brak_require_arg "$1" "${2:-}"
            CLI_STAGE_DIR="$2"
            shift 2 ;;
        --stage-dir=*)
            CLI_STAGE_DIR="${1#*=}"
            brak_require_arg "--stage-dir" "$CLI_STAGE_DIR"
            shift ;;
        --hostname)
            brak_require_arg "$1" "${2:-}"
            CLI_HOSTNAME="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --hostname=*)
            CLI_HOSTNAME="${1#*=}"
            brak_require_arg "--hostname" "$CLI_HOSTNAME"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --user)
            brak_require_arg "$1" "${2:-}"
            CLI_USER="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --user=*)
            CLI_USER="${1#*=}"
            brak_require_arg "--user" "$CLI_USER"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --subnet)
            brak_require_arg "$1" "${2:-}"
            CLI_SUBNET="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --subnet=*)
            CLI_SUBNET="${1#*=}"
            brak_require_arg "--subnet" "$CLI_SUBNET"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --nvme-dev)
            brak_require_arg "$1" "${2:-}"
            CLI_NVME_DEV="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --nvme-dev=*)
            CLI_NVME_DEV="${1#*=}"
            brak_require_arg "--nvme-dev" "$CLI_NVME_DEV"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --mount-point)
            brak_require_arg "$1" "${2:-}"
            CLI_MOUNT_POINT="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --mount-point=*)
            CLI_MOUNT_POINT="${1#*=}"
            brak_require_arg "--mount-point" "$CLI_MOUNT_POINT"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --nfs-mount)
            brak_require_arg "$1" "${2:-}"
            CLI_NFS_MOUNT="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --nfs-mount=*)
            CLI_NFS_MOUNT="${1#*=}"
            brak_require_arg "--nfs-mount" "$CLI_NFS_MOUNT"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --with-raid)
            CLI_WITH_RAID="true"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --no-raid)
            CLI_WITH_RAID="false"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --with-pg|--with-postgres)
            CLI_ENABLE_PG="true"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --no-pg|--no-postgres)
            CLI_ENABLE_PG="false"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --with-mqtt)
            CLI_ENABLE_MQTT="true"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --no-mqtt)
            CLI_ENABLE_MQTT="false"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --with-nfs)
            CLI_ENABLE_NFS="true"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --no-nfs)
            CLI_ENABLE_NFS="false"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --nfs-backend)
            brak_require_arg "$1" "${2:-}"
            CLI_NFS_BACKEND="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --nfs-backend=*)
            CLI_NFS_BACKEND="${1#*=}"
            brak_require_arg "--nfs-backend" "$CLI_NFS_BACKEND"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --nfs-ganesha)
            CLI_NFS_BACKEND="ganesha"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --nfs-kernel|--nfs-kernal)
            CLI_NFS_BACKEND="kernel"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --nfs-auto)
            CLI_NFS_BACKEND="auto"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --deeptune|--deep-tune|--with-deeptune)
            CLI_WITH_DEEPTUNE="true"
            shift ;;
        --tune|-t)
            brak_require_arg "$1" "${2:-}"
            CLI_WITH_DEEPTUNE="true"
            CLI_DEEPTUNE_TUNE="$2"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift 2 ;;
        --tune=*)
            CLI_DEEPTUNE_TUNE="${1#*=}"
            brak_require_arg "--tune" "$CLI_DEEPTUNE_TUNE"
            CLI_WITH_DEEPTUNE="true"
            CLI_TOPOLOGY_OVERRIDE="true"
            shift ;;
        --with-tailscale|--tailscale)
            CLI_WITH_TAILSCALE="true"
            shift ;;
        --tailscale-up|--ts-up)
            CLI_WITH_TAILSCALE="true"
            CLI_TS_FLAGS+=("--up")
            shift ;;
        --tailscale-ssh|--ts-ssh)
            CLI_WITH_TAILSCALE="true"
            CLI_TS_FLAGS+=("--ssh")
            shift ;;
        --tailscale-authkey|--ts-authkey|--tailscale-authkey=*|--ts-authkey=*)
            log_fatal "Option '${1%%=*}' is no longer supported because CLI argv exposes secrets in /proc/<pid>/cmdline. Use --tailscale-authkey-file <path> (0600) or the TS_AUTHKEY environment variable." ;;
        --tailscale-authkey-file|--ts-authkey-file)
            brak_require_arg "$1" "${2:-}"
            CLI_WITH_TAILSCALE="true"
            CLI_TS_AUTHKEY_FILE="$2"
            shift 2 ;;
        --tailscale-authkey-file=*|--ts-authkey-file=*)
            CLI_TS_AUTHKEY_FILE="${1#*=}"
            brak_require_arg "${1%%=*}" "$CLI_TS_AUTHKEY_FILE"
            CLI_WITH_TAILSCALE="true"
            shift ;;
        --tailscale-routes)
            brak_require_arg "$1" "${2:-}"
            CLI_WITH_TAILSCALE="true"
            CLI_TS_FLAGS+=("--advertise-routes" "$2")
            shift 2 ;;
        --tailscale-routes=*)
            _ts_routes="${1#*=}"
            brak_require_arg "--tailscale-routes" "$_ts_routes"
            CLI_WITH_TAILSCALE="true"
            CLI_TS_FLAGS+=("--advertise-routes" "$_ts_routes")
            shift ;;
        --tailscale-userspace)
            CLI_WITH_TAILSCALE="true"
            CLI_TS_FLAGS+=("--userspace")
            shift ;;
        --no-apt-update|--skip-apt-update)
            APT_UPDATED="true"
            shift ;;
        --force-wipe-nvme)
            FORCE_WIPE_NVME="true"
            shift ;;
        --force-wipe-raid)
            FORCE_WIPE_RAID="true"
            shift ;;
        --force-rebuild-pg|--force-build|--compile-pg|--no-pkg-cache)
            FORCE_REBUILD_PG="true"
            shift ;;
        --use-pkg-cache)
            FORCE_REBUILD_PG="false"
            shift ;;
        --noprogbar|--no-progbar)
            export BRAKERRAK_NO_PROGBAR="1"
            export RVDK_NO_PROGBAR="1"
            shift ;;
        --version|-V)
            print_version
            exit 0 ;;
        -h|--help)
            print_usage
            exit 0 ;;
        *)
            log_fatal "Unknown argument: $1 (run 'brakerrak --help' for usage)" ;;
    esac
done

# Validate optional --media and --stage-dir overrides
if [[ -n "$CLI_MEDIA" ]]; then
    CLI_MEDIA="$(tr '[:upper:]' '[:lower:]' <<< "$CLI_MEDIA")"
    case "$CLI_MEDIA" in
        nvme|sd) ;;
        *) log_fatal "Unknown --media '${CLI_MEDIA}' (expected: nvme | sd)" ;;
    esac
fi

if [[ -n "$CLI_STAGE_DIR" ]]; then
    if [[ "$CLI_STAGE_DIR" =~ [[:cntrl:]] ]]; then
        log_fatal "Invalid --stage-dir path containing control characters."
    fi
    CLI_STAGE_DIR="${CLI_STAGE_DIR%/}"
    if [[ -z "$CLI_STAGE_DIR" ]]; then
        log_fatal "Refusing '/' as --stage-dir."
    fi
    NODE_ENV="${CLI_STAGE_DIR}/config/node.env"
    export NODE_ENV
fi

# Validate and read --tailscale-authkey-file (enforcing 0600 permissions)
if [[ -n "$CLI_TS_AUTHKEY_FILE" ]]; then
    if [[ ! -f "$CLI_TS_AUTHKEY_FILE" || ! -r "$CLI_TS_AUTHKEY_FILE" ]]; then
        log_fatal "Tailscale authkey file not found or unreadable: ${CLI_TS_AUTHKEY_FILE}"
    fi
    _ts_mode="$(stat -c '%a' "$CLI_TS_AUTHKEY_FILE" 2>/dev/null || stat -f '%Lp' "$CLI_TS_AUTHKEY_FILE" 2>/dev/null || echo "")"
    if [[ "$_ts_mode" != "600" && "$_ts_mode" != "400" ]]; then
        log_fatal "Refusing --tailscale-authkey-file '${CLI_TS_AUTHKEY_FILE}': permissions must be 0600 (found: ${_ts_mode:-unknown}). Run: chmod 0600 '${CLI_TS_AUTHKEY_FILE}'"
    fi
    CLI_TS_AUTHKEY="$(tr -d '\r\n' < "$CLI_TS_AUTHKEY_FILE")"
    if [[ -z "$CLI_TS_AUTHKEY" ]]; then
        log_fatal "Tailscale authkey file is empty: ${CLI_TS_AUTHKEY_FILE}"
    fi
fi

RUNTIME_DIR="$(brak_runtime_dir)"
export BRAKERRAK_RUNTIME_DIR="$RUNTIME_DIR"
APT_STAMP_FILE="${RUNTIME_DIR}/apt-$$.stamp"
export RVDK_APT_STAMP_FILE="$APT_STAMP_FILE"
if [[ "$APT_UPDATED" != "true" ]]; then
    rm -f "$APT_STAMP_FILE" 2>/dev/null || true
fi

# Dispatch an RVDK subcommand while propagating `--no-apt-update` once APT_UPDATED=true
run_rvdk() {
    local subcmd="$1"
    shift
    if [[ "$APT_UPDATED" == "true" && "$TARGET_BOARD" != "espressif-esp32p4" && -z "$CLI_STAGE_DIR" && "$subcmd" != bsp/espressif/esp32p4/* && "$subcmd" != boards/waveshare/* ]]; then
        "$RVDK_BIN" "$subcmd" --no-apt-update "$@"
    else
        "$RVDK_BIN" "$subcmd" "$@"
        if [[ -f "$APT_STAMP_FILE" ]]; then
            APT_UPDATED="true"
        fi
    fi
}

# ==============================================================================
# 5. Resolve Silicon Target & Short Tag (Unified `brak_resolve_silicon`)
# ==============================================================================
if ! brak_resolve_silicon "$TARGET_BOARD"; then
    log_fatal "Could not auto-detect silicon target from Device Tree: '${DT_MODEL}'. Pass --target <board>."
fi

if [[ -n "$CLI_STAGE_DIR" && "$TARGET_BOARD" != "espressif-esp32p4" ]]; then
    log_fatal "--stage-dir host-staged SD convergence is only supported for ESP32-P4 (--target espressif-esp32p4 / p4; resolved '${TARGET_BOARD}')."
fi

if [[ "$TARGET_BOARD" == "espressif-esp32p4" ]]; then
    TARGET_ARCH="riscv32"
    STORAGE_MEDIA="sd"
    if [[ "$CLI_ENABLE_PG" == "true" ]]; then
        log_fatal "--with-pg is unsupported on ${TARGET_BOARD} (riscv32 nommu MCU-class SoC has no MMU/PCIe or PostgreSQL 18 support)."
    fi
    if [[ "$CLI_ENABLE_NFS" == "true" ]]; then
        log_fatal "--with-nfs is unsupported on ${TARGET_BOARD} (riscv32 nommu MCU-class SoC cannot host NFSv4 vault servers)."
    fi
    if [[ "$CLI_WITH_RAID" == "true" ]]; then
        log_fatal "--with-raid is unsupported on ${TARGET_BOARD} (riscv32 SD-media SoC has no PCIe/USB RAID 10 tier)."
    fi
    if [[ "$CLI_ENABLE_MQTT" == "true" ]]; then
        log_fatal "--with-mqtt is unsupported on ${TARGET_BOARD} (riscv32 nommu MCU-class SoC cannot host Eclipse Mosquitto broker)."
    fi
    if [[ "$CLI_MEDIA" == "nvme" ]]; then
        log_fatal "--media nvme is unsupported on ${TARGET_BOARD} (no PCIe/NVMe bus; use --media sd)."
    fi
    if [[ "$CLI_WITH_TAILSCALE" == "true" ]]; then
        log_fatal "--with-tailscale is unsupported on ${TARGET_BOARD} (no Go/Tailscale runtime on riscv32)."
    fi
fi

if [[ -f "${LOCAL_ROOT}/scripts/lib-progbar.sh" ]]; then
    # shellcheck disable=SC1091
    source "${LOCAL_ROOT}/scripts/lib-progbar.sh"
else
    brak_prog_init()    { :; }
    brak_prog()         { :; }
    brak_prog_cleanup() { :; }
fi

brak_prog_init "Resolving ${TARGET_BOARD} node configuration..."
log_brak "Silicon Target: ${TARGET_BOARD} (${DT_MODEL}) | Arch: ${TARGET_ARCH} | Media: ${STORAGE_MEDIA} | Action: ${ACTION}"

# ==============================================================================
# 6. CONFIG RESOLUTION (Pass 1 Template Generation, Pass 2 Load & Role Flipping)
# ==============================================================================
if [[ -z "$CLI_STAGE_DIR" ]]; then
    if [[ $EUID -eq 0 ]]; then
        install -d -m 0750 -o "$REAL_USER" -g "$REAL_GRP" "$BRAKER_DIR" "$SNAP_DIR"
    else
        mkdir -p "$BRAKER_DIR" "$SNAP_DIR"
        chmod 0750 "$BRAKER_DIR" "$SNAP_DIR" 2>/dev/null || true
    fi
fi

# If Pass 1 was run from the factory default user (e.g. 'user' on JH7110) and we are now
# running as the designated admin user before purging 'user', pre-seed /etc/brakerrak/node.env
# from /home/<factory_user>/.brakerrak/node.env when no node.env exists yet.
if [[ -z "$CLI_STAGE_DIR" && -z "${BRAKERRAK_NODE_ENV:-}" && -n "$FACTORY_USER" && "$REAL_USER" != "$FACTORY_USER" && ! -f "$NODE_ENV" && -f "/home/${FACTORY_USER}/.brakerrak/node.env" ]]; then
    install -d -m 0755 -o 0 -g 0 "$(dirname "$NODE_ENV")"
    sed "s/^ADMIN_USER=\"${FACTORY_USER}\"/ADMIN_USER=\"${REAL_USER}\"/" "/home/${FACTORY_USER}/.brakerrak/node.env" \
        | brak_atomic_write "$NODE_ENV" 0640 "0:${REAL_GRP}"
    log_ok "Adopted Pass 1 node.env from /home/${FACTORY_USER}/.brakerrak/node.env -> ${NODE_ENV}"
fi

# Ensure LAB_SUBNET starts unset so an explicit LAB_SUBNET="" in node.env is distinguishable
# from an absent key (${CLI_SUBNET:-${LAB_SUBNET-10.0.0.0/24}}).
unset LAB_SUBNET

WRITE_NODE_ENV="false"
if [[ -f "$NODE_ENV" ]]; then
    FORGE_PASS="2"
    log_brak "Pass 2 Detected: Loading node configuration from ${NODE_ENV}"
    brak_load_kv_env "$NODE_ENV" || log_fatal "Failed to read node configuration: ${NODE_ENV}"
    SAVED_ROLE="$(brak_normalize_role "${NODE_ROLE:-databroker}")"
    [[ -z "$SAVED_ROLE" ]] && SAVED_ROLE="databroker"
    NODE_ROLE="$SAVED_ROLE"

    if [[ -n "$CLI_ROLE" ]]; then
        REQUESTED_ROLE="$(brak_normalize_role "$CLI_ROLE")"
        [[ -z "$REQUESTED_ROLE" ]] && log_fatal "Unknown role '${CLI_ROLE}' (expected: databroker | databench | babbagebox | babbagebench | visionbox | visionbench | devbench | snitchbench | lilsnitch)"
        if [[ "$REQUESTED_ROLE" != "$SAVED_ROLE" ]]; then
            log_brak "Stateless Persona Flip: ${SAVED_ROLE} -> ${REQUESTED_ROLE}"
            NODE_ROLE="$REQUESTED_ROLE"
            WRITE_NODE_ENV="true"
            unset ENABLE_POSTGRES ENABLE_MQTT_BROKER ENABLE_NFS_SERVER PIGEON_ROLE RVDK_TUNE_PROFILE STORAGE_MEDIA
            if [[ -z "$CLI_HOSTNAME" && "${TARGET_HOSTNAME:-}" =~ ^(brakerbox|brakerbench|databroker|databench|babbagebox|babbagebench|visionbox|visionbench|vferret|visionferret|devbench|snitchbench|lilsnitch)- ]]; then
                unset TARGET_HOSTNAME
            fi
        fi
    fi

    if [[ "$CLI_TOPOLOGY_OVERRIDE" == "true" ]]; then
        WRITE_NODE_ENV="true"
    fi
else
    FORGE_PASS="1"
    WRITE_NODE_ENV="true"
    NODE_ROLE="$(brak_normalize_role "${CLI_ROLE:-databroker}")"
    [[ -z "$NODE_ROLE" ]] && log_fatal "Unknown role '${CLI_ROLE}' (expected: databroker | databench | babbagebox | babbagebench | visionbox | visionbench | devbench | snitchbench | lilsnitch)"
fi

ROLE_ENV_FILE="${LOCAL_ROOT}/roles/${NODE_ROLE}.env"
[[ ! -f "$ROLE_ENV_FILE" ]] && log_fatal "Role definition file missing: ${ROLE_ENV_FILE}"
# shellcheck disable=SC1090
source "$ROLE_ENV_FILE"

TARGET_HOSTNAME="${CLI_HOSTNAME:-${TARGET_HOSTNAME:-${NODE_ROLE}-${TARGET_TAG}}}"
TARGET_ARCH="${TARGET_ARCH:-riscv64}"
STORAGE_MEDIA="${CLI_MEDIA:-${STORAGE_MEDIA:-nvme}}"
ADMIN_USER="${CLI_USER:-${ADMIN_USER:-$REAL_USER}}"
LAB_SUBNET="${CLI_SUBNET:-${LAB_SUBNET-10.0.0.0/24}}"
NVME_DEV="${CLI_NVME_DEV:-${NVME_DEV:-/dev/nvme0n1}}"
MOUNT_POINT="${CLI_MOUNT_POINT:-${MOUNT_POINT:-/mnt/nvme_pgdata}}"
NFS_MOUNT_POINT="${CLI_NFS_MOUNT:-${NFS_MOUNT_POINT:-/mnt/nfs_vault}}"
VG_NAME="${VG_NAME:-vg_braker}"
LV_NAME="${LV_NAME:-lv_pgdata}"
FS_LABEL="${FS_LABEL:-PGDATA_NVME}"
NFS_LV_NAME="${NFS_LV_NAME:-lv_nfsvault}"
NFS_FS_LABEL="${NFS_FS_LABEL:-NFS_VAULT}"
WITH_RAID="${CLI_WITH_RAID:-${WITH_RAID:-false}}"
RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"
ENABLE_POSTGRES="${CLI_ENABLE_PG:-${ENABLE_POSTGRES:-true}}"
ENABLE_MQTT_BROKER="${CLI_ENABLE_MQTT:-${ENABLE_MQTT_BROKER:-false}}"
MQTT_PORT="${MQTT_PORT:-1883}"
ENABLE_NFS_SERVER="${CLI_ENABLE_NFS:-${ENABLE_NFS_SERVER:-false}}"
NFS_BACKEND="${CLI_NFS_BACKEND:-${NFS_BACKEND:-ganesha}}"
PIGEON_ROLE="${PIGEON_ROLE:-pigeoneer}"
RVDK_TUNE_PROFILE="${CLI_DEEPTUNE_TUNE:-${RVDK_TUNE_PROFILE:-$(brak_role_to_rvdk_tune "$NODE_ROLE")}}"
_norm_tune="$(brak_normalize_tune "$RVDK_TUNE_PROFILE")"
if [[ -n "$_norm_tune" ]]; then
    RVDK_TUNE_PROFILE="$_norm_tune"
else
    if [[ -n "$CLI_DEEPTUNE_TUNE" ]]; then
        log_fatal "Unknown --tune profile '${CLI_DEEPTUNE_TUNE}' (expected: data | ai | iot)"
    fi
    RVDK_TUNE_PROFILE="$(brak_role_to_rvdk_tune "$NODE_ROLE")"
fi
SHARE_ORT_SNAPSHOT="${SHARE_ORT_SNAPSHOT:-false}"

if [[ "$TARGET_BOARD" == "espressif-esp32p4" ]]; then
    TARGET_ARCH="riscv32"
    STORAGE_MEDIA="sd"
    if [[ "$ENABLE_POSTGRES" == "true" ]]; then
        ENABLE_POSTGRES="false"
        log_skip "Clamped ENABLE_POSTGRES=false for ${TARGET_BOARD} (no MMU/PCIe/PG18 on riscv32; role=${NODE_ROLE})"
    fi
    if [[ "$ENABLE_MQTT_BROKER" == "true" ]]; then
        ENABLE_MQTT_BROKER="false"
        log_skip "Clamped ENABLE_MQTT_BROKER=false for ${TARGET_BOARD} (MCU-class riscv32 target; role=${NODE_ROLE})"
    fi
    if [[ "$ENABLE_NFS_SERVER" == "true" ]]; then
        ENABLE_NFS_SERVER="false"
        log_skip "Clamped ENABLE_NFS_SERVER=false for ${TARGET_BOARD} (MCU-class riscv32 target; role=${NODE_ROLE})"
    fi
    if [[ "$WITH_RAID" == "true" ]]; then
        WITH_RAID="false"
        log_skip "Clamped WITH_RAID=false for ${TARGET_BOARD} (SD media target; role=${NODE_ROLE})"
    fi
fi

NFS_BACKEND="$(tr '[:upper:]' '[:lower:]' <<< "$NFS_BACKEND")"
case "$NFS_BACKEND" in
    ganesha|nfs-ganesha|userspace)           NFS_BACKEND="ganesha" ;;
    kernel|nfs-kernel|nfs-kernal|knfsd|nfsd) NFS_BACKEND="kernel" ;;
    auto)                                    NFS_BACKEND="auto" ;;
    *)
        log_fatal "Unknown NFS_BACKEND '${NFS_BACKEND}' (expected: ganesha | kernel | auto)"
        ;;
esac

# Upgrade legacy node.env schemas atomically if required keys are missing or use deprecated 'ml'
if [[ "$WRITE_NODE_ENV" != "true" && -f "$NODE_ENV" ]]; then
    if ! grep -q '^NFS_MOUNT_POINT=' "$NODE_ENV" 2>/dev/null \
       || ! grep -q '^NFS_BACKEND=' "$NODE_ENV" 2>/dev/null \
       || ! grep -q '^ENABLE_POSTGRES=' "$NODE_ENV" 2>/dev/null \
       || ! grep -q '^RVDK_TUNE_PROFILE=' "$NODE_ENV" 2>/dev/null \
       || ! grep -q '^TARGET_ARCH=' "$NODE_ENV" 2>/dev/null \
       || ! grep -q '^STORAGE_MEDIA=' "$NODE_ENV" 2>/dev/null \
       || grep -qE '^RVDK_TUNE_PROFILE=["'\'']?ml["'\'']?$' "$NODE_ENV" 2>/dev/null; then
        WRITE_NODE_ENV="true"
    fi
fi

if [[ "$WRITE_NODE_ENV" == "true" ]]; then
    if [[ -n "$CLI_STAGE_DIR" ]]; then
        mkdir -p "${CLI_STAGE_DIR}/config"
        brak_write_node_env "$NODE_ENV" "" 0644
    else
        brak_write_node_env "$NODE_ENV" "0:${REAL_GRP}" 0640
    fi
    log_ok "Persisted node configuration (${NODE_ROLE} -> ${TARGET_HOSTNAME}): ${NODE_ENV}"
fi

export BRAKERRAK_NODE_ENV="$NODE_ENV"
export RVDK_ENV_FILE="$NODE_ENV"
export NODE_ROLE TARGET_HOSTNAME TARGET_ARCH STORAGE_MEDIA ADMIN_USER LAB_SUBNET NVME_DEV MOUNT_POINT NFS_MOUNT_POINT VG_NAME LV_NAME FS_LABEL NFS_LV_NAME NFS_FS_LABEL WITH_RAID RAID_ARRAYS_JSON ENABLE_POSTGRES ENABLE_MQTT_BROKER MQTT_PORT ENABLE_NFS_SERVER NFS_BACKEND PIGEON_ROLE RVDK_TUNE_PROFILE

# ==============================================================================
# 7. ENSURE RVDK CLI IS INSTALLED & DISPATCH MODULAR RVDK PIPELINE
# ==============================================================================
if [[ ! -x "$RVDK_BIN" ]]; then
    if command -v rvdk >/dev/null 2>&1; then
        RVDK_BIN="$(command -v rvdk)"
    elif [[ $EUID -eq 0 && -z "$CLI_STAGE_DIR" ]]; then
        brak_prog 5 "Stage 0A: Installing RVDK CLI..." 0 "Cloning RVDK engine..."
        log_step "0A. Installing RVDK Package Manager CLI (${RVDK_BASE_URL}/install-cli.sh)"
        _brak_fetch_and_exec_script "${RVDK_BASE_URL}/install-cli.sh" "${RVDK_INSTALL_SHA256:-}" --quiet
        [[ -x /usr/bin/rvdk ]] && RVDK_BIN="/usr/bin/rvdk" || RVDK_BIN="/usr/local/bin/rvdk"
    else
        log_fatal "RVDK CLI not found at '${RVDK_BIN}' or PATH (install RVDK or set RVDK_BIN)."
    fi
fi

if [[ "$TARGET_BOARD" != "espressif-esp32p4" && -z "$CLI_STAGE_DIR" ]]; then
    _brak_delegate_legacy_pgdg_migration
fi

if [[ "$TARGET_BOARD" == "espressif-esp32p4" ]]; then
    brak_prog 8 "Stage 1/7: ESP32-P4 BSP Provenance (${TARGET_HOSTNAME})" 0 "Launching rvdk bsp/espressif/esp32p4/forge.sh..."
    log_step "1. RVDK ESP32-P4 BSP Provenance Convergence (Hostname: ${TARGET_HOSTNAME})"
    if [[ -n "$CLI_STAGE_DIR" ]]; then
        run_rvdk bsp/espressif/esp32p4/forge.sh --stage-dir "$CLI_STAGE_DIR"
    else
        run_rvdk bsp/espressif/esp32p4/forge.sh
    fi
else
    brak_prog 8 "Stage 1/7: Day-0 OS & Silicon BSP (${TARGET_HOSTNAME})" 0 "Launching rvdk day0..."
    log_step "1. RVDK Day-0 OS & Silicon BSP Convergence (Hostname: ${TARGET_HOSTNAME})"
    run_rvdk day0 --user "$ADMIN_USER" --hostname "$TARGET_HOSTNAME" --nopasswd
fi

if [[ "$TARGET_BOARD" == "espressif-esp32p4" || "$STORAGE_MEDIA" == "sd" || -n "$CLI_STAGE_DIR" ]]; then
    brak_prog 35 "Stage 2/7: SD Media Target (Skipping 4Kn NVMe LVM)" 100 "mods/nvme-4kn skipped"
    log_step "2. NVMe 4Kn LVM Provisioning Skipped (${TARGET_BOARD} / media=${STORAGE_MEDIA})"
    log_skip "SD media target (${TARGET_BOARD}); skipping 4Kn NVMe LVM stage"
else
    NVME_FLAGS=(--device "$NVME_DEV" --mount "$MOUNT_POINT" --vg "$VG_NAME" --lv "$LV_NAME" --label "$FS_LABEL")
    USE_DUAL_NFS_LV="false"
    if [[ "$ENABLE_NFS_SERVER" == "true" && "$WITH_RAID" != "true" ]]; then
        # Preserve brownfield single-LV nodes whose NFS vault already lives at ${MOUNT_POINT}/nfs_vault
        # while enabling Dual-LVM on fresh builds, --force-wipe-nvme, existing Dual-LVM nodes, and role flips.
        if [[ "$FORCE_WIPE_NVME" == "true" ]] \
           || mountpoint -q "$NFS_MOUNT_POINT" 2>/dev/null \
           || [[ -b "/dev/${VG_NAME}/${NFS_LV_NAME}" ]] \
           || ! mountpoint -q "$MOUNT_POINT" 2>/dev/null \
           || [[ ! -d "${MOUNT_POINT}/nfs_vault" ]]; then
            USE_DUAL_NFS_LV="true"
        fi
    fi

    if [[ "$USE_DUAL_NFS_LV" == "true" ]]; then
        brak_prog 28 "Stage 2/7: Dual-LVM 4Kn NVMe (${MOUNT_POINT} XFS + ${NFS_MOUNT_POINT} Btrfs)" 0 "Launching rvdk mods/nvme-4kn --with-nfs-lv..."
        log_step "2. RVDK Dual-LVM 4Kn NVMe Provisioning (${NVME_DEV} -> ${MOUNT_POINT} + ${NFS_MOUNT_POINT})"
        NVME_FLAGS+=(--with-nfs-lv --nfs-mount "$NFS_MOUNT_POINT" --nfs-lv "$NFS_LV_NAME" --nfs-label "$NFS_FS_LABEL")
    else
        brak_prog 28 "Stage 2/7: Hot NVMe 4Kn Storage (${NVME_DEV} -> ${MOUNT_POINT})" 0 "Launching rvdk mods/nvme-4kn..."
        log_step "2. RVDK Hot NVMe 4Kn Storage Provisioning (${NVME_DEV} -> ${MOUNT_POINT})"
    fi
    [[ "$FORCE_WIPE_NVME" == "true" ]] && NVME_FLAGS+=(--force-wipe)
    run_rvdk mods/nvme-4kn "${NVME_FLAGS[@]}"
fi

if [[ "$ENABLE_POSTGRES" == "true" ]]; then
    brak_prog 45 "Stage 3/7: PostgreSQL 18.6 (io_uring + Sv39 HugePages)" 0 "Launching rvdk postgresql..."
    log_step "3. RVDK PostgreSQL 18.6 Convergence (io_uring + Sv39 HugePages)"
    PG_FLAGS=(--data-mount "$MOUNT_POINT")
    [[ -n "$LAB_SUBNET" ]] && PG_FLAGS+=(--subnet "$LAB_SUBNET")
    [[ "$FORCE_REBUILD_PG" == "true" ]] && PG_FLAGS+=(--force-build)
    run_rvdk postgresql "${PG_FLAGS[@]}"
else
    brak_prog 65 "Stage 3/7: PostgreSQL 18.6 Skipped (ENABLE_POSTGRES=false)" 100 "postgresql skipped (${NODE_ROLE})"
    log_step "3. PostgreSQL 18.6 Convergence Skipped (ENABLE_POSTGRES=false for ${NODE_ROLE})"
    if [[ "$TARGET_BOARD" == "espressif-esp32p4" || -n "$CLI_STAGE_DIR" ]]; then
        log_skip "PostgreSQL 18.6 skipped on ${TARGET_BOARD} (${TARGET_ARCH}, media=${STORAGE_MEDIA})"
    else
        if systemctl is-active --quiet postgresql.service 2>/dev/null || systemctl is-active --quiet postgresql 2>/dev/null; then
            systemctl disable --now postgresql 2>/dev/null || systemctl disable --now postgresql.service 2>/dev/null || true
            log_ok "Stopped & disabled postgresql to free RAM/HugePages for ${NODE_ROLE} workloads"
        fi
        _brak_disable_hugepages
    fi
fi

if [[ "$WITH_RAID" == "true" ]]; then
    brak_prog 70 "Stage 4/7: Btrfs RAID 10 Vault Provisioning" 0 "Launching rvdk mods/btrfs-raid..."
    log_step "4. RVDK Btrfs RAID 10 Vault Provisioning & Tablespace Binding"
    RAID_FLAGS=(--json "$RAID_ARRAYS_JSON")
    [[ "$FORCE_WIPE_RAID" == "true" ]] && RAID_FLAGS+=(--force-wipe-raid)
    run_rvdk mods/btrfs-raid "${RAID_FLAGS[@]}"
else
    brak_prog 74 "Stage 4/7: Btrfs RAID 10 Skipped (WITH_RAID=false)" 100 "mods/btrfs-raid skipped"
    log_step "4. Btrfs RAID 10 Vault Provisioning Skipped (WITH_RAID=false)"
    if [[ "$TARGET_BOARD" == "espressif-esp32p4" || -n "$CLI_STAGE_DIR" ]]; then
        log_skip "Btrfs RAID 10 skipped on ${TARGET_BOARD} (${TARGET_ARCH}, media=${STORAGE_MEDIA})"
    fi
fi

if [[ "$ENABLE_MQTT_BROKER" == "true" ]]; then
    brak_prog 78 "Stage 5A/7: Eclipse Mosquitto MQTT Broker (:${MQTT_PORT})" 0 "Launching rvdk mods/mosquitto..."
    log_step "5A. RVDK Eclipse Mosquitto MQTT Broker (:${MQTT_PORT} + Unix Socket)"
    rm -f /etc/mosquitto/conf.d/brakerrak.conf /etc/mosquitto/conf.d/99-brakerrak.conf 2>/dev/null || true
    run_rvdk mods/mosquitto --port "$MQTT_PORT" --data-mount "$MOUNT_POINT"
else
    brak_prog 82 "Stage 5A/7: Mosquitto MQTT Skipped (ENABLE_MQTT_BROKER=false)" 100 "mods/mosquitto skipped"
    log_step "5A. Mosquitto MQTT Broker Skipped (ENABLE_MQTT_BROKER=false)"
    if [[ "$TARGET_BOARD" == "espressif-esp32p4" || -n "$CLI_STAGE_DIR" ]]; then
        log_skip "Mosquitto MQTT broker skipped on ${TARGET_BOARD} (${TARGET_ARCH}, media=${STORAGE_MEDIA})"
    elif systemctl is-active --quiet mosquitto.service 2>/dev/null; then
        systemctl disable --now mosquitto.service 2>/dev/null || true
        log_ok "Disabled mosquitto.service for ${NODE_ROLE} isolation"
    fi
fi

if [[ "$ENABLE_NFS_SERVER" == "true" ]]; then
    brak_prog 86 "Stage 5B/7: NFSv4 Vault Exports (${NFS_BACKEND} -> ${LAB_SUBNET:-auto-subnet})" 0 "Launching rvdk mods/nfs-vault..."
    log_step "5B. RVDK NFSv4 Vault Exports (${NFS_BACKEND} -> ${LAB_SUBNET:-auto-subnet})"
    rm -f /etc/exports.d/brakerrak-vaults.exports 2>/dev/null || true
    NFS_FLAGS=(--data-mount "$MOUNT_POINT" --backend "$NFS_BACKEND")
    if [[ -n "$LAB_SUBNET" ]]; then
        NFS_FLAGS+=(--subnet "$LAB_SUBNET")
    else
        NFS_FLAGS+=(--auto-subnet)
    fi
    run_rvdk mods/nfs-vault "${NFS_FLAGS[@]}"
else
    brak_prog 90 "Stage 5B/7: NFSv4 Vault Server Skipped (ENABLE_NFS_SERVER=false)" 100 "mods/nfs-vault skipped"
    log_step "5B. NFSv4 Vault Server Skipped (ENABLE_NFS_SERVER=false)"
    if [[ "$TARGET_BOARD" == "espressif-esp32p4" || -n "$CLI_STAGE_DIR" ]]; then
        log_skip "NFSv4 vault server skipped on ${TARGET_BOARD} (${TARGET_ARCH}, media=${STORAGE_MEDIA})"
    else
        if systemctl is-active --quiet nfs-server.service 2>/dev/null || systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
            systemctl disable --now nfs-kernel-server 2>/dev/null || systemctl disable --now nfs-server.service 2>/dev/null || true
            log_ok "Disabled nfs-kernel-server for ${NODE_ROLE} isolation"
        fi
        if systemctl is-active --quiet nfs-ganesha.service 2>/dev/null; then
            systemctl disable --now nfs-ganesha.service 2>/dev/null || true
            log_ok "Disabled nfs-ganesha for ${NODE_ROLE} isolation"
        fi
    fi
fi

if [[ "$CLI_WITH_TAILSCALE" == "true" ]]; then
    brak_prog 91 "Stage 5C: Tailscale Mesh VPN (--with-tailscale)" 0 "Launching rvdk mods/tailscale..."
    log_step "5C. RVDK Tailscale Mesh VPN (--with-tailscale)"
    if [[ -n "$CLI_TS_AUTHKEY" ]]; then
        TS_AUTHKEY="$CLI_TS_AUTHKEY" run_rvdk mods/tailscale --hostname "$TARGET_HOSTNAME" ${CLI_TS_FLAGS[@]+"${CLI_TS_FLAGS[@]}"}
    else
        run_rvdk mods/tailscale --hostname "$TARGET_HOSTNAME" ${CLI_TS_FLAGS[@]+"${CLI_TS_FLAGS[@]}"}
    fi
fi

if [[ "$CLI_WITH_DEEPTUNE" == "true" ]]; then
    RESOLVED_TUNE="${CLI_DEEPTUNE_TUNE:-$RVDK_TUNE_PROFILE}"
    _norm_rt="$(brak_normalize_tune "$RESOLVED_TUNE")"
    RESOLVED_TUNE="${_norm_rt:-data}"
    brak_prog 93 "Stage 5D: Silicon & OS Extreme DeepTune (--tune ${RESOLVED_TUNE})" 0 "Launching rvdk deeptune --tune ${RESOLVED_TUNE}..."
    log_step "5D. RVDK Silicon & OS Extreme DeepTune (Role: ${NODE_ROLE} -> --tune ${RESOLVED_TUNE})"
    if [[ "$TARGET_BOARD" == "espressif-esp32p4" ]]; then
        _dt_stage_args=()
        [[ -n "$CLI_STAGE_DIR" ]] && _dt_stage_args=(--stage-dir "$CLI_STAGE_DIR")
        run_rvdk bsp/espressif/esp32p4/deeptune.sh --tune "$RESOLVED_TUNE" ${_dt_stage_args[@]+"${_dt_stage_args[@]}"}
        run_rvdk boards/waveshare/esp32-p4-wifi6/deeptune.sh --tune "$RESOLVED_TUNE" ${_dt_stage_args[@]+"${_dt_stage_args[@]}"}
    else
        run_rvdk deeptune --tune "$RESOLVED_TUNE"
    fi
fi

# ==============================================================================
# 8. STAGE 6: POST-FLIGHT CONVERGENCE SUMMARY
# ==============================================================================
brak_prog 95 "Stage 6/7: Collecting Post-Flight Convergence Summary..." 100 "RVDK pipeline converged"
if [[ "$TARGET_BOARD" == "espressif-esp32p4" || "$STORAGE_MEDIA" == "sd" || -n "$CLI_STAGE_DIR" ]]; then
    if [[ -n "$CLI_STAGE_DIR" ]]; then
        SD_MNT_INFO="staged (${CLI_STAGE_DIR})"
    elif command -v findmnt >/dev/null 2>&1 && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        SD_MNT_INFO="$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT" 2>/dev/null || echo "sdmmc (mounted)")"
    else
        SD_MNT_INFO="n/a (riscv32/sd)"
    fi
    log_step "6. Post-Flight Verification Summary (Pass ${FORGE_PASS})"
    printf "  • Hostname           : %s (Role: %s | Tune: %s | Pass: %s)\n" "$TARGET_HOSTNAME" "$NODE_ROLE" "$RVDK_TUNE_PROFILE" "$FORGE_PASS"
    printf "  • CarrierPigeons Role: %s\n" "$PIGEON_ROLE"
    printf "  • Arch / Storage     : %s / media=%s\n" "$TARGET_ARCH" "$STORAGE_MEDIA"
    printf "  • CPU / Firmware     : 2x ESP32-P4 HP Harts (esp-idf / nommu)\n"
    printf "  • NVMe LBA Block Sz  : n/a (riscv32/sd)\n"
    printf "  • SD Staging / Mount : %s\n" "$SD_MNT_INFO"
    printf "  • LVM Elastic Pool   : n/a (riscv32/sd)\n"
    printf "  • PG Data Directory  : n/a (riscv32/sd)\n"
    printf "  • PG 18 Async I/O    : n/a (riscv32/sd)\n"
    printf "  • Mosquitto MQTT     : n/a (riscv32/sd)\n"
    printf "  • NFSv4 Vault Server : n/a (riscv32/sd)\n\n"
else
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
    NFS_LV_MNT_INFO=""
    if mountpoint -q "$NFS_MOUNT_POINT" 2>/dev/null; then
        NFS_LV_MNT_INFO="$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$NFS_MOUNT_POINT" 2>/dev/null || true)"
    fi
    LVM_POOL_INFO=""
    if command -v vgs >/dev/null 2>&1 && vgs "$VG_NAME" >/dev/null 2>&1; then
        VG_FREE="$(vgs --noheadings -o vg_free "$VG_NAME" 2>/dev/null | xargs || true)"
        VG_TOTAL="$(vgs --noheadings -o vg_size "$VG_NAME" 2>/dev/null | xargs || true)"
        [[ -n "$VG_FREE" && -n "$VG_TOTAL" ]] && LVM_POOL_INFO="${VG_NAME}: ${VG_FREE} free of ${VG_TOTAL} (online lvextend reserve)"
    fi
    HP_TOTAL="$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    HP_FREE="$(awk '/HugePages_Free:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    [[ "$HP_TOTAL" =~ ^[0-9]+$ ]] || HP_TOTAL=0
    [[ "$HP_FREE" =~ ^[0-9]+$ ]] || HP_FREE=0
    HP_USED=$(( HP_TOTAL - HP_FREE ))
    if [[ "$ENABLE_POSTGRES" == "true" ]]; then
        if command -v psql >/dev/null 2>&1; then
            PG_DATA_DIR="$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null | xargs || echo "unknown")"
            PG_IO_METHOD="$(sudo -u postgres psql -tAc "SHOW io_method;" 2>/dev/null | xargs || echo "unknown")"
            PG_SHBUF="$(sudo -u postgres psql -tAc "SHOW shared_buffers;" 2>/dev/null | xargs || echo "unknown")"
        else
            PG_DATA_DIR="unknown (psql unavailable)"
            PG_IO_METHOD="unknown"
            PG_SHBUF="unknown"
        fi
    else
        PG_DATA_DIR="disabled (ENABLE_POSTGRES=false)"
        PG_IO_METHOD="disabled"
        PG_SHBUF="disabled"
    fi
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
    printf "  • Hostname           : %s (Role: %s | Tune: %s | Pass: %s)\n" "$(hostname)" "$NODE_ROLE" "$RVDK_TUNE_PROFILE" "$FORGE_PASS"
    printf "  • CarrierPigeons Role: %s\n" "$PIGEON_ROLE"
    printf "  • Kernel / Arch      : %s (%s)\n" "$(uname -r)" "$(uname -m)"
    printf "  • CPU Governor/Clock : %s\n" "$CPU_CLOCK_INFO"
    printf "  • NVMe LBA Block Sz  : %s bytes\n" "$LBA_SZ"
    printf "  • Hot NVMe Mount     : %s\n" "$NVME_MNT_INFO"
    [[ -n "$NFS_LV_MNT_INFO" ]] && printf "  • Dedicated NFS LV   : %s\n" "$NFS_LV_MNT_INFO"
    [[ -n "$LVM_POOL_INFO" ]]   && printf "  • LVM Elastic Pool   : %s\n" "$LVM_POOL_INFO"
    printf "  • PG Data Directory  : %s\n" "$PG_DATA_DIR"
    printf "  • PG 18 Async I/O    : io_method = %s\n" "$PG_IO_METHOD"
    printf "  • PG Shared Buffers  : %s (HugePages in use: %s / %s)\n" "$PG_SHBUF" "$HP_USED" "$HP_TOTAL"
    printf "  • Mosquitto MQTT     : %s (Port %s)\n" "$MQTT_STATE" "$MQTT_PORT"
    if [[ -n "$TS_SUMMARY" ]]; then
        printf "  • NFSv4 Vault Server : %s (Subnet %s)\n" "$NFS_STATE" "${LAB_SUBNET:-auto}"
        printf "  • Tailscale Mesh VPN : %s\n\n" "$TS_SUMMARY"
    else
        printf "  • NFSv4 Vault Server : %s (Subnet %s)\n\n" "$NFS_STATE" "${LAB_SUBNET:-auto}"
    fi
fi

# ==============================================================================
# 9. STAGE 7: FACTORY DEFAULT USER MIGRATION & PURGE
# ==============================================================================
if [[ -z "$CLI_STAGE_DIR" && "$TARGET_BOARD" != "espressif-esp32p4" && -n "$FACTORY_USER" && "$FACTORY_USER" != "$ADMIN_USER" ]]; then
    if id -u "$FACTORY_USER" >/dev/null 2>&1 || [[ -d "/home/${FACTORY_USER}" ]]; then
        if [[ "$REAL_USER" == "$ADMIN_USER" ]]; then
            brak_prog 98 "Stage 7/7: Purging factory user '${FACTORY_USER}' -> '${ADMIN_USER}'" 50 "utils/purge-user.sh ${FACTORY_USER}"
            log_step "7. Migrating Artifacts & Purging Factory Default User ('${FACTORY_USER}' -> '${ADMIN_USER}')"
            "$RVDK_BIN" utils/purge-user.sh "$FACTORY_USER" \
                --to-user "$ADMIN_USER" \
                --extra-dotdir .brakerrak \
                --mount-point "$MOUNT_POINT" \
                --nfs-mount "$NFS_MOUNT_POINT"
            echo ""
        else
            log_brak "Factory user '${FACTORY_USER}' still exists (active session: '${REAL_USER}'). Log in as '${ADMIN_USER}' and re-run 'sudo brakerrak' to migrate ~/.brakerrak & purge '${FACTORY_USER}'."
        fi
    fi
fi

rm -f "$APT_STAMP_FILE" 2>/dev/null || true
brak_prog 100 "${TARGET_HOSTNAME} (${NODE_ROLE}) Forge Complete!" 100 "All RVDK stages complete"
brak_prog_cleanup
log_ok "${TARGET_HOSTNAME} (${NODE_ROLE}) Forge Complete!"
