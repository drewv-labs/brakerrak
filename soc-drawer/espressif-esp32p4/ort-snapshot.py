#!/usr/bin/env python3
"""Thin CLI shim delegating espressif-esp32p4 ORT collection to brakerrak_ort."""

from __future__ import annotations

import sys
from pathlib import Path


def _main() -> int:
    repo_root = str(Path(__file__).resolve().parents[2])
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    from brakerrak_ort.cli import main

    argv = sys.argv[1:]
    has_soc = any(a in ("--soc", "--target") or a.startswith(("--soc=", "--target=")) for a in argv)
    return main(argv if has_soc else ["--soc", "espressif-esp32p4", *argv])


if __name__ == "__main__":
    raise SystemExit(_main())
