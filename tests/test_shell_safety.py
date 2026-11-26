"""Regression tests for shell safety interlocks, exit hooks, and silicon alias parity."""

from __future__ import annotations

import ast
import os
import re
import shlex
import signal
import subprocess
from pathlib import Path

import pytest

from brakerrak_ort.profiles import SOC_ALIASES, detect_soc_from_dt_model, resolve_profile

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_COMMON_SH = REPO_ROOT / "scripts" / "lib-common.sh"
LIB_PROGBAR_SH = REPO_ROOT / "scripts" / "lib-progbar.sh"
RESET_DAY0_SH = REPO_ROOT / "scripts" / "reset-day0.sh"
PROFILES_PY = REPO_ROOT / "brakerrak_ort" / "profiles.py"

# Fallback globs intentionally broader in lib-common.sh than vendor-qualified DT matching in Python.
SHELL_ONLY_DT_FALLBACK_PATTERNS = frozenset(
    {
        '*"starfive"*"mars"*',
        '*"jupiter"*',
        '*"spacemit"*',
    }
)


def _extract_case_block(script_text: str, case_header: str) -> str:
    start = script_text.index(case_header)
    end = script_text.index("esac", start)
    return script_text[start:end]


def _parse_lib_common_cli_aliases() -> dict[str, str]:
    text = LIB_COMMON_SH.read_text(encoding="utf-8")
    cli_block = _extract_case_block(text, 'case "$board_lc" in')
    parsed: dict[str, str] = {}
    pattern = re.compile(r'^\s*([a-z0-9/|_-]+)\)\s*\n\s*board="([^"]+)"', re.MULTILINE)
    for match in pattern.finditer(cli_block):
        aliases_raw, board = match.groups()
        for alias in aliases_raw.split("|"):
            parsed[alias] = board
    assert parsed, "Failed to parse CLI aliases from scripts/lib-common.sh"
    return parsed


def _parse_lib_common_dt_patterns() -> list[tuple[str, str, str]]:
    text = LIB_COMMON_SH.read_text(encoding="utf-8")
    dt_block = _extract_case_block(text, 'case "$dt_lc" in')
    parsed: list[tuple[str, str, str]] = []
    pattern = re.compile(r'^\s*([^\n*]*\*[^\n]+)\)\s*\n\s*board="([^"]+)"', re.MULTILINE)
    for match in pattern.finditer(dt_block):
        pats_raw, board = match.groups()
        for raw_pat in pats_raw.strip().split("|"):
            pat = raw_pat.strip()
            sample = " ".join(pat.replace("*", " ").replace('"', "").split())
            parsed.append((pat, sample, board))
    assert parsed, "Failed to parse DT patterns from scripts/lib-common.sh"
    return parsed


def _extract_python_dt_tokens() -> dict[str, list[str]]:
    tree = ast.parse(PROFILES_PY.read_text(encoding="utf-8"))
    out: dict[str, list[str]] = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "detect_soc_from_dt_model":
            for stmt in node.body:
                if not isinstance(stmt, ast.If) or not stmt.body:
                    continue
                ret = stmt.body[0]
                if not isinstance(ret, ast.Return) or not isinstance(ret.value, ast.Constant):
                    continue
                if not isinstance(ret.value.value, str):
                    continue
                target_slug = ret.value.value
                tokens = [
                    c.value
                    for c in ast.walk(stmt.test)
                    if isinstance(c, ast.Constant) and isinstance(c.value, str)
                ]
                out.setdefault(target_slug, []).extend(tokens)
    assert out, "Failed to extract DT tokens from brakerrak_ort/profiles.py"
    return out


def _isolated_shell_env(tmp_path: Path) -> dict[str, str]:
    tmp_dir = tmp_path / "tmp"
    xdg_dir = tmp_path / "xdg"
    tmp_dir.mkdir(exist_ok=True)
    xdg_dir.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(tmp_dir)
    env["XDG_RUNTIME_DIR"] = str(xdg_dir)
    env["BRAKERRAK_NO_PROGBAR"] = "1"
    env["TERM"] = "dumb"
    return env


def test_cli_alias_parity_between_lib_common_and_profiles() -> None:
    sh_aliases = _parse_lib_common_cli_aliases()

    # Direction 1: Every CLI alias in scripts/lib-common.sh matches resolve_profile() & SOC_ALIASES.
    for alias, sh_slug in sh_aliases.items():
        assert resolve_profile(alias).slug == sh_slug
        assert SOC_ALIASES.get(alias) == sh_slug

    # Direction 2: Exact key-set parity with SOC_ALIASES and live bash brak_resolve_silicon.
    assert set(sh_aliases.keys()) == set(SOC_ALIASES.keys())

    probe_lines = [f"source {shlex.quote(str(LIB_COMMON_SH))}"]
    for alias in sorted(SOC_ALIASES):
        q_alias = shlex.quote(alias)
        q_upper = shlex.quote(alias.upper())
        probe_lines.append(
            f"brak_resolve_silicon {q_alias} && printf '%s=%s\\n' {q_alias} \"$TARGET_BOARD\""
        )
        probe_lines.append(
            f"brak_resolve_silicon {q_upper} && printf '%s=%s\\n' {q_upper} \"$TARGET_BOARD\""
        )

    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", "\n".join(probe_lines)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"brak_resolve_silicon failed:\n{proc.stderr}"

    resolved_map: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        key, val = line.split("=", 1)
        resolved_map[key] = val

    for alias, expected_slug in SOC_ALIASES.items():
        assert resolved_map.get(alias) == expected_slug
        assert resolved_map.get(alias.upper()) == expected_slug


def test_dt_model_substring_parity_between_lib_common_and_profiles() -> None:
    dt_patterns = _parse_lib_common_dt_patterns()

    # Verify every DT pattern in scripts/lib-common.sh resolves in bash and matches Python.
    probe_lines = [f"source {shlex.quote(str(LIB_COMMON_SH))}"]
    for idx, (_, sample, _) in enumerate(dt_patterns):
        probe_lines.append(
            f"brak_resolve_silicon '' {shlex.quote(sample)} && "
            f"printf '%d=%s\\n' {idx} \"$TARGET_BOARD\""
        )

    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", "\n".join(probe_lines)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"brak_resolve_silicon DT resolution failed:\n{proc.stderr}"

    sh_results = dict(line.split("=", 1) for line in proc.stdout.splitlines())
    for idx, (raw_pat, sample, expected_board) in enumerate(dt_patterns):
        assert sh_results.get(str(idx)) == expected_board
        if raw_pat not in SHELL_ONLY_DT_FALLBACK_PATTERNS:
            assert detect_soc_from_dt_model(sample) == expected_board
            assert resolve_profile(None, dt_model=sample).slug == expected_board

    # Reverse direction: every DT token in profiles.py resolves identically in bash.
    py_dt_tokens = _extract_python_dt_tokens()
    rev_lines = [f"source {shlex.quote(str(LIB_COMMON_SH))}"]
    expected_rev: list[tuple[str, str]] = []
    for expected_slug, tokens in py_dt_tokens.items():
        for tok in tokens:
            idx = len(expected_rev)
            expected_rev.append((tok, expected_slug))
            rev_lines.append(
                f"brak_resolve_silicon '' {shlex.quote(tok)} && "
                f"printf '%d=%s\\n' {idx} \"$TARGET_BOARD\""
            )

    rev_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", "\n".join(rev_lines)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert rev_proc.returncode == 0, f"Reverse DT resolution failed:\n{rev_proc.stderr}"

    rev_results = dict(line.split("=", 1) for line in rev_proc.stdout.splitlines())
    for idx, (tok, expected_slug) in enumerate(expected_rev):
        assert rev_results.get(str(idx)) == expected_slug
        assert resolve_profile(None, dt_model=tok).slug == expected_slug


@pytest.mark.parametrize(
    "bad_path",
    [
        "/",
        "/mnt",
        "/mnt/",
        "/srv",
        "/var",
        "/home",
        "/etc",
        "/usr",
        "/root",
        "/boot",
        "/mnt/..",
        "/mnt/pgdata/../../etc",
        "/mnt/ ",
        "mnt/pgdata",
        "",
    ],
)
def test_reset_validate_rm_mountpoint_rejects_unsafe_paths(bad_path: str) -> None:
    script = (
        f"source {shlex.quote(str(RESET_DAY0_SH))}\n"
        f"_reset_validate_rm_mountpoint {shlex.quote(bad_path)}\n"
    )
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode != 0, f"Expected rejection for {bad_path!r}"


@pytest.mark.parametrize(
    "good_path",
    [
        "/mnt/pgdata",
        "/srv/warmvault",
        "/var/lib/brakerrak/pgdata",
    ],
)
def test_reset_validate_rm_mountpoint_accepts_safe_paths(good_path: str) -> None:
    script = (
        f"source {shlex.quote(str(RESET_DAY0_SH))}\n"
        f"_reset_validate_rm_mountpoint {shlex.quote(good_path)}\n"
    )
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"Expected acceptance for {good_path!r}: {proc.stderr}"


def test_exit_hook_cleans_mktemp_and_legacy_tmpfiles_on_normal_exit(tmp_path: Path) -> None:
    env = _isolated_shell_env(tmp_path)
    marker_file = tmp_path / "custom_hook_ran"
    script = f"""
set -euo pipefail
source {shlex.quote(str(LIB_COMMON_SH))}
source {shlex.quote(str(LIB_PROGBAR_SH))}
custom_hook() {{
    printf 'ran\\n' > {shlex.quote(str(marker_file))}
}}
brak_prog_init "normal-exit-test"
brak_register_exit_hook custom_hook

brak_mktemp -v tf_direct
tf_sub="$(brak_mktemp)"
brak_mktemp -d -v td_dir
legacy_tf="$(mktemp "${{TMPDIR}}/legacy.XXXXXX")"
_BRAK_TMPFILES+=("$legacy_tf")

[[ -f "$tf_direct" && -f "$tf_sub" && -d "$td_dir" && -f "$legacy_tf" ]]
printf '%s\\n%s\\n%s\\n%s\\n' "$tf_direct" "$tf_sub" "$td_dir" "$legacy_tf"
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    created_paths = [Path(line) for line in proc.stdout.splitlines() if line.strip()]
    assert len(created_paths) == 4
    assert marker_file.read_text(encoding="utf-8") == "ran\n"
    for p in created_paths:
        assert not p.exists(), f"Expected tempfile {p} to be cleaned up on exit"
    assert not list((tmp_path / "xdg").glob(".brak-tmp-*"))


def test_exit_hook_cleans_mktemp_and_legacy_tmpfiles_on_sigterm(tmp_path: Path) -> None:
    env = _isolated_shell_env(tmp_path)
    paths_file = tmp_path / "paths.txt"
    script = f"""
set -euo pipefail
source {shlex.quote(str(LIB_COMMON_SH))}
source {shlex.quote(str(LIB_PROGBAR_SH))}
brak_prog_init "sigterm-test"

brak_mktemp -v tf_direct
tf_sub="$(brak_mktemp)"
legacy_tf="$(mktemp "${{TMPDIR}}/legacy.XXXXXX")"
_BRAK_TMPFILES+=("$legacy_tf")

printf '%s\\n%s\\n%s\\n' "$tf_direct" "$tf_sub" "$legacy_tf" > {shlex.quote(str(paths_file))}
printf 'READY\\n'
sleep 30 &
wait "$!"
"""
    proc = subprocess.Popen(
        ["bash", "-c", script],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert proc.stdout is not None
        ready = proc.stdout.readline().strip()
        assert ready == "READY"
        created_paths = [
            Path(line) for line in paths_file.read_text(encoding="utf-8").splitlines() if line
        ]
        assert len(created_paths) == 3
        for p in created_paths:
            assert p.exists()

        proc.send_signal(signal.SIGTERM)
        rc = proc.wait(timeout=5)
        assert rc == -signal.SIGTERM
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)

    for p in created_paths:
        assert not p.exists(), f"Expected tempfile {p} to be cleaned up on SIGTERM"
    assert not list((tmp_path / "xdg").glob(".brak-tmp-*"))


def test_parent_tmpfiles_survive_atomic_write_pipeline_and_clean_on_exit(tmp_path: Path) -> None:
    env = _isolated_shell_env(tmp_path)
    target_file = tmp_path / "out" / "node.env"
    script = f"""
set -euo pipefail
source {shlex.quote(str(LIB_COMMON_SH))}
source {shlex.quote(str(LIB_PROGBAR_SH))}
brak_prog_init "pipeline-test"

brak_mktemp -v parent_direct
parent_sub="$(brak_mktemp)"
legacy_tf="$(mktemp "${{TMPDIR}}/legacy.XXXXXX")"
_BRAK_TMPFILES+=("$legacy_tf")

printf 'atomic-payload\\n' | brak_atomic_write {shlex.quote(str(target_file))}

[[ -f "$parent_direct" ]] || {{ echo "parent_direct missing after pipeline" >&2; exit 1; }}
[[ -f "$parent_sub" ]] || {{ echo "parent_sub missing after pipeline" >&2; exit 1; }}
[[ -f "$legacy_tf" ]] || {{ echo "legacy_tf missing after pipeline" >&2; exit 1; }}

printf 'SURVIVED=true\\n'
printf '%s\\n%s\\n%s\\n' "$parent_direct" "$parent_sub" "$legacy_tf"
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    assert lines[0] == "SURVIVED=true"
    parent_paths = [Path(line) for line in lines[1:] if line.strip()]
    assert len(parent_paths) == 3

    assert target_file.read_text(encoding="utf-8") == "atomic-payload\n"
    for p in parent_paths:
        assert not p.exists(), f"Expected parent tempfile {p} to be cleaned up on parent exit"
    assert not list((tmp_path / "xdg").glob(".brak-tmp-*"))


@pytest.mark.parametrize(
    ("role", "expected_tune"),
    [
        ("snitchbench", "iot"),
        ("lilsnitch", "iot"),
        ("devbench", "ai"),
        ("databroker", "data"),
        ("databench", "data"),
        ("visionbench", "ai"),
        ("babbagebox", "ai"),
    ],
)
def test_brak_role_to_rvdk_tune_mappings(role: str, expected_tune: str) -> None:
    script = (
        f"source {shlex.quote(str(LIB_COMMON_SH))}\n"
        f"brak_role_to_rvdk_tune {shlex.quote(role)}\n"
    )
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == expected_tune


def test_brak_resolve_silicon_p4_resolves_espressif_esp32p4_and_tag() -> None:
    script = (
        f"source {shlex.quote(str(LIB_COMMON_SH))}\n"
        "brak_resolve_silicon p4\n"
        'printf "%s|%s|devbench-%s\\n" "$TARGET_BOARD" "$TARGET_TAG" "$TARGET_TAG"\n'
    )
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "espressif-esp32p4|p4|devbench-p4"
