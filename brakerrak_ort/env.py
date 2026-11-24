"""Safe user resolution and non-executing key-value node.env parsing."""

from __future__ import annotations

import grp
import json
import os
import pwd
import shlex
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from brakerrak_ort.profiles import get_role_defaults
from brakerrak_ort.types import UserIdentity

SYSTEM_NODE_ENV_PATH = "/etc/brakerrak/node.env"
SYSTEM_KIT_ENV_PATH = "/etc/rvdk/kit.env"


def _group_name_for_gid(gid: int) -> str:
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return str(gid)


def resolve_real_user(env: Mapping[str, str] | None = None) -> UserIdentity:
    """Resolve real operator user, group, and home directory without hardcoded paths."""
    active_env = os.environ if env is None else env

    sudo_user = (active_env.get("SUDO_USER") or "").strip()
    if sudo_user and sudo_user != "root":
        try:
            pw = pwd.getpwnam(sudo_user)
            return UserIdentity(
                username=pw.pw_name,
                groupname=_group_name_for_gid(pw.pw_gid),
                home=pw.pw_dir,
                uid=pw.pw_uid,
                gid=pw.pw_gid,
            )
        except KeyError:
            pass

    try:
        pw = pwd.getpwuid(os.geteuid())
        return UserIdentity(
            username=pw.pw_name,
            groupname=_group_name_for_gid(pw.pw_gid),
            home=pw.pw_dir,
            uid=pw.pw_uid,
            gid=pw.pw_gid,
        )
    except KeyError:
        pass

    expanded = os.path.expanduser("~")
    if expanded and expanded != "~":
        return UserIdentity(
            username=active_env.get("USER") or "root",
            groupname="root",
            home=expanded,
            uid=None,
            gid=None,
        )

    return UserIdentity(
        username="root",
        groupname="root",
        home="/root",
        uid=0,
        gid=0,
    )


def resolve_real_user_home(env: Mapping[str, str] | None = None) -> str:
    """Return the resolved home directory of the invoking operator."""
    return resolve_real_user(env).home


def parse_kv_content(content: str) -> dict[str, str]:
    """Parse shell-style KEY=VALUE text strictly as data (supports quotes & multiline values)."""
    env_map: dict[str, str] = {}
    try:
        lexer = shlex.shlex(content, posix=True)
        lexer.whitespace_split = True
        lexer.commenters = "#"
        for token in lexer:
            if "=" not in token:
                continue
            key, val = token.split("=", 1)
            if key.isidentifier():
                env_map[key] = val
    except ValueError:
        # Fallback line-by-line parse if an input file has an unbalanced quote.
        for raw_line in content.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export ") :].lstrip()
            if "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            if not key.isidentifier():
                continue
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                val = val[1:-1]
            env_map[key] = val
    return env_map


def load_kv_file(path: str | Path) -> dict[str, str]:
    """Load a KEY=VALUE file strictly as data, returning {} if absent or unreadable."""
    file_path = Path(path)
    if not file_path.is_file():
        return {}
    try:
        return parse_kv_content(file_path.read_text(encoding="utf-8"))
    except OSError:
        return {}


def load_node_env(
    config_path: str | None = None,
    *,
    real_home: str | None = None,
    env: Mapping[str, str] | None = None,
    system_node_env: str = SYSTEM_NODE_ENV_PATH,
) -> dict[str, str]:
    """Load node.env following precedence: --config -> BRAKERRAK_NODE_ENV -> /etc -> legacy home."""
    active_env = os.environ if env is None else env
    candidates: list[str] = []

    if config_path:
        candidates.append(config_path)

    env_override = (active_env.get("BRAKERRAK_NODE_ENV") or "").strip()
    if env_override:
        candidates.append(env_override)

    candidates.append(system_node_env)

    resolved_home = real_home if real_home is not None else resolve_real_user_home(active_env)
    candidates.append(os.path.join(resolved_home, ".brakerrak", "node.env"))

    for candidate in candidates:
        if os.path.isfile(candidate):
            return load_kv_file(candidate)
    return {}


def get_raid_arrays_config(
    env_map: Mapping[str, str],
    env: Mapping[str, str] | None = None,
) -> list[dict[str, Any]]:
    """Return configured RAID array definitions when WITH_RAID is enabled."""
    active_env = os.environ if env is None else env
    with_raid = (active_env.get("WITH_RAID") or env_map.get("WITH_RAID") or "false").strip().lower()
    if with_raid != "true":
        return []
    raw_json = active_env.get("RAID_ARRAYS_JSON") or env_map.get("RAID_ARRAYS_JSON")
    if not raw_json:
        return []
    try:
        parsed: Any = json.loads(raw_json)
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []
    return [entry for entry in parsed if isinstance(entry, dict)]


def resolve_feature_flag(
    key: str,
    node_env: Mapping[str, str],
    node_role: str,
    env: Mapping[str, str] | None = None,
) -> bool:
    """Resolve boolean service flag via process env -> node.env -> role defaults."""
    active_env = os.environ if env is None else env
    raw = active_env.get(key)
    if raw is None:
        raw = node_env.get(key)
    if raw is not None and raw.strip() != "":
        return raw.strip().lower() in ("1", "true", "yes", "on")

    defaults = get_role_defaults(node_role)
    if key == "ENABLE_POSTGRES":
        return defaults.enable_postgres
    if key == "ENABLE_MQTT_BROKER":
        return defaults.enable_mqtt_broker
    if key == "ENABLE_NFS_SERVER":
        return defaults.enable_nfs_server
    return False
