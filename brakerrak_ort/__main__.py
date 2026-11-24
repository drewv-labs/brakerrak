"""Module entry point for `python3 -m brakerrak_ort`."""

from __future__ import annotations

import sys

from brakerrak_ort.cli import main

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
