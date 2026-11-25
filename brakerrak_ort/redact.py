"""Canonical SHA-256 provenance signing and strict .public.json redaction."""

from __future__ import annotations

import copy
import hashlib
import json
import re
from collections.abc import Iterable, Mapping
from typing import Any

SIGNATURE_KEYS: frozenset[str] = frozenset({"provenance_signature", "sha256_provenance_digest"})

_UUID_TOKEN_RE = re.compile(r"\b(PARTUUID|UUID)=[^\s\"']+", re.IGNORECASE)
_BARE_UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
_MAC_RE = re.compile(
    r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b|\b(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}\b"
)
_TSKEY_RE = re.compile(r"tskey-[^\s\"',;]+", re.IGNORECASE)
_SERIAL_KV_RE = re.compile(
    r"\b((?:androidboot\.)?serial(?:_?no|_?number|num)?|SerialNumber)(\s*[:=]\s*|\s+)[^\s,;\"']+",
    re.IGNORECASE,
)
_USER_KV_RE = re.compile(r"\b(sudo_user|username|user|owner)=([^\s,;\"']+)", re.IGNORECASE)
_HOME_PATH_RE = re.compile(r"(/(?:home|Users))/([A-Za-z0-9._-]+)")
_IPV4_CIDR_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])"
    r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"
    r"(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}"
    r"(?:/(?:3[0-2]|[12]?\d))?"
    r"(?![0-9.]|-[A-Za-z])"
)
_IPV4_VERSION_CONTEXT_RE = re.compile(
    r"\b(?:linux|kernel|version|ver|gcc|glibc|systemd|u-boot|opensbi)\s*(?:[:=]\s*|\s+)$",
    re.IGNORECASE,
)
_IPV6_CIDR_RE = re.compile(
    r"(?<![0-9a-fA-F:.])"
    r"(?:"
    r"(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}"
    r"|(?:[0-9a-fA-F]{1,4}:){6}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"
    r"(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}"
    r"|(?:[0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){0,5}"
    r"|(?:[0-9a-fA-F]{1,4}:){1,5}:(?:[0-9a-fA-F]{1,4}:){0,4}"
    r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}"
    r"|(?:[0-9a-fA-F]{1,4}:){1,7}:"
    r"|::(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4}"
    r"|::(?:[0-9a-fA-F]{1,4}:){0,5}"
    r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}"
    r"|::(?=/(?:12[0-8]|1[01]\d|[1-9]?\d))"
    r")"
    r"(?:%[A-Za-z0-9._-]+)?"
    r"(?:/(?:12[0-8]|1[01]\d|[1-9]?\d))?"
    r"(?![0-9a-fA-F.]|:[0-9a-fA-F:])"
)
_KERNEL_EXPORT_CLIENT_RE = re.compile(r"^([^\s(]+)(\([^)]*\))?$")

# Common system/OS tokens that must not be globally replaced if a human account shares the name.
_PROTECTED_SYSTEM_TOKENS: frozenset[str] = frozenset(
    {
        "root",
        "ubuntu",
        "debian",
        "linux",
        "postgres",
        "systemd",
        "admin",
        "operator",
        "user",
        "bin",
        "sys",
        "sync",
        "mail",
        "news",
        "proxy",
        "www-data",
        "nobody",
        "nogroup",
    }
)


def compute_canonical_sha256(payload: Mapping[str, Any]) -> str:
    """Compute canonical compact sorted-key JSON SHA-256 hex digest excluding signature keys."""
    body = {k: v for k, v in payload.items() if k not in SIGNATURE_KEYS}
    canonical_bytes = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical_bytes).hexdigest()


def sign_snapshot(
    payload: dict[str, Any],
    *,
    unredacted_sha256: str | None = None,
    redacted: bool = False,
) -> str:
    """Attach canonical SHA-256 provenance_signature in-place and return the digest."""
    for sig_key in SIGNATURE_KEYS:
        payload.pop(sig_key, None)
    digest = compute_canonical_sha256(payload)
    sig: dict[str, Any] = {
        "algorithm": "SHA-256",
        "canonical_payload_sha256": digest,
        "sha256_provenance_digest": digest,
    }
    if unredacted_sha256 is not None:
        sig["unredacted_vault_sha256"] = unredacted_sha256
    if redacted:
        sig["redacted_for_public_repo"] = True
    payload["provenance_signature"] = sig
    return digest


def verify_snapshot_signature(payload: Mapping[str, Any]) -> bool:
    """Verify canonical SHA-256 provenance signature on ORT or thermal baseline payloads."""
    expected_digests: list[str] = []
    top_digest = payload.get("sha256_provenance_digest")
    if isinstance(top_digest, str) and top_digest:
        expected_digests.append(top_digest)

    sig_obj = payload.get("provenance_signature")
    if isinstance(sig_obj, Mapping):
        for field in ("canonical_payload_sha256", "sha256_provenance_digest"):
            val = sig_obj.get(field)
            if isinstance(val, str) and val:
                expected_digests.append(val)

    if not expected_digests:
        return False
    computed = compute_canonical_sha256(payload)
    return all(digest == computed for digest in expected_digests)


def _scrub_home_paths(text: str, home_paths: Iterable[str] = ()) -> str:
    result = _HOME_PATH_RE.sub(r"\1/REDACTED_USER", text)
    cleaned_homes = {
        h.rstrip("/") for h in home_paths if h and h not in ("/", "/root")
    }
    for home in sorted(cleaned_homes, key=len, reverse=True):
        if home in result:
            result = result.replace(home, "/home/REDACTED_USER")
    return result


def _scrub_usernames_in_text(
    text: str,
    usernames: Iterable[str] = (),
    home_paths: Iterable[str] = (),
) -> str:
    result = _scrub_home_paths(text, home_paths)
    result = _USER_KV_RE.sub(r"\1=REDACTED_USER", result)
    cleaned_users = {u.strip() for u in usernames if u and len(u.strip()) >= 2}
    for username in sorted(cleaned_users, key=len, reverse=True):
        if username.lower() in _PROTECTED_SYSTEM_TOKENS:
            continue
        pattern = re.compile(rf"(?<![A-Za-z0-9_.-]){re.escape(username)}(?![A-Za-z0-9_.-])")
        result = pattern.sub("REDACTED_USER", result)
    return result


def _scrub_known_literals(text: str, literals: Iterable[str], replacement: str) -> str:
    result = text
    cleaned_literals = {lit.strip() for lit in literals if lit and len(lit.strip()) >= 4}
    for literal in sorted(cleaned_literals, key=len, reverse=True):
        if literal in result:
            result = result.replace(literal, replacement)
    return result


def redact_nfs_export(
    export_line: str,
    *,
    usernames: Iterable[str] = (),
    home_paths: Iterable[str] = (),
) -> str:
    """Replace NFS client/CIDR/IP specs with REDACTED_SUBNET while keeping export path."""
    stripped = export_line.strip()
    if not stripped:
        return stripped

    # Ganesha formatted line: "<path> <clients> (ganesha,...)"
    ganesha_idx = stripped.find(" (ganesha")
    if ganesha_idx != -1:
        prefix = stripped[:ganesha_idx].strip()
        suffix = stripped[ganesha_idx:]
        parts = prefix.split(None, 1)
        export_path = parts[0] if parts else prefix
        if len(parts) > 1:
            redacted = f"{export_path} REDACTED_SUBNET{suffix}"
        else:
            redacted = f"{export_path}{suffix}"
        redacted = _IPV4_CIDR_RE.sub("REDACTED_SUBNET", redacted)
        redacted = _IPV6_CIDR_RE.sub("REDACTED_SUBNET", redacted)
        return _scrub_usernames_in_text(redacted, usernames, home_paths)

    # Kernel /etc/exports line: "<path> <client>(opts) [<client2>(opts)]"
    tokens = stripped.split()
    if len(tokens) <= 1:
        return _scrub_usernames_in_text(stripped, usernames, home_paths)

    export_path = tokens[0]
    redacted_clients: list[str] = []
    for tok in tokens[1:]:
        match = _KERNEL_EXPORT_CLIENT_RE.match(tok)
        if match:
            opts = match.group(2) or ""
            redacted_clients.append(f"REDACTED_SUBNET{opts}")
        else:
            redacted_clients.append("REDACTED_SUBNET")

    redacted = " ".join([export_path, *redacted_clients])
    redacted = _IPV4_CIDR_RE.sub("REDACTED_SUBNET", redacted)
    redacted = _IPV6_CIDR_RE.sub("REDACTED_SUBNET", redacted)
    return _scrub_usernames_in_text(redacted, usernames, home_paths)


def _scrub_ips(text: str, replacement: str = "REDACTED_IP") -> str:
    result = _IPV6_CIDR_RE.sub(replacement, text)

    def _replace_ipv4(match: re.Match[str]) -> str:
        prefix = result[: match.start()]
        if _IPV4_VERSION_CONTEXT_RE.search(prefix):
            return match.group(0)
        return replacement

    return _IPV4_CIDR_RE.sub(_replace_ipv4, result)


def redact_proc_cmdline(
    cmdline: str,
    *,
    known_serials: Iterable[str] = (),
    usernames: Iterable[str] = (),
    home_paths: Iterable[str] = (),
) -> str:
    """Redact UUIDs, PARTUUIDs, MACs, IPs, Tailscale authkeys, serials, and usernames."""
    result = _UUID_TOKEN_RE.sub(r"\1=REDACTED", cmdline)
    result = _BARE_UUID_RE.sub("REDACTED_UUID", result)
    result = _MAC_RE.sub("REDACTED_MAC", result)
    result = _TSKEY_RE.sub("REDACTED_TSKEY", result)
    result = _SERIAL_KV_RE.sub(r"\1\2REDACTED", result)
    result = _scrub_ips(result)
    result = _scrub_known_literals(result, known_serials, "REDACTED")
    return _scrub_usernames_in_text(result, usernames, home_paths)


def redact_dmesg_line(
    line: str,
    *,
    known_serials: Iterable[str] = (),
    known_uuids: Iterable[str] = (),
    usernames: Iterable[str] = (),
    home_paths: Iterable[str] = (),
) -> str:
    """Scrub hardware serials, MACs, IPs, UUIDs, Tailscale keys, and usernames from dmesg."""
    result = _MAC_RE.sub("REDACTED_MAC", line)
    result = _TSKEY_RE.sub("REDACTED_TSKEY", result)
    result = _SERIAL_KV_RE.sub(r"\1\2REDACTED", result)
    result = _UUID_TOKEN_RE.sub(r"\1=REDACTED", result)
    result = _BARE_UUID_RE.sub("REDACTED_UUID", result)
    result = _scrub_ips(result)
    result = _scrub_known_literals(result, known_serials, "REDACTED")
    result = _scrub_known_literals(result, known_uuids, "REDACTED_UUID")
    return _scrub_usernames_in_text(result, usernames, home_paths)


def redact_block_tree(
    devices: list[dict[str, Any]],
    *,
    usernames: Iterable[str] = (),
    home_paths: Iterable[str] = (),
) -> None:
    """Recursively redact serial, uuid, partuuid, and user home paths from lsblk trees."""
    for dev in devices:
        for secret_key in ("serial", "uuid", "partuuid"):
            if dev.get(secret_key) is not None:
                dev[secret_key] = "REDACTED"
        if isinstance(dev.get("mountpoint"), str):
            dev["mountpoint"] = _scrub_usernames_in_text(dev["mountpoint"], usernames, home_paths)
        if isinstance(dev.get("mountpoints"), list):
            dev["mountpoints"] = [
                _scrub_usernames_in_text(mp, usernames, home_paths) if isinstance(mp, str) else mp
                for mp in dev["mountpoints"]
            ]
        children = dev.get("children")
        if isinstance(children, list):
            redact_block_tree(children, usernames=usernames, home_paths=home_paths)


def _collect_block_secrets(
    devices: Iterable[Mapping[str, Any]],
    serials: set[str],
    uuids: set[str],
) -> None:
    for dev in devices:
        ser = dev.get("serial")
        if isinstance(ser, str) and ser.strip():
            serials.add(ser.strip())
        for key in ("uuid", "partuuid"):
            val = dev.get(key)
            if isinstance(val, str) and val.strip():
                uuids.add(val.strip())
        children = dev.get("children")
        if isinstance(children, list):
            _collect_block_secrets(children, serials, uuids)


def _scrub_strings_recursive(
    node: Any,
    *,
    usernames: set[str],
    home_paths: set[str],
    skip_keys: frozenset[str] = frozenset({"os_release", "hostname", "id"}),
) -> Any:
    if isinstance(node, str):
        cleaned = _scrub_usernames_in_text(node, usernames, home_paths)
        cleaned = _TSKEY_RE.sub("REDACTED_TSKEY", cleaned)
        return cleaned
    if isinstance(node, list):
        return [
            _scrub_strings_recursive(
                item, usernames=usernames, home_paths=home_paths, skip_keys=skip_keys
            )
            for item in node
        ]
    if isinstance(node, dict):
        return {
            k: (
                v
                if k in skip_keys
                else _scrub_strings_recursive(
                    v, usernames=usernames, home_paths=home_paths, skip_keys=skip_keys
                )
            )
            for k, v in node.items()
        }
    return node


def build_public_snapshot(
    raw_payload: Mapping[str, Any],
    raw_sha256: str,
    primary_nic: str,
    nic_up: bool,
    *,
    nic_has_ipv4: bool = False,
    extra_usernames: Iterable[str] = (),
) -> dict[str, Any]:
    """Produce a strictly redacted, SHA-256-signed .public.json companion snapshot."""
    pub: dict[str, Any] = copy.deepcopy(dict(raw_payload))
    for sig_key in SIGNATURE_KEYS:
        pub.pop(sig_key, None)

    known_serials: set[str] = set()
    known_uuids: set[str] = set()
    usernames: set[str] = {u.strip() for u in extra_usernames if u and u.strip()}
    home_paths: set[str] = set()

    sec = raw_payload.get("security_and_users")
    if isinstance(sec, Mapping):
        users_list = sec.get("human_and_root_users")
        if isinstance(users_list, list):
            for entry in users_list:
                if not isinstance(entry, Mapping):
                    continue
                uid_val = entry.get("uid")
                uname = entry.get("username")
                uhome = entry.get("home")
                if isinstance(uid_val, int) and uid_val >= 1000:
                    if isinstance(uname, str) and uname.strip():
                        usernames.add(uname.strip())
                    if isinstance(uhome, str) and uhome.strip():
                        home_paths.add(uhome.strip())

    hw = pub.get("hardware_inventory")
    if isinstance(hw, dict):
        nvme_primary = hw.get("nvme_primary")
        if isinstance(nvme_primary, dict) and nvme_primary.get("serial") is not None:
            if isinstance(nvme_primary["serial"], str) and nvme_primary["serial"].strip():
                known_serials.add(nvme_primary["serial"].strip())
            nvme_primary["serial"] = "REDACTED"

        raid_arrays = hw.get("usb_raid_arrays")
        if isinstance(raid_arrays, dict):
            for arr_entry in raid_arrays.values():
                if not isinstance(arr_entry, dict):
                    continue
                detected_disks = arr_entry.get("detected_disks")
                if isinstance(detected_disks, list):
                    for disk in detected_disks:
                        if isinstance(disk, dict) and disk.get("serial") is not None:
                            if isinstance(disk["serial"], str) and disk["serial"].strip():
                                known_serials.add(disk["serial"].strip())
                            disk["serial"] = "REDACTED"

        block_devices = hw.get("block_devices")
        if isinstance(block_devices, list):
            _collect_block_secrets(block_devices, known_serials, known_uuids)
            redact_block_tree(block_devices, usernames=usernames, home_paths=home_paths)

    services = pub.get("databroker_services_state")
    if isinstance(services, dict):
        nfs = services.get("nfs_v4_server")
        if isinstance(nfs, dict) and isinstance(nfs.get("configured_exports"), list):
            nfs["configured_exports"] = [
                redact_nfs_export(str(exp), usernames=usernames, home_paths=home_paths)
                for exp in nfs["configured_exports"]
            ]

    os_state = pub.get("os_and_kernel_state")
    if isinstance(os_state, dict):
        cmdline = os_state.get("proc_cmdline")
        if isinstance(cmdline, str):
            os_state["proc_cmdline"] = redact_proc_cmdline(
                cmdline,
                known_serials=known_serials,
                usernames=usernames,
                home_paths=home_paths,
            )
        bus_events = os_state.get("dmesg_bus_events")
        if isinstance(bus_events, list):
            os_state["dmesg_bus_events"] = [
                redact_dmesg_line(
                    str(line),
                    known_serials=known_serials,
                    known_uuids=known_uuids,
                    usernames=usernames,
                    home_paths=home_paths,
                )
                for line in bus_events
            ]

    safe_nic = re.sub(r"[^a-zA-Z0-9_]", "_", primary_nic or "eth0")
    net_raw = raw_payload.get("network_topology")
    hostname = net_raw.get("hostname") if isinstance(net_raw, Mapping) else None
    pub["network_topology"] = {
        "hostname": hostname,
        "primary_nic": primary_nic,
        "primary_nic_operstate": "UP" if nic_up else "DOWN",
        "primary_nic_has_ipv4": nic_has_ipv4,
        f"primary_nic_{safe_nic}_operstate": "UP" if nic_up else "DOWN",
    }

    pub.pop("security_and_users", None)

    rt_raw = raw_payload.get("runtime_processes")
    proc_count = rt_raw.get("total_process_count", 0) if isinstance(rt_raw, Mapping) else 0
    pub["runtime_processes"] = {"total_process_count": proc_count}

    sw = pub.get("software_provenance")
    if isinstance(sw, dict):
        sw.pop("installed_apt_packages", None)

    pub = _scrub_strings_recursive(pub, usernames=usernames, home_paths=home_paths)
    sign_snapshot(pub, unredacted_sha256=raw_sha256, redacted=True)
    return pub
