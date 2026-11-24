"""Unit tests for tools/brakerrak_ci.py gates (binary EXIF/size, hygiene, thermal SHA-256)."""

from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path

from tools.brakerrak_ci import (
    MAX_IMAGE_BYTES,
    check_hygiene,
    check_images,
    check_thermal_artifact,
    compute_canonical_sha256,
    inspect_jpeg_metadata,
    inspect_png_metadata,
    inspect_webp_metadata,
)


def _make_png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
    return struct.pack(">I4s", len(payload), chunk_type) + payload + struct.pack(">I", crc)


def _make_minimal_png(*extra_chunks: tuple[bytes, bytes]) -> bytes:
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr_payload = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    parts = [sig, _make_png_chunk(b"IHDR", ihdr_payload)]
    for ctype, payload in extra_chunks:
        parts.append(_make_png_chunk(ctype, payload))
    parts.append(_make_png_chunk(b"IEND", b""))
    return b"".join(parts)


def _make_jpeg_segment(marker_byte: int, payload: bytes) -> bytes:
    return bytes([0xFF, marker_byte]) + struct.pack(">H", len(payload) + 2) + payload


def _make_minimal_jpeg(*segments: tuple[int, bytes]) -> bytes:
    parts = [b"\xff\xd8"]
    for marker_byte, payload in segments:
        parts.append(_make_jpeg_segment(marker_byte, payload))
    parts.append(b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x00\xff\xd9")
    return b"".join(parts)


def _make_webp(*chunks: tuple[bytes, bytes]) -> bytes:
    body_parts: list[bytes] = [b"WEBP"]
    for fourcc, payload in chunks:
        pad = b"\x00" if (len(payload) & 1) else b""
        body_parts.append(fourcc + struct.pack("<I", len(payload)) + payload + pad)
    body = b"".join(body_parts)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def test_jpeg_metadata_inspection() -> None:
    clean_jpg = _make_minimal_jpeg(
        (0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"),
        (0xE2, b"ICC_PROFILE\x00\x01\x01mntrRGB XYZ "),
    )
    assert inspect_jpeg_metadata(clean_jpg) == []

    exif_jpg = _make_minimal_jpeg((0xE1, b"Exif\x00\x00II*\x00GPS"))
    exif_findings = inspect_jpeg_metadata(exif_jpg)
    assert any("APP1 Exif" in f and "GPS" in f for f in exif_findings)

    xmp_jpg = _make_minimal_jpeg((0xE1, b"http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta/>"))
    assert any("APP1 XMP" in f for f in inspect_jpeg_metadata(xmp_jpg))

    iptc_jpg = _make_minimal_jpeg((0xED, b"Photoshop 3.0\x008BIM"))
    assert any("APP13" in f for f in inspect_jpeg_metadata(iptc_jpg))


def test_png_metadata_inspection() -> None:
    clean_png = _make_minimal_png((b"sRGB", b"\x00"))
    assert inspect_png_metadata(clean_png) == []

    exif_png = _make_minimal_png((b"eXIf", b"MM\x00*\x00\x00\x00\x08"))
    assert any("eXIf" in f for f in inspect_png_metadata(exif_png))

    xmp_itxt = b"XML:com.adobe.xmp\x00\x00\x00\x00\x00<x:xmpmeta/>"
    xmp_png = _make_minimal_png((b"iTXt", xmp_itxt))
    assert any("iTXt" in f for f in inspect_png_metadata(xmp_png))

    ztxt_payload = b"Raw profile type exif\x00\x00" + zlib.compress(b"exif data")
    ztxt_png = _make_minimal_png((b"zTXt", ztxt_payload))
    assert any("zTXt" in f for f in inspect_png_metadata(ztxt_png))


def test_webp_metadata_inspection() -> None:
    clean_webp = _make_webp((b"VP8 ", b"\x00\x00\x00\x00"))
    assert inspect_webp_metadata(clean_webp) == []

    exif_webp = _make_webp(
        (b"VP8X", b"\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00"),
        (b"EXIF", b"II*"),
    )
    findings = inspect_webp_metadata(exif_webp)
    assert any("VP8X" in f and "EXIF" in f for f in findings)
    assert any("WebP EXIF" in f for f in findings)


def test_check_images_enforces_size_cap(tmp_path: Path) -> None:
    oversized = tmp_path / "huge.png"
    pad_chunk = b"tEXt", b"Comment\x00" + (b"A" * (MAX_IMAGE_BYTES + 128))
    oversized.write_bytes(_make_minimal_png(pad_chunk))

    errors, count = check_images(tmp_path, [oversized])
    assert count == 1
    assert any("exceeds 3.00 MiB" in e for e in errors)


def test_check_hygiene_rules_and_license_exception(tmp_path: Path) -> None:
    # Construct test strings dynamically so this test file itself stays hygiene-clean.
    surname = "Vanda" + "griff"
    license_file = tmp_path / "LICENSE"
    license_file.write_text(f"Copyright 2026 DREW-V Labs (Drew {surname})\n", encoding="utf-8")

    clean_doc = tmp_path / "README.md"
    clean_doc.write_text(
        'BrakerRak fits in a 1U rack with LAB_SUBNET="198.51.100.0/24" and ADMIN_USER="ubuntu".\n',
        encoding="utf-8",
    )

    errors, checked = check_hygiene(tmp_path, [license_file, clean_doc])
    assert checked == 2
    assert errors == []

    leaky = tmp_path / "leaky.md"
    leaky_lines = [
        "down=" + "ada" + "lovespace",
        'exports=["' + "sig" + 'mf", "' + "fi" + 'ts"]',
        "subnet=" + "10.0." + "10.0/24",
        "path=" + "/home/" + "drew/work",
        'ADMIN_' + 'USER="' + "drew" + '"',
        "author=" + surname,
        "host=" + "jake" + "base-vf2",
        "vault1=" + "Big" + "Red",
        "vault2=" + "Lil" + "Blu",
        "typo=" + "Brack" + "erRak",
    ]
    leaky.write_text("\n".join(leaky_lines) + "\n", encoding="utf-8")

    leak_errors, _ = check_hygiene(tmp_path, [leaky])
    assert len(leak_errors) == 11


def test_check_thermal_artifact_pass_and_tamper(tmp_path: Path) -> None:
    art_dir = tmp_path / "artifacts"
    art_dir.mkdir()
    art_file = art_dir / "ctd-thermal-soak-baseline.json"

    base: dict[str, object] = {
        "schema_version": "ctd.thermal.v1",
        "campaign_id": "synthetic-soak-test",
        "ambient_celsius": 22.5,
    }
    signed = dict(base)
    signed["sha256_provenance_digest"] = compute_canonical_sha256(base)
    art_file.write_text(json.dumps(signed, indent=2) + "\n", encoding="utf-8")

    assert check_thermal_artifact(tmp_path) == []

    tampered = dict(signed)
    tampered["ambient_celsius"] = 99.0
    art_file.write_text(json.dumps(tampered, indent=2) + "\n", encoding="utf-8")

    tamper_errors = check_thermal_artifact(tmp_path)
    assert len(tamper_errors) == 1
    assert "canonical SHA-256 mismatch" in tamper_errors[0]
