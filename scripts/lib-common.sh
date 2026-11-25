#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // BrakerRak Core Runtime, Safe Env I/O & Silicon Resolution Library
# Path: brakerrak/scripts/lib-common.sh
#
# Provides:
#   • Standardized ANSI logging (brak_log_init, log_brak, log_info, log_step,
#     log_ok, log_skip, log_warn, log_fatal)
#   • SSH-forwarded locale hygiene (brak_sanitize_locale)
#   • Strict CLI flag argument validation (brak_require_arg)
#   • Safe caller identity resolution without `eval` (brak_resolve_user)
#   • Root-owned runtime directory management (brak_runtime_dir)
#   • Atomic same-directory file writer (brak_atomic_write)
#   • System-wide node.env path & legacy migration helper (brak_resolve_node_env)
#   • Non-executing key-value .env loader supporting multiline values (brak_load_kv_env)
#   • Safe, expansion-free node.env serializer (brak_write_node_env)
#   • Unified Device-Tree & --target silicon resolver (brak_resolve_silicon)
#   • Canonical role & RVDK tune profile mappers (brak_normalize_role, brak_role_to_rvdk_tune)
# ==============================================================================

if [[ "${_BRAKERRAK_COMMON_SOURCED:-0}" == "1" ]]; then
    if [[ "${BASHPID:-$$}" != "${_BRAK_TRAP_PID:-}" ]]; then
        _BRAK_LEGACY_TMPFILES_PID="${BASHPID:-$$}"
    fi
    return 0
fi
_BRAKERRAK_COMMON_SOURCED="1"

export BRAKERRAK_SYSTEM_ENGINE_DIR="/usr/local/share/brakerrak/engine"
export BRAKERRAK_SYSTEM_ETC_DIR="/etc/brakerrak"
export BRAKERRAK_SYSTEM_NODE_ENV="/etc/brakerrak/node.env"

BRAKERRAK_NODE_ENV_KEYS=(
    NODE_ROLE
    TARGET_HOSTNAME
    ADMIN_USER
    LAB_SUBNET
    RVDK_TUNE_PROFILE
    PIGEON_ROLE
    NVME_DEV
    MOUNT_POINT
    NFS_MOUNT_POINT
    VG_NAME
    LV_NAME
    FS_LABEL
    NFS_LV_NAME
    NFS_FS_LABEL
    WITH_RAID
    RAID_ARRAYS_JSON
    ENABLE_POSTGRES
    ENABLE_MQTT_BROKER
    MQTT_PORT
    ENABLE_NFS_SERVER
    NFS_BACKEND
    SHARE_ORT_SNAPSHOT
)

_BRAK_LOG_TAG="${_BRAK_LOG_TAG:-BRAKERRAK}"

if [[ -z "${_BRAK_TMPFILES+x}" ]]; then
    _BRAK_TMPFILES=()
fi
if [[ -z "${_BRAK_OWNED_TMPFILES+x}" ]]; then
    _BRAK_OWNED_TMPFILES=()
fi
if [[ -z "${_BRAK_EXIT_HOOKS+x}" ]]; then
    _BRAK_EXIT_HOOKS=()
fi
if [[ -z "${_BRAK_EXIT_RAN+x}" ]]; then
    _BRAK_EXIT_RAN="0"
fi
if [[ -z "${_BRAK_ROOT_PID+x}" ]]; then
    _BRAK_ROOT_PID="${BASHPID:-$$}"
fi
if [[ -z "${_BRAK_TRAP_PID+x}" ]]; then
    _BRAK_TRAP_PID="${BASHPID:-$$}"
fi
if [[ -z "${_BRAK_LEGACY_TMPFILES_PID+x}" ]]; then
    _BRAK_LEGACY_TMPFILES_PID="${BASHPID:-$$}"
fi

brak_log_init() {
    _BRAK_LOG_TAG="${1:-BRAKERRAK}"
}

log_brak()  { printf "\033[1;35m[%s]\033[0m %s\n" "${_BRAK_LOG_TAG}" "$1"; }
log_info()  { printf "\033[1;35m[%s]\033[0m %s\n" "${_BRAK_LOG_TAG}" "$1"; }
log_step()  { printf "\n\033[1;36m=== [%s] %s ===\033[0m\n" "$(date +%H:%M:%S)" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1" >&2; }
log_fatal() { printf "\033[1;31m[%s:FATAL]\033[0m %s\n" "${_BRAK_LOG_TAG}" "$1" >&2; exit 1; }

# Sanitize SSH-forwarded LC_* (e.g. macOS SendEnv) before Day-0 locale-gen
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

# Fail fast when a flag expecting a value is missing its argument or receives another flag.
# Usage: brak_require_arg "$1" "${2:-}"
brak_require_arg() {
    local flag="${1:-}"
    local val="${2:-}"
    if [[ -z "$val" || "$val" == -* ]]; then
        log_fatal "Option '${flag}' requires an argument."
    fi
    return 0
}

# Safely resolve invoking user, primary group, and home directory strictly via
# getent passwd / dscl / standard home fallbacks (ZERO `eval`).
# Exports: REAL_USER, REAL_GRP, REAL_HOME
brak_resolve_user() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        REAL_USER="$(id -un 2>/dev/null || echo "${USER:-root}")"
    else
        REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
    fi
    if [[ ! "$REAL_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        REAL_USER="root"
    fi
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
    return 0
}

# Create and return a private 0700 runtime directory.
# Uses root-owned /run/brakerrak on Linux as root; falls back to mktemp -d (0700)
# on macOS or unprivileged invocations.
brak_runtime_dir() {
    local dir=""
    if [[ -n "${BRAKERRAK_RUNTIME_DIR:-}" && -d "${BRAKERRAK_RUNTIME_DIR}" && ! -L "${BRAKERRAK_RUNTIME_DIR}" ]]; then
        printf '%s\n' "${BRAKERRAK_RUNTIME_DIR}"
        return 0
    fi

    if [[ "$(uname -s)" == "Linux" && "${EUID:-$(id -u)}" -eq 0 && -d /run ]]; then
        dir="/run/brakerrak"
        if [[ -L "$dir" ]]; then
            log_fatal "Refusing symlink runtime directory: ${dir}"
        fi
        install -d -m 0700 -o 0 -g 0 "$dir"
        printf '%s\n' "$dir"
        return 0
    fi

    dir="$(mktemp -d "${TMPDIR:-/tmp}/brakerrak.XXXXXX")"
    chmod 0700 "$dir"
    printf '%s\n' "$dir"
    return 0
}

_brak_tmp_manifest_path() {
    local owner_pid="${1:-${BASHPID:-$$}}"
    local base_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    base_dir="${base_dir%/}"
    local uid_val="${UID:-$(id -u 2>/dev/null || echo 0)}"
    printf '%s/.brak-tmp-%s-%s\n' "$base_dir" "$uid_val" "$owner_pid"
}

_brak_cleanup_tmpfiles() {
    local cur_pid="${BASHPID:-$$}"
    local _tf

    # Clean entries owned by this specific shell PID (safe across pipeline subshells)
    local -a remaining_owned=()
    for _tf in ${_BRAK_OWNED_TMPFILES[@]+"${_BRAK_OWNED_TMPFILES[@]}"}; do
        [[ -n "$_tf" ]] || continue
        if [[ "$_tf" == "${cur_pid}:"* ]]; then
            local owned_path="${_tf#*:}"
            [[ -n "$owned_path" ]] && rm -rf -- "$owned_path" 2>/dev/null || true
        else
            remaining_owned+=("$_tf")
        fi
    done
    _BRAK_OWNED_TMPFILES=(${remaining_owned[@]+"${remaining_owned[@]}"})

    # Clean legacy _BRAK_TMPFILES only in the shell PID that sourced lib-common.sh or called brak_prog_init
    if [[ "$cur_pid" == "${_BRAK_LEGACY_TMPFILES_PID:-}" ]]; then
        for _tf in ${_BRAK_TMPFILES[@]+"${_BRAK_TMPFILES[@]}"}; do
            [[ -n "$_tf" ]] && rm -rf -- "$_tf" 2>/dev/null || true
        done
        _BRAK_TMPFILES=()
    fi

    # Only clean the subshell manifest belonging to this exiting shell PID
    local manifest=""
    manifest="$(_brak_tmp_manifest_path "$cur_pid")"
    if [[ -n "$manifest" && -f "$manifest" && ! -L "$manifest" && -O "$manifest" ]]; then
        while IFS= read -r _tf || [[ -n "$_tf" ]]; do
            [[ -n "$_tf" ]] && rm -rf -- "$_tf" 2>/dev/null || true
        done < "$manifest"
        rm -f -- "$manifest" 2>/dev/null || true
    fi
}

_brak_append_exit_hook() {
    local candidate="${1:-}"
    [[ -n "$candidate" ]] || return 0
    local existing
    for existing in ${_BRAK_EXIT_HOOKS[@]+"${_BRAK_EXIT_HOOKS[@]}"}; do
        if [[ "$existing" == "$candidate" ]]; then
            return 0
        fi
    done
    _BRAK_EXIT_HOOKS+=("$candidate")
}

_brak_run_exit_hooks() {
    local rc=$?
    if [[ "${_BRAK_EXIT_RAN:-0}" == "1" ]]; then
        return "$rc"
    fi
    _BRAK_EXIT_RAN="1"

    local hook
    for hook in ${_BRAK_EXIT_HOOKS[@]+"${_BRAK_EXIT_HOOKS[@]}"}; do
        [[ -n "$hook" ]] || continue
        if declare -F "$hook" >/dev/null 2>&1; then
            "$hook" "$rc" || true
        elif [[ "$hook" == __BRAK_RAW_TRAP__:* ]]; then
            local raw_cmd="${hook#__BRAK_RAW_TRAP__:}"
            eval "$raw_cmd" || true
        fi
    done
    return "$rc"
}

_brak_on_signal() {
    local sig="$1"
    _brak_run_exit_hooks
    trap - "$sig" EXIT
    kill -"$sig" "${BASHPID:-$$}"
}

# Register a cleanup callback to run in order on EXIT/INT/TERM without
# double-running or clobbering prior EXIT traps.
# Usage: brak_register_exit_hook <function_name>
brak_register_exit_hook() {
    local fn="${1:-}"
    [[ -n "$fn" ]] || return 1

    local cur_pid="${BASHPID:-$$}"
    if [[ "${_BRAK_TRAP_PID:-}" != "$cur_pid" ]]; then
        _BRAK_EXIT_RAN="0"
        _BRAK_TRAP_PID="$cur_pid"
        # Do not inherit parent shell callbacks into forked subshells/pipelines
        _BRAK_EXIT_HOOKS=()
    fi

    local cur_exit_trap=""
    cur_exit_trap="$(trap -p EXIT 2>/dev/null || true)"
    if [[ -n "$cur_exit_trap" && "$cur_exit_trap" != *"_brak_run_exit_hooks"* ]]; then
        local prior_cmd="$cur_exit_trap"
        prior_cmd="${prior_cmd#trap -- \'}"
        prior_cmd="${prior_cmd%\' EXIT}"
        prior_cmd="${prior_cmd//\'\\\'\'/\'}"
        if [[ -n "$prior_cmd" ]]; then
            if declare -F "$prior_cmd" >/dev/null 2>&1; then
                _brak_append_exit_hook "$prior_cmd"
            else
                _brak_append_exit_hook "__BRAK_RAW_TRAP__:${prior_cmd}"
            fi
        fi
    fi

    _brak_append_exit_hook "$fn"

    trap '_brak_run_exit_hooks' EXIT
    trap '_brak_on_signal INT' INT
    trap '_brak_on_signal TERM' TERM
    return 0
}

# Create a private temp file (or directory with -d) registered for cleanup on EXIT/INT/TERM.
# Supports both subshell capture `f="$(brak_mktemp)"` and direct `-v var` assignment.
# Usage: brak_mktemp [-d] [-v var_name] [template]
brak_mktemp() {
    local is_dir="false"
    local out_var=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d) is_dir="true"; shift ;;
            -v)
                brak_require_arg "$1" "${2:-}"
                out_var="$2"
                shift 2
                ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    local template="${1:-${TMPDIR:-/tmp}/brakerrak.XXXXXX}"
    local created=""
    if [[ "$is_dir" == "true" ]]; then
        created="$(mktemp -d "$template")"
        chmod 0700 "$created"
    else
        created="$(mktemp "$template")"
        chmod 0600 "$created"
    fi

    if (( ${BASH_SUBSHELL:-0} > 0 )); then
        local owner_pid="${_BRAK_TRAP_PID:-${BASHPID:-$$}}"
        local manifest=""
        manifest="$(_brak_tmp_manifest_path "$owner_pid")"
        (
            set -o noclobber
            : > "$manifest"
        ) 2>/dev/null || true
        if [[ -f "$manifest" && ! -L "$manifest" && -O "$manifest" ]]; then
            chmod 0600 "$manifest" 2>/dev/null || true
            printf '%s\n' "$created" >> "$manifest"
        fi
    else
        _BRAK_OWNED_TMPFILES+=("${BASHPID:-$$}:${created}")
        brak_register_exit_hook _brak_cleanup_tmpfiles
    fi

    if [[ -n "$out_var" ]]; then
        printf -v "$out_var" '%s' "$created"
    else
        printf '%s\n' "$created"
    fi
}

# Atomically write stdin to <target_path> via same-directory temp file + mv -f.
# Usage: brak_atomic_write <target_path> [octal_mode=0644] [owner:group]
brak_atomic_write() {
    local target_path="$1"
    local file_mode="${2:-0644}"
    local owner_group="${3:-}"

    local dir base tmp_file
    dir="$(dirname "$target_path")"
    base="$(basename "$target_path")"
    mkdir -p "$dir"

    brak_register_exit_hook _brak_cleanup_tmpfiles

    tmp_file="$(mktemp "${dir}/.${base}.brak.XXXXXX")"
    _BRAK_OWNED_TMPFILES+=("${BASHPID:-$$}:${tmp_file}")

    cat > "$tmp_file"
    chmod "$file_mode" "$tmp_file"
    if [[ -n "$owner_group" && "${EUID:-$(id -u)}" -eq 0 ]]; then
        chown "$owner_group" "$tmp_file"
    fi
    mv -f "$tmp_file" "$target_path"
}

# Resolve per-node configuration path (/etc/brakerrak/node.env), respecting
# BRAKERRAK_NODE_ENV override and transparently migrating legacy ~/.brakerrak/node.env
# when --migrate is passed as root.
# Exports: NODE_ENV
brak_resolve_node_env() {
    local do_migrate="false"
    if [[ "${1:-}" == "--migrate" ]]; then
        do_migrate="true"
    fi

    if [[ -z "${REAL_HOME:-}" || -z "${REAL_GRP:-}" ]]; then
        brak_resolve_user
    fi

    if [[ -n "${BRAKERRAK_NODE_ENV:-}" ]]; then
        NODE_ENV="$BRAKERRAK_NODE_ENV"
        export NODE_ENV
        return 0
    fi

    NODE_ENV="$BRAKERRAK_SYSTEM_NODE_ENV"
    local legacy_env="${REAL_HOME}/.brakerrak/node.env"

    if [[ ! -f "$NODE_ENV" && -f "$legacy_env" ]]; then
        if [[ "$do_migrate" == "true" && "${EUID:-$(id -u)}" -eq 0 ]]; then
            install -d -m 0755 -o 0 -g 0 "$BRAKERRAK_SYSTEM_ETC_DIR"
            brak_atomic_write "$NODE_ENV" 0640 "0:${REAL_GRP}" < "$legacy_env"
            rm -f "$legacy_env" 2>/dev/null || true
            log_ok "Migrated legacy node configuration ${legacy_env} -> ${NODE_ENV}"
        elif [[ ! -r "$NODE_ENV" && -r "$legacy_env" ]]; then
            NODE_ENV="$legacy_env"
        fi
    fi

    export NODE_ENV
    return 0
}

# Internal helper: check whether a shell variable named $1 is currently non-empty
# without using `eval`.
_brak_var_is_nonempty() {
    local _name="$1"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        local _decl=""
        _decl="$(typeset -p "$_name" 2>/dev/null || true)"
        [[ -n "$_decl" && "$_decl" != *="''" && "$_decl" != *='""' && "$_decl" != *"=${_name}" ]]
        return $?
    fi
    [[ -n "${!_name:-}" ]]
}

# Internal helper: unescape sentinel-masked double-quoted string content into _BRAK_UNESC_OUT.
_brak_unescape_dq_masked() {
    local s="$1"
    local _s_bs=$'\x01'
    local _s_dq=$'\x02'
    s="${s//${_s_dq}/\"}"
    s="${s//\\\$/\$}"
    s="${s//\\\`/\`}"
    s="${s//${_s_bs}/\\}"
    _BRAK_UNESC_OUT="$s"
}

# Safe, non-executing key-value .env parser supporting unquoted, single-quoted,
# double-quoted, and multiline single/double-quoted values (e.g. RAID_ARRAYS_JSON).
# NEVER executes shell commands or expands variables. Preserves explicit empty
# assignments such as LAB_SUBNET="".
#
# Usage: brak_load_kv_env <env_file> [--preserve-existing] [ALLOWED_KEY ...]
#   When no ALLOWED_KEY arguments are provided, defaults to BRAKERRAK_NODE_ENV_KEYS.
brak_load_kv_env() {
    local env_file="${1:-}"
    shift || return 1
    [[ -n "$env_file" && -r "$env_file" ]] || return 1

    local preserve="false"
    if [[ "${1:-}" == "--preserve-existing" ]]; then
        preserve="true"
        shift
    fi

    local allowed_list=""
    if [[ $# -gt 0 ]]; then
        allowed_list=" $* "
    else
        allowed_list=" ${BRAKERRAK_NODE_ENV_KEYS[*]} "
    fi

    local _s_bs=$'\x01'
    local _s_dq=$'\x02'
    local _BRAK_UNESC_OUT=""
    local in_quote=""
    local ml_key=""
    local ml_val=""
    local ml_allowed="false"

    local raw_line line key val rest masked closing_part
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%$'\r'}"

        if [[ "$in_quote" == "'" ]]; then
            if [[ "$line" == *"'"* ]]; then
                closing_part="${line%%\'*}"
                ml_val+=$'\n'"${closing_part}"
                if [[ "$ml_allowed" == "true" ]]; then
                    if [[ "$preserve" != "true" ]] || ! _brak_var_is_nonempty "$ml_key"; then
                        printf -v "$ml_key" '%s' "$ml_val"
                    fi
                fi
                in_quote=""
                ml_key=""
                ml_val=""
                ml_allowed="false"
            else
                ml_val+=$'\n'"${line}"
            fi
            continue
        fi

        if [[ "$in_quote" == '"' ]]; then
            masked="${line//\\\\/${_s_bs}}"
            masked="${masked//\\\"/${_s_dq}}"
            if [[ "$masked" == *'"'* ]]; then
                closing_part="${masked%%\"*}"
                _brak_unescape_dq_masked "$closing_part"
                ml_val+=$'\n'"${_BRAK_UNESC_OUT}"
                if [[ "$ml_allowed" == "true" ]]; then
                    if [[ "$preserve" != "true" ]] || ! _brak_var_is_nonempty "$ml_key"; then
                        printf -v "$ml_key" '%s' "$ml_val"
                    fi
                fi
                in_quote=""
                ml_key=""
                ml_val=""
                ml_allowed="false"
            else
                _brak_unescape_dq_masked "$masked"
                ml_val+=$'\n'"${_BRAK_UNESC_OUT}"
            fi
            continue
        fi

        # Trim leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export}"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"
        val="${line#*=}"
        # Trim trailing whitespace on key
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        local is_allowed="false"
        if [[ "$allowed_list" == *" ${key} "* ]]; then
            is_allowed="true"
        fi

        # Trim leading whitespace on value
        val="${val#"${val%%[![:space:]]*}"}"

        if [[ "${val:0:1}" == "'" ]]; then
            rest="${val:1}"
            if [[ "$rest" == *"'"* ]]; then
                val="${rest%%\'*}"
                if [[ "$is_allowed" == "true" ]]; then
                    if [[ "$preserve" != "true" ]] || ! _brak_var_is_nonempty "$key"; then
                        printf -v "$key" '%s' "$val"
                    fi
                fi
            else
                in_quote="'"
                ml_key="$key"
                ml_val="$rest"
                ml_allowed="$is_allowed"
            fi
            continue
        fi

        if [[ "${val:0:1}" == '"' ]]; then
            rest="${val:1}"
            masked="${rest//\\\\/${_s_bs}}"
            masked="${masked//\\\"/${_s_dq}}"
            if [[ "$masked" == *'"'* ]]; then
                closing_part="${masked%%\"*}"
                _brak_unescape_dq_masked "$closing_part"
                val="$_BRAK_UNESC_OUT"
                if [[ "$is_allowed" == "true" ]]; then
                    if [[ "$preserve" != "true" ]] || ! _brak_var_is_nonempty "$key"; then
                        printf -v "$key" '%s' "$val"
                    fi
                fi
            else
                in_quote='"'
                ml_key="$key"
                _brak_unescape_dq_masked "$masked"
                ml_val="$_BRAK_UNESC_OUT"
                ml_allowed="$is_allowed"
            fi
            continue
        fi

        # Unquoted value: strip trailing whitespace and inline comment preceded by whitespace
        val="${val%%[[:space:]]#*}"
        val="${val%"${val##*[![:space:]]}"}"
        if [[ "$is_allowed" == "true" ]]; then
            if [[ "$preserve" != "true" ]] || ! _brak_var_is_nonempty "$key"; then
                printf -v "$key" '%s' "$val"
            fi
        fi
    done < "$env_file"

    if [[ -n "$in_quote" ]]; then
        log_warn "Unterminated quoted value for '${ml_key}' in ${env_file}; ignored."
    fi
    return 0
}

# Format a single-line KEY="ESCAPED_VALUE" line without shell expansion hazards.
_brak_emit_dq_kv() {
    local k="$1"
    local v="$2"
    local nl=$'\n' cr=$'\r'
    v="${v//"$nl"/ }"
    v="${v//"$cr"/}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '%s="%s"\n' "$k" "$v"
}

# Format a potentially multiline value safely (single-quoted if no `'`, else escaped double-quoted).
_brak_emit_json_kv() {
    local k="$1"
    local v="$2"
    local cr=$'\r'
    v="${v//"$cr"/}"
    if [[ "$v" != *"'"* ]]; then
        printf "%s='%s'\n" "$k" "$v"
    else
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        v="${v//\$/\\\$}"
        v="${v//\`/\\\`}"
        printf '%s="%s"\n' "$k" "$v"
    fi
}

# Safely serialize BrakerRak node.env atomically without unquoted <<EOF expansion bugs.
# Usage: brak_write_node_env [target_path] [owner:group] [octal_mode]
brak_write_node_env() {
    local target_path="${1:-${NODE_ENV:-$BRAKERRAK_SYSTEM_NODE_ENV}}"
    local owner_group="${2:-}"
    local file_mode="${3:-0640}"

    if [[ -z "$owner_group" && "${EUID:-$(id -u)}" -eq 0 ]]; then
        if [[ -z "${REAL_GRP:-}" ]]; then
            brak_resolve_user
        fi
        owner_group="0:${REAL_GRP:-0}"
    fi

    local parent_dir
    parent_dir="$(dirname "$target_path")"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        install -d -m 0755 -o 0 -g 0 "$parent_dir"
    else
        mkdir -p "$parent_dir"
    fi

    {
        printf '# ==============================================================================\n'
        printf '# DREW-V Labs // BrakerRak Node Configuration (%s)\n' "$target_path"
        printf '# Role Personas: databroker | databench | babbagebox | babbagebench | visionbox | visionbench | devbench\n'
        printf '# ==============================================================================\n'
        _brak_emit_dq_kv "NODE_ROLE" "${NODE_ROLE:-databroker}"
        _brak_emit_dq_kv "TARGET_HOSTNAME" "${TARGET_HOSTNAME:-}"
        _brak_emit_dq_kv "ADMIN_USER" "${ADMIN_USER:-}"
        _brak_emit_dq_kv "LAB_SUBNET" "${LAB_SUBNET-}"
        _brak_emit_dq_kv "RVDK_TUNE_PROFILE" "${RVDK_TUNE_PROFILE:-data}"
        _brak_emit_dq_kv "PIGEON_ROLE" "${PIGEON_ROLE:-pigeoneer}"
        printf '\n# Hot NVMe Storage (Dual-LVM carves NFS_MOUNT_POINT when ENABLE_NFS_SERVER=true & WITH_RAID=false)\n'
        _brak_emit_dq_kv "NVME_DEV" "${NVME_DEV:-/dev/nvme0n1}"
        _brak_emit_dq_kv "MOUNT_POINT" "${MOUNT_POINT:-/mnt/nvme_pgdata}"
        _brak_emit_dq_kv "NFS_MOUNT_POINT" "${NFS_MOUNT_POINT:-/mnt/nfs_vault}"
        _brak_emit_dq_kv "VG_NAME" "${VG_NAME:-vg_braker}"
        _brak_emit_dq_kv "LV_NAME" "${LV_NAME:-lv_pgdata}"
        _brak_emit_dq_kv "FS_LABEL" "${FS_LABEL:-PGDATA_NVME}"
        _brak_emit_dq_kv "NFS_LV_NAME" "${NFS_LV_NAME:-lv_nfsvault}"
        _brak_emit_dq_kv "NFS_FS_LABEL" "${NFS_FS_LABEL:-NFS_VAULT}"
        printf '\n# Optional USB/SATA Btrfs RAID 10 Arrays (Default: false / empty array)\n'
        _brak_emit_dq_kv "WITH_RAID" "${WITH_RAID:-false}"
        _brak_emit_json_kv "RAID_ARRAYS_JSON" "${RAID_ARRAYS_JSON:-[]}"
        printf '\n# Role Services (Toggle via role flip or explicit overrides)\n'
        _brak_emit_dq_kv "ENABLE_POSTGRES" "${ENABLE_POSTGRES:-true}"
        _brak_emit_dq_kv "ENABLE_MQTT_BROKER" "${ENABLE_MQTT_BROKER:-false}"
        _brak_emit_dq_kv "MQTT_PORT" "${MQTT_PORT:-1883}"
        _brak_emit_dq_kv "ENABLE_NFS_SERVER" "${ENABLE_NFS_SERVER:-false}"
        printf '# NFSv4 Server Backend: ganesha (default) | kernel (nfs-kernel-server override) | auto\n'
        _brak_emit_dq_kv "NFS_BACKEND" "${NFS_BACKEND:-ganesha}"
        printf '\n# Opt-In Community RISC-V Telemetry Commons\n'
        _brak_emit_dq_kv "SHARE_ORT_SNAPSHOT" "${SHARE_ORT_SNAPSHOT:-false}"
    } | brak_atomic_write "$target_path" "$file_mode" "$owner_group"
}

# Normalize role alias -> canonical role name in `roles/<role>.env`
brak_normalize_role() {
    local raw
    raw="$(tr '[:upper:]' '[:lower:]' <<< "${1:-databroker}")"
    case "$raw" in
        prod|broker|databroker|brakerbox|brakbox|brx)                 printf 'databroker\n' ;;
        bench|databench|brakerbench|brakbnch|brh)                     printf 'databench\n' ;;
        babbagebox|babbox|bab|gpuprod)                                printf 'babbagebox\n' ;;
        babbagebench|babbnch|bah|gpubench)                            printf 'babbagebench\n' ;;
        visionbox|visbox|vx|npuprod)                                  printf 'visionbox\n' ;;
        visionbench|visbnch|vh|npubench|visionferret|vferret|mlbench) printf 'visionbench\n' ;;
        devbench|devbnch|dev)                                         printf 'devbench\n' ;;
        *)                                                            printf '\n' ;;
    esac
}

# Map BrakerRak NODE_ROLE -> agnostic RVDK `--tune` target (`data` | `ai`)
brak_role_to_rvdk_tune() {
    local canon
    canon="$(brak_normalize_role "${1:-databroker}")"
    case "$canon" in
        babbagebox|babbagebench|visionbox|visionbench|devbench) printf 'ai\n' ;;
        *)                                                      printf 'data\n' ;;
    esac
}

# Unify Device-Tree (/proc/device-tree/model), /etc/rvdk/kit.env, and --target
# silicon resolution using vendor-qualified patterns (no bare K3/K1/M1 globs).
#
# Usage: brak_resolve_silicon [requested_target] [dt_model_override]
# Exports: TARGET_BOARD, TARGET_TAG, DT_MODEL, FACTORY_USER
# Returns: 0 on successful resolution, 1 if unrecognized.
brak_resolve_silicon() {
    local requested=""
    if [[ $# -ge 1 ]]; then
        requested="$1"
    else
        requested="${TARGET_BOARD:-}"
    fi
    local dt_override="${2:-}"
    local dt_model="Unknown"
    local board=""
    local tag=""
    local factory_user=""

    if [[ -n "$dt_override" ]]; then
        dt_model="$dt_override"
    fi

    if [[ -z "$requested" && -z "$dt_override" && -r /etc/rvdk/kit.env ]]; then
        local RVDK_SOC_SLUG="" RVDK_DT_MODEL="" RVDK_BOARD_TAG="" RVDK_FACTORY_USER=""
        brak_load_kv_env /etc/rvdk/kit.env RVDK_SOC_SLUG RVDK_DT_MODEL RVDK_BOARD_TAG RVDK_FACTORY_USER || true
        if [[ -n "$RVDK_SOC_SLUG" ]]; then
            board="$RVDK_SOC_SLUG"
            dt_model="${RVDK_DT_MODEL:-Unknown}"
            tag="${RVDK_BOARD_TAG:-}"
            factory_user="${RVDK_FACTORY_USER:-}"
        fi
    fi

    if [[ "$dt_model" == "Unknown" && -r /proc/device-tree/model ]]; then
        dt_model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    fi

    if [[ -n "$requested" ]]; then
        board="$requested"
    fi

    if [[ -z "$board" ]]; then
        local dt_lc
        dt_lc="$(tr '[:upper:]' '[:lower:]' <<< "$dt_model")"
        case "$dt_lc" in
            *"premier p550"*)
                board="eswin-eic7700x"; tag="p550" ;;
            *"megrez"*)
                board="eswin-eic7700x"; tag="megrez" ;;
            *"starpro64"*)
                board="eswin-eic7700x"; tag="starpro64" ;;
            *"eic7700"*)
                board="eswin-eic7700x"; tag="p550" ;;
            *"unmatched"*|*"fu740"*)
                board="sifive-fu740"; tag="unmatched" ;;
            *"visionfive 2 lite"*|*"vf2 lite"*|*"jh7110s"*|*"jh-7110s"*)
                board="starfive-jh7110"; tag="vf2lite"; factory_user="user" ;;
            *"visionfive 2"*|*"vf2"*)
                board="starfive-jh7110"; tag="vf2"; factory_user="user" ;;
            *"milk-v mars"*|*"milkv-mars"*|*"milkv mars"*|*"starfive"*"mars"*)
                board="starfive-jh7110"; tag="mars"; factory_user="user" ;;
            *"star64"*)
                board="starfive-jh7110"; tag="star64"; factory_user="user" ;;
            *"orangepi-rv2"*|*"orangepi rv2"*|*"orange pi rv2"*)
                board="spacemit-k1"; tag="rv2"; factory_user="orangepi" ;;
            *"orangepi-r2s"*|*"orangepi r2s"*|*"orange pi r2s"*)
                board="spacemit-k1"; tag="r2s"; factory_user="orangepi" ;;
            *"orangepi-rv"*|*"orangepi rv"*|*"orange pi rv"*)
                board="starfive-jh7110"; tag="opirv"; factory_user="user" ;;
            *"jh7110"*|*"jh-7110"*)
                board="starfive-jh7110"; tag="vf2"; factory_user="user" ;;
            *"aibox-k3"*|*"firefly-k3"*|*"firefly k3"*|*"firefly"*k3*)
                board="spacemit-k3"; tag="aiboxk3" ;;
            *"jupiter 2"*|*"jupiter2"*|*"spacemit k3"*|*"spacemit-k3"*|*"spacemit"*k3*)
                board="spacemit-k3"; tag="jptr2" ;;
            *"bpi-f3"*|*"banana pi f3"*|*"bananapi-f3"*)
                board="spacemit-k1"; tag="bpif3" ;;
            *"bpi-cm6"*|*"banana pi cm6"*|*"bananapi-cm6"*)
                board="spacemit-k1"; tag="bpicm6" ;;
            *"milk-v jupiter"*|*"milkv-jupiter"*|*"milkv jupiter"*|*"jupiter"*|*"spacemit k1"*|*"spacemit-k1"*|*"spacemit m1"*|*"spacemit-m1"*|*"spacemit x60"*|*"spacemit"*|*"ky x1"*|*"ky-x1"*|*"muse pi"*|*"muse book"*)
                board="spacemit-k1"; tag="jptr1" ;;
            *"milk-v titan"*|*"milkv-titan"*|*"milkv titan"*|*"ultrarisc"*"dp1000"*|*"ultrarisc"*|*"dp1000"*)
                board="ultrarisc-dp1000"; tag="titan" ;;
            *"tenstorrent"*"atlantis"*|*"atlantis"*|*"ascalon"*)
                board="tenstorrent-atlantis"; tag="atlantis" ;;
            *)
                TARGET_BOARD=""
                TARGET_TAG=""
                DT_MODEL="$dt_model"
                FACTORY_USER=""
                export TARGET_BOARD TARGET_TAG DT_MODEL FACTORY_USER
                return 1
                ;;
        esac
    else
        local board_lc
        board_lc="$(tr '[:upper:]' '[:lower:]' <<< "$board")"
        case "$board_lc" in
            eswin-eic7700x|eswin/eic7700x|sifive-p550|sifive/p550|p550|premier-p550)
                board="eswin-eic7700x"; [[ -z "$tag" ]] && tag="p550" ;;
            milkv-megrez|milkv/megrez|megrez)
                board="eswin-eic7700x"; [[ -z "$tag" ]] && tag="megrez" ;;
            pine64-starpro64|pine64/starpro64|starpro64)
                board="eswin-eic7700x"; [[ -z "$tag" ]] && tag="starpro64" ;;
            sifive-fu740|sifive/fu740|sifive-unmatched|sifive/unmatched|unmatched|fu740)
                board="sifive-fu740"; [[ -z "$tag" ]] && tag="unmatched" ;;
            starfive-vf2-lite|starfive/vf2-lite|vf2-lite|vf2lite)
                board="starfive-jh7110"; [[ -z "$tag" ]] && tag="vf2lite" ;;
            milkv-mars|milkv/mars|mars)
                board="starfive-jh7110"; [[ -z "$tag" ]] && tag="mars" ;;
            pine64-star64|pine64/star64|star64)
                board="starfive-jh7110"; [[ -z "$tag" ]] && tag="star64" ;;
            orangepi-rv|orangepi/rv|opirv)
                board="starfive-jh7110"; [[ -z "$tag" ]] && tag="opirv" ;;
            starfive-jh7110|starfive/jh7110|starfive-vf2|starfive/vf2|vf2|visionfive2)
                board="starfive-jh7110"; [[ -z "$tag" ]] && tag="vf2" ;;
            orangepi-rv2|orangepi/rv2|rv2)
                board="spacemit-k1"; [[ -z "$tag" ]] && tag="rv2" ;;
            orangepi-r2s|orangepi/r2s|r2s)
                board="spacemit-k1"; [[ -z "$tag" ]] && tag="r2s" ;;
            bananapi-f3|bananapi/f3|bpi-f3|bpif3)
                board="spacemit-k1"; [[ -z "$tag" ]] && tag="bpif3" ;;
            bananapi-cm6|bananapi/cm6|bpi-cm6|bpicm6)
                board="spacemit-k1"; [[ -z "$tag" ]] && tag="bpicm6" ;;
            spacemit-k1|spacemit/k1|milkv-jupiter|milkv/jupiter|jupiter|jptr1|muse-pi|musepi)
                board="spacemit-k1"; [[ -z "$tag" ]] && tag="jptr1" ;;
            firefly-aibox-k3|firefly/aibox-k3|aibox-k3|aiboxk3)
                board="spacemit-k3"; [[ -z "$tag" ]] && tag="aiboxk3" ;;
            spacemit-k3|spacemit/k3|milkv-jupiter2|milkv/jupiter2|jupiter2|jptr2)
                board="spacemit-k3"; [[ -z "$tag" ]] && tag="jptr2" ;;
            ultrarisc-dp1000|ultrarisc/dp1000|milkv-titan|milkv/titan|titan|dp1000)
                board="ultrarisc-dp1000"; [[ -z "$tag" ]] && tag="titan" ;;
            tenstorrent-atlantis|tenstorrent/atlantis|atlantis|ascalon)
                board="tenstorrent-atlantis"; [[ -z "$tag" ]] && tag="atlantis" ;;
            generic-riscv64|generic|riscv64)
                board="generic-riscv64"; [[ -z "$tag" ]] && tag="node" ;;
            *)
                if [[ ! "$board_lc" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
                    TARGET_BOARD=""
                    TARGET_TAG=""
                    DT_MODEL="$dt_model"
                    FACTORY_USER=""
                    export TARGET_BOARD TARGET_TAG DT_MODEL FACTORY_USER
                    return 1
                fi
                board="$board_lc"
                [[ -z "$tag" ]] && tag="node"
                ;;
        esac
    fi

    if [[ -z "$factory_user" ]]; then
        case "$board" in
            starfive-jh7110) factory_user="user" ;;
        esac
    fi

    TARGET_BOARD="$board"
    TARGET_TAG="${tag:-node}"
    DT_MODEL="$dt_model"
    FACTORY_USER="$factory_user"
    export TARGET_BOARD TARGET_TAG DT_MODEL FACTORY_USER
    return 0
}

brak_register_exit_hook _brak_cleanup_tmpfiles
