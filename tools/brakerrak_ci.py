#!/usr/bin/env python3
"""DREW-V Labs // BrakerRak Repository Integrity, Hygiene & Verification Gate.

Path: brakerrak/tools/brakerrak_ci.py

Usage:
    uv run python tools/brakerrak_ci.py --check

Gates enforced under ``--check``:
  1. Binary EXIF/GPS & Size Gate on all tracked images (.jpg, .jpeg, .png, .webp):
     - Fails if any single image exceeds 3 MiB (3 * 1024 * 1024 bytes).
     - Fails if Exif, GPS, XMP, or IPTC metadata markers/chunks exist
       (JPEG APP1/APP13, PNG eXIf/Exif and metadata tEXt/iTXt/zTXt, WebP EXIF/XMP).
  2. Hygiene & Bleed Gate on all tracked text files (excluding this script):
     - Rejects downstream astrophotography/RF bleed and personal lab/PII literals.
  3. Thermal Artifact Integrity Check:
     - Verifies canonical SHA-256 of artifacts/ctd-thermal-soak-baseline.json
       matches its embedded sha256_provenance_digest field.
  4. Shell & Python Verification:
     - Runs bash -n and shellcheck on forge.sh, install-cli.sh, scripts/*.sh,
       and benchmarks/*.sh.
     - Runs uv run ruff check, uv run mypy --strict, and uv run pytest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zlib
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

MAX_IMAGE_BYTES = 3 * 1024 * 1024  # 3 MiB

IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".webp"})

BINARY_EXTENSIONS = frozenset(
    {
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".webp",
        ".ico",
        ".pdf",
        ".parquet",
        ".arrow",
        ".zst",
        ".xz",
        ".gz",
        ".bz2",
        ".img",
        ".tar",
        ".zip",
    }
)

FALLBACK_IGNORED_DIRS = frozenset(
    {
        ".git",
        ".venv",
        "__pycache__",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        "dist",
        "_site",
        "graphify-out",
        "skills",
    }
)

FALLBACK_IGNORED_FILES = frozenset({".DS_Store", "GEMINI.md", "node.env"})

JPEG_METADATA_SIGNATURES: tuple[tuple[str, bytes], ...] = (
    ("Exif", b"Exif"),
    ("GPS", b"GPS"),
    ("XMP", b"ns.adobe.com/xap"),
    ("XMP-ext", b"ns.adobe.com/xmp"),
    ("XMP-meta", b"xmpmeta"),
    ("IPTC", b"IPTC"),
    ("Photoshop", b"Photoshop 3.0"),
    ("Photoshop-8BIM", b"8BIM"),
)

JPEG_RAW_SIGNATURES: tuple[tuple[str, bytes], ...] = (
    ("Exif header", b"Exif\x00\x00"),
    ("XMP packet", b"<x:xmpmeta"),
    ("XMP namespace", b"http://ns.adobe.com/xap/"),
    ("XMP extension", b"http://ns.adobe.com/xmp/"),
)

PNG_TEXT_METADATA_MARKERS: tuple[str, ...] = (
    "xml:com.adobe.xmp",
    "xmpmeta",
    "ns.adobe.com/xap",
    "ns.adobe.com/xmp",
    "exif",
    "iptc",
    "gps",
    "photoshop",
)


@dataclass(frozen=True)
class ForbiddenRule:
    """Regex rule enforced by the repository hygiene and bleed gate."""

    description: str
    pattern: re.Pattern[str]
    allowed_paths: frozenset[Path] = frozenset()


FORBIDDEN_RULES: tuple[ForbiddenRule, ...] = (
    ForbiddenRule(
        description="Downstream project bleed (adalove/adalovespace)",
        pattern=re.compile(r"adalove(?:space)?", re.IGNORECASE),
    ),
    ForbiddenRule(
        description='Downstream RF bleed ("sigmf")',
        pattern=re.compile(r"\bsigmf\b", re.IGNORECASE),
    ),
    ForbiddenRule(
        description='Downstream astronomy bleed ("fits")',
        pattern=re.compile(r"""["']fits["']""", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Personal lab subnet literal (10.0.10.)",
        pattern=re.compile(r"10\.0\.10\."),
    ),
    ForbiddenRule(
        description="Personal home directory literal (/home/drew)",
        pattern=re.compile(r"/home/drew\b", re.IGNORECASE),
    ),
    ForbiddenRule(
        description='Personal ADMIN_USER literal (ADMIN_USER="drew")',
        pattern=re.compile(r"""ADMIN_USER\s*=\s*["']?drew["']?\b""", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Personal surname literal (Vandagriff)",
        pattern=re.compile(r"vandagriff", re.IGNORECASE),
        allowed_paths=frozenset({Path("LICENSE")}),
    ),
    ForbiddenRule(
        description="Personal host literal (jakebase)",
        pattern=re.compile(r"jakebase", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Personal vault array literal (bigred)",
        pattern=re.compile(r"bigred", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Personal vault array literal (lilblu)",
        pattern=re.compile(r"lilblu", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="BrakerRak misspelling with 'c' (Bracker/Brakc)",
        pattern=re.compile(r"bracker|brakc", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Retired entity literal (hamstak/hamstack)",
        pattern=re.compile(r"hamstak|hamstack", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Retired entity literal (darksilicon)",
        pattern=re.compile(r"darksilicon", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Retired entity literal (poggerbox)",
        pattern=re.compile(r"poggerbox", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Retired entity literal (codabox)",
        pattern=re.compile(r"codabox", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Retired entity literal (coffeecan)",
        pattern=re.compile(r"coffeecan", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Retired entity literal (snitchmesh)",
        pattern=re.compile(r"snitchmesh", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Downstream astro literal (adastak)",
        pattern=re.compile(r"adastak", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Downstream astro literal (adascope)",
        pattern=re.compile(r"adascope", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Downstream astro literal (alone-v)",
        pattern=re.compile(r"alone-v", re.IGNORECASE),
    ),
    ForbiddenRule(
        description="Personal macOS home directory literal (/Users/drew)",
        pattern=re.compile(r"/Users/drew\b", re.IGNORECASE),
    ),
)

SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")
THERMAL_BASELINE_REL = Path("artifacts/ctd-thermal-soak-baseline.json")


def collect_repo_files(repo_root: Path) -> list[Path]:
    """Return sorted repository files (tracked + non-ignored untracked, excluding symlinks)."""
    git_bin = shutil.which("git")
    if git_bin and (repo_root / ".git").exists():
        proc = subprocess.run(
            [
                git_bin,
                "-C",
                str(repo_root),
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ],
            capture_output=True,
            check=False,
        )
        if proc.returncode == 0:
            paths: list[Path] = []
            seen: set[Path] = set()
            for raw_entry in proc.stdout.split(b"\x00"):
                if not raw_entry:
                    continue
                rel = Path(os.fsdecode(raw_entry))
                full = repo_root / rel
                if full in seen:
                    continue
                seen.add(full)
                if full.is_file() and not full.is_symlink():
                    paths.append(full)
            return sorted(paths)

    fallback_paths: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(repo_root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in FALLBACK_IGNORED_DIRS]
        cur_dir = Path(dirpath)
        for fn in sorted(filenames):
            if fn in FALLBACK_IGNORED_FILES:
                continue
            full = cur_dir / fn
            if full.is_file() and not full.is_symlink():
                fallback_paths.append(full)
    return sorted(fallback_paths)


def inspect_jpeg_metadata(data: bytes) -> list[str]:
    """Inspect JPEG segments and raw markers for Exif, GPS, XMP, or IPTC metadata."""
    findings: list[str] = []
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return ["invalid JPEG header (missing SOI 0xFFD8)"]

    pos = 2
    n = len(data)
    while pos < n:
        if data[pos] != 0xFF:
            break
        while pos < n and data[pos] == 0xFF:
            pos += 1
        if pos >= n:
            break
        marker = data[pos]
        pos += 1

        if marker in (0xD9, 0xDA):  # EOI or SOS (start of entropy-coded scan)
            break
        if marker == 0x01 or 0xD0 <= marker <= 0xD8:
            continue
        if pos + 2 > n:
            findings.append(f"truncated JPEG segment length at marker 0xFF{marker:02X}")
            break

        seg_len = struct.unpack(">H", data[pos : pos + 2])[0]
        if seg_len < 2 or pos + seg_len > n:
            findings.append(f"malformed JPEG segment length ({seg_len}) at 0xFF{marker:02X}")
            break

        payload = data[pos + 2 : pos + seg_len]
        pos += seg_len

        if marker == 0xE1:  # APP1 (Exif / XMP)
            if payload.startswith(b"Exif\x00\x00"):
                tag_note = " (contains GPS marker)" if b"GPS" in payload else ""
                findings.append(f"JPEG APP1 Exif metadata segment present{tag_note}")
            elif (
                b"ns.adobe.com/xap" in payload
                or b"ns.adobe.com/xmp" in payload
                or b"xmpmeta" in payload
            ):
                findings.append("JPEG APP1 XMP metadata segment present")
            else:
                findings.append("JPEG APP1 metadata segment present")
        elif marker == 0xED:  # APP13 (Photoshop / IPTC)
            findings.append("JPEG APP13 Photoshop/IPTC metadata segment present")
        elif marker == 0xFE or (0xE0 <= marker <= 0xEF):
            if marker == 0xE2 and payload.startswith(b"ICC_PROFILE\x00"):
                continue
            for label, sig in JPEG_METADATA_SIGNATURES:
                if sig in payload:
                    findings.append(
                        f"JPEG marker 0xFF{marker:02X} contains {label} metadata signature"
                    )

    eoi_idx = data.rfind(b"\xff\xd9")
    if eoi_idx != -1 and eoi_idx + 2 < n:
        trailing = data[eoi_idx + 2 :]
        for label, sig in JPEG_METADATA_SIGNATURES:
            if sig in trailing:
                findings.append(f"trailing data after JPEG EOI contains {label} metadata")

    for label, sig in JPEG_RAW_SIGNATURES:
        if sig in data:
            msg = f"raw JPEG bytes contain {label}"
            if msg not in findings:
                findings.append(msg)

    return findings


def _decode_png_text_chunk(chunk_type: bytes, payload: bytes) -> tuple[str, str]:
    """Extract (keyword, text) from a PNG tEXt, zTXt, or iTXt chunk payload."""
    nul_idx = payload.find(b"\x00")
    if nul_idx == -1:
        return payload.decode("latin-1", errors="ignore"), ""
    keyword = payload[:nul_idx].decode("latin-1", errors="ignore")
    rest = payload[nul_idx + 1 :]

    if chunk_type == b"tEXt":
        return keyword, rest.decode("latin-1", errors="ignore")

    if chunk_type == b"zTXt":
        if len(rest) < 2:
            return keyword, ""
        compressed = rest[1:]
        try:
            text_bytes = zlib.decompress(compressed)
        except zlib.error:
            text_bytes = compressed
        return keyword, text_bytes.decode("latin-1", errors="ignore")

    # iTXt: comp_flag(1) comp_method(1) lang\0 translated_kw\0 text
    if len(rest) < 2:
        return keyword, ""
    comp_flag = rest[0]
    tail = rest[2:]
    lang_end = tail.find(b"\x00")
    if lang_end == -1:
        return keyword, tail.decode("utf-8", errors="ignore")
    after_lang = tail[lang_end + 1 :]
    trans_end = after_lang.find(b"\x00")
    if trans_end == -1:
        return keyword, after_lang.decode("utf-8", errors="ignore")
    raw_text = after_lang[trans_end + 1 :]
    if comp_flag == 1:
        try:
            raw_text = zlib.decompress(raw_text)
        except zlib.error:
            pass
    return keyword, raw_text.decode("utf-8", errors="ignore")


def inspect_png_metadata(data: bytes) -> list[str]:
    """Inspect PNG chunks for eXIf/Exif, GPS, XMP, or IPTC metadata."""
    findings: list[str] = []
    if len(data) < 8 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return ["invalid PNG signature"]

    pos = 8
    n = len(data)
    while pos + 8 <= n:
        chunk_len, chunk_type = struct.unpack(">I4s", data[pos : pos + 8])
        chunk_end = pos + 12 + chunk_len
        if chunk_end > n:
            findings.append(f"truncated PNG chunk {chunk_type!r} (length {chunk_len})")
            break

        payload = data[pos + 8 : pos + 8 + chunk_len]
        pos = chunk_end

        if chunk_type.lower() == b"exif":
            findings.append(f"PNG {chunk_type.decode('ascii', errors='replace')} chunk present")
        elif chunk_type in (b"tEXt", b"iTXt", b"zTXt"):
            keyword, text = _decode_png_text_chunk(chunk_type, payload)
            combined_lower = f"{keyword}\n{text}".lower()
            for marker in PNG_TEXT_METADATA_MARKERS:
                if marker in combined_lower:
                    findings.append(
                        f"PNG {chunk_type.decode('ascii')} chunk ({keyword!r}) contains "
                        f"{marker!r} metadata"
                    )
                    break

        if chunk_type == b"IEND":
            break

    return findings


def inspect_webp_metadata(data: bytes) -> list[str]:
    """Inspect WebP RIFF container chunks for EXIF, XMP, or IPTC metadata."""
    findings: list[str] = []
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return ["invalid WebP RIFF header"]

    pos = 12
    n = len(data)
    while pos + 8 <= n:
        fourcc = data[pos : pos + 4]
        chunk_size = struct.unpack("<I", data[pos + 4 : pos + 8])[0]
        payload_start = pos + 8
        payload_end = payload_start + chunk_size
        if payload_end > n:
            findings.append(f"truncated WebP chunk {fourcc!r} (length {chunk_size})")
            break
        payload = data[payload_start:payload_end]
        pos = payload_end + (chunk_size & 1)

        if fourcc in (b"EXIF", b"XMP ", b"IPTC"):
            findings.append(f"WebP {fourcc.decode('ascii').strip()} metadata chunk present")
        elif fourcc == b"VP8X" and len(payload) >= 1:
            flags = payload[0]
            if flags & 0x08:
                findings.append("WebP VP8X header advertises EXIF metadata flag")
            if flags & 0x04:
                findings.append("WebP VP8X header advertises XMP metadata flag")

    return findings


def check_images(repo_root: Path, files: Sequence[Path]) -> tuple[list[str], int]:
    """Enforce binary EXIF/GPS/XMP/IPTC absence and 3 MiB size cap across repo images."""
    errors: list[str] = []
    checked = 0

    for path in files:
        ext = path.suffix.lower()
        if ext not in IMAGE_EXTENSIONS:
            continue
        checked += 1
        rel = path.relative_to(repo_root)
        data = path.read_bytes()
        size = len(data)
        if size > MAX_IMAGE_BYTES:
            size_mb = size / (1024 * 1024)
            errors.append(
                f"{rel}: image size {size_mb:.2f} MiB ({size:,} B) exceeds 3.00 MiB "
                f"({MAX_IMAGE_BYTES:,} B) limit"
            )

        if ext in (".jpg", ".jpeg"):
            meta_findings = inspect_jpeg_metadata(data)
        elif ext == ".png":
            meta_findings = inspect_png_metadata(data)
        else:
            meta_findings = inspect_webp_metadata(data)

        for finding in meta_findings:
            errors.append(f"{rel}: {finding}")

    return errors, checked


def check_hygiene(
    repo_root: Path,
    files: Sequence[Path],
    exclude_paths: frozenset[Path] | None = None,
) -> tuple[list[str], int]:
    """Scan tracked text files for forbidden downstream bleed and personal/PII literals."""
    errors: list[str] = []
    checked = 0
    excluded = (
        exclude_paths
        if exclude_paths is not None
        else frozenset({Path("tools/brakerrak_ci.py")})
    )

    for path in files:
        if path.suffix.lower() in BINARY_EXTENSIONS:
            continue
        rel = path.relative_to(repo_root)
        if rel in excluded:
            continue

        raw_bytes = path.read_bytes()
        if b"\x00" in raw_bytes:
            continue
        try:
            text = raw_bytes.decode("utf-8")
        except UnicodeDecodeError:
            continue

        checked += 1
        for rule in FORBIDDEN_RULES:
            if rel in rule.allowed_paths:
                continue
            for lineno, line in enumerate(text.splitlines(), start=1):
                if rule.pattern.search(line):
                    errors.append(f"{rel}:{lineno}: {rule.description}: {line.strip()}")

    return errors, checked


def compute_canonical_sha256(payload: dict[str, object]) -> str:
    """Compute canonical JSON SHA-256 (sorted keys, compact separators, UTF-8)."""
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def check_thermal_artifact(repo_root: Path) -> list[str]:
    """Verify artifacts/ctd-thermal-soak-baseline.json matches its provenance digest."""
    artifact_path = repo_root / THERMAL_BASELINE_REL
    if not artifact_path.is_file():
        return [f"{THERMAL_BASELINE_REL}: missing required thermal baseline artifact"]

    try:
        loaded: object = json.loads(artifact_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{THERMAL_BASELINE_REL}: failed to parse JSON ({exc})"]

    if not isinstance(loaded, dict):
        return [f"{THERMAL_BASELINE_REL}: top-level JSON value must be an object"]

    expected = loaded.get("sha256_provenance_digest")
    if not isinstance(expected, str) or not SHA256_HEX_RE.match(expected):
        return [
            f"{THERMAL_BASELINE_REL}: missing or invalid 64-hex "
            f"sha256_provenance_digest ({expected!r})"
        ]

    unsigned_payload: dict[str, object] = {
        str(k): v for k, v in loaded.items() if k != "sha256_provenance_digest"
    }
    actual = compute_canonical_sha256(unsigned_payload)
    if actual != expected:
        return [
            f"{THERMAL_BASELINE_REL}: canonical SHA-256 mismatch "
            f"(expected {expected}, computed {actual})"
        ]

    return []


def update_thermal_baseline_sha(repo_root: Path) -> tuple[list[str], str]:
    """Recompute sha256_provenance_digest and atomically update the thermal baseline JSON."""
    artifact_path = repo_root / THERMAL_BASELINE_REL
    if not artifact_path.is_file():
        return [f"{THERMAL_BASELINE_REL}: missing required thermal baseline artifact"], ""

    try:
        loaded: object = json.loads(artifact_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{THERMAL_BASELINE_REL}: failed to parse JSON ({exc})"], ""

    if not isinstance(loaded, dict):
        return [f"{THERMAL_BASELINE_REL}: top-level JSON value must be an object"], ""

    unsigned_payload: dict[str, object] = {
        str(k): v for k, v in loaded.items() if k != "sha256_provenance_digest"
    }
    digest = compute_canonical_sha256(unsigned_payload)
    updated_payload: dict[str, object] = dict(unsigned_payload)
    updated_payload["sha256_provenance_digest"] = digest
    serialized = json.dumps(updated_payload, indent=2) + "\n"

    orig_mode = stat.S_IMODE(artifact_path.stat().st_mode)
    tmp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=artifact_path.parent,
            prefix=f".{artifact_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as tmp_file:
            tmp_path = Path(tmp_file.name)
            tmp_file.write(serialized)
            tmp_file.flush()
            os.fsync(tmp_file.fileno())
        os.chmod(tmp_path, orig_mode)
        os.replace(tmp_path, artifact_path)
    except OSError as exc:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)
        return [f"{THERMAL_BASELINE_REL}: failed atomic write ({exc})"], ""

    return [], digest


def collect_shell_targets(repo_root: Path) -> tuple[list[Path], list[str]]:
    """Collect shell scripts targeted by bash -n and shellcheck."""
    errors: list[str] = []
    targets: list[Path] = []

    for root_script in ("forge.sh", "install-cli.sh"):
        p = repo_root / root_script
        if p.is_file():
            targets.append(p)
        else:
            errors.append(f"{root_script}: expected top-level shell script missing")

    for subdir in ("scripts", "benchmarks"):
        dir_path = repo_root / subdir
        if dir_path.is_dir():
            targets.extend(sorted(dir_path.glob("*.sh")))

    return targets, errors


def check_shell_scripts(repo_root: Path, skip_shellcheck: bool = False) -> tuple[list[str], int]:
    """Run bash -n and shellcheck across forge.sh, install-cli.sh, scripts/*.sh, benchmarks/*.sh."""
    targets, errors = collect_shell_targets(repo_root)
    if not targets:
        errors.append("no shell scripts found to validate")
        return errors, 0

    for sh_path in targets:
        proc = subprocess.run(
            ["bash", "-n", str(sh_path)],
            cwd=str(repo_root),
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            rel = sh_path.relative_to(repo_root)
            errors.append(f"{rel}: bash -n failed:\n{proc.stderr.strip()}")

    if not skip_shellcheck:
        sc_bin = shutil.which("shellcheck")
        if not sc_bin:
            errors.append(
                "shellcheck binary not found on PATH "
                "(install with `brew install shellcheck` or `apt-get install shellcheck`)"
            )
        else:
            rel_targets = [str(p.relative_to(repo_root)) for p in targets]
            proc = subprocess.run(
                [sc_bin, "-x", *rel_targets],
                cwd=str(repo_root),
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode != 0:
                details = (proc.stdout or proc.stderr).strip()
                errors.append(f"shellcheck failed:\n{details}")

    return errors, len(targets)


def _run_tool_step(repo_root: Path, label: str, cmd: list[str]) -> list[str]:
    proc = subprocess.run(
        cmd,
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        combined = "\n".join(part for part in (proc.stdout.strip(), proc.stderr.strip()) if part)
        return [f"{label} failed (exit {proc.returncode}):\n{combined}"]
    return []


def check_python_suite(repo_root: Path) -> list[str]:
    """Run uv run ruff check, uv run mypy --strict, and uv run pytest."""
    uv_bin = shutil.which("uv")
    if not uv_bin:
        return ["uv binary not found on PATH (required for ruff, mypy, and pytest)"]

    errors: list[str] = []
    errors.extend(
        _run_tool_step(repo_root, "uv run ruff check", [uv_bin, "run", "--frozen", "ruff", "check"])
    )
    errors.extend(
        _run_tool_step(
            repo_root, "uv run mypy --strict", [uv_bin, "run", "--frozen", "mypy", "--strict"]
        )
    )
    errors.extend(
        _run_tool_step(repo_root, "uv run pytest", [uv_bin, "run", "--frozen", "pytest"])
    )
    return errors


def run_checks(
    repo_root: Path,
    skip_shellcheck: bool = False,
    skip_python: bool = False,
) -> int:
    """Execute all BrakerRak CI gates and report pass/fail status."""
    files = collect_repo_files(repo_root)
    all_errors: list[str] = []

    img_errors, img_count = check_images(repo_root, files)
    all_errors.extend(img_errors)

    hygiene_errors, text_count = check_hygiene(repo_root, files)
    all_errors.extend(hygiene_errors)

    all_errors.extend(check_thermal_artifact(repo_root))

    shell_errors, shell_count = check_shell_scripts(repo_root, skip_shellcheck=skip_shellcheck)
    all_errors.extend(shell_errors)

    if not skip_python:
        all_errors.extend(check_python_suite(repo_root))

    if all_errors:
        print(f"[BRAKERRAK:CI] FAILED with {len(all_errors)} issue(s):", file=sys.stderr)
        for err in all_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    sc_note = " (shellcheck skipped)" if skip_shellcheck else " + shellcheck"
    py_note = " (python suite skipped)" if skip_python else ", ruff, mypy --strict, pytest"
    print(
        f"[BRAKERRAK:CI] OK — {img_count} images (EXIF/GPS/XMP/IPTC clean, <=3 MiB), "
        f"{text_count} text files (hygiene clean), thermal baseline SHA-256 verified, "
        f"{shell_count} shell scripts (bash -n{sc_note}){py_note}."
    )
    return 0


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="BrakerRak CI integrity, hygiene, asset metadata, and test gate."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run all repository integrity, hygiene, shell, and Python checks.",
    )
    parser.add_argument(
        "--update-baseline-sha",
        action="store_true",
        help=(
            "Recompute canonical SHA-256 and atomically update "
            "artifacts/ctd-thermal-soak-baseline.json."
        ),
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Optional repository root override (defaults to brakerrak repo root).",
    )
    parser.add_argument(
        "--skip-shellcheck",
        action="store_true",
        help="Skip shellcheck (still runs bash -n).",
    )
    parser.add_argument(
        "--skip-python",
        action="store_true",
        help="Skip uv run ruff/mypy/pytest checks.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.check and not args.update_baseline_sha:
        parse_args(["--help"])
        return 1

    repo_root = (
        args.repo_root.resolve()
        if args.repo_root is not None
        else Path(__file__).resolve().parent.parent
    )

    if args.update_baseline_sha:
        errors, digest = update_thermal_baseline_sha(repo_root)
        if errors:
            print("[BRAKERRAK:CI] FAILED to update thermal baseline SHA-256:", file=sys.stderr)
            for err in errors:
                print(f"  - {err}", file=sys.stderr)
            return 1
        print(f"[BRAKERRAK:CI] Updated {THERMAL_BASELINE_REL} sha256_provenance_digest={digest}")
        if not args.check:
            return 0

    return run_checks(
        repo_root,
        skip_shellcheck=args.skip_shellcheck,
        skip_python=args.skip_python,
    )


if __name__ == "__main__":
    sys.exit(main())
