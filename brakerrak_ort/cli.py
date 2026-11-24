"""Command-line interface for the unified BrakerRak ORT & CTD collector."""

from __future__ import annotations

import argparse
from collections.abc import Sequence

from brakerrak_ort.collector import run_ort_collection
from brakerrak_ort.profiles import SOC_PROFILES
from brakerrak_ort.types import SystemProbe


def build_parser() -> argparse.ArgumentParser:
    """Construct the CLI argument parser for brakerrak_ort."""
    soc_list = ", ".join(sorted(SOC_PROFILES.keys()))
    parser = argparse.ArgumentParser(
        prog="brakerrak-ort",
        description="DREW-V Labs Read-Only ORT & CTD Provenance Snapshot Collector",
    )
    parser.add_argument(
        "--soc",
        "--target",
        dest="soc",
        default=None,
        help=f"Target SoC slug or board alias ({soc_list})",
    )
    parser.add_argument(
        "--stage",
        default="day0-pre-forge",
        help="Lifecycle stage tag (e.g., day0-pre-forge, day1-post-forge, converged-idempotent)",
    )
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Directory to write output JSON snapshots (default: ~/.brakerrak/snapshots)",
    )
    parser.add_argument(
        "--config",
        default=None,
        help="Optional explicit path to node.env configuration file",
    )
    parser.add_argument(
        "--window",
        type=float,
        default=5.0,
        help="Quiescent profiling window in seconds (default: 5.0)",
    )
    parser.add_argument(
        "--no-public",
        action="store_true",
        help="Skip generating the redacted .public.json companion manifest",
    )
    parser.add_argument(
        "--no-fail-exit",
        action="store_true",
        help="Exit 0 even when overall_status is FAIL",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress human-readable stdout summary banner",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    probe: SystemProbe | None = None,
) -> int:
    """Execute ORT collection and return 1 on FAIL unless --no-fail-exit is supplied."""
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)

    outputs = run_ort_collection(
        soc=args.soc,
        stage=args.stage,
        out_dir=args.out_dir,
        config_path=args.config,
        window_sec=args.window,
        write_public=not args.no_public,
        quiet=args.quiet,
        probe=probe,
    )
    if outputs.overall_status == "FAIL" and not args.no_fail_exit:
        return 1
    return 0
