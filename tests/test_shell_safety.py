"""Regression tests for shell safety interlocks, exit hooks, and silicon alias parity."""

from __future__ import annotations

import ast
import os
import re
import shlex
import signal
import subprocess
from collections.abc import Sequence
from pathlib import Path

import pytest

from brakerrak_ort.profiles import SOC_ALIASES, detect_soc_from_dt_model, resolve_profile

REPO_ROOT = Path(__file__).resolve().parent.parent
FORGE_SH = REPO_ROOT / "forge.sh"
LIB_COMMON_SH = REPO_ROOT / "scripts" / "lib-common.sh"
LIB_PROGBAR_SH = REPO_ROOT / "scripts" / "lib-progbar.sh"
RESET_DAY0_SH = REPO_ROOT / "scripts" / "reset-day0.sh"
VERIFY_CONVERGENCE_SH = REPO_ROOT / "scripts" / "verify-convergence.sh"
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


def _extract_shell_functions(script_path: Path, fn_names: Sequence[str]) -> str:
    text = script_path.read_text(encoding="utf-8")
    chunks: list[str] = []
    for name in fn_names:
        pattern = re.compile(rf"^{re.escape(name)}\(\)\s*\{{.*?^\}}", re.MULTILINE | re.DOTALL)
        match = pattern.search(text)
        assert match is not None, f"Failed to locate shell function {name}() in {script_path}"
        chunks.append(match.group(0))
    return "\n".join(chunks)


def _extract_verify_destructive_re() -> str:
    text = VERIFY_CONVERGENCE_SH.read_text(encoding="utf-8")
    match = re.search(r"^DESTRUCTIVE_RE=.*$", text, re.MULTILINE)
    assert match is not None, "Failed to locate DESTRUCTIVE_RE in scripts/verify-convergence.sh"
    return match.group(0)


def _extract_forge_storage_case() -> str:
    text = FORGE_SH.read_text(encoding="utf-8")
    start = text.index("    storage)\n")
    end = text.index("    ort)\n", start)
    return 'case "$ACTION" in\n' + text[start:end] + "esac\n"


def _write_executable(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)
    return path


def test_verify_destructive_re_ignores_skip_lines_including_ansi(tmp_path: Path) -> None:
    log_file = tmp_path / "pass2.log"
    log_file.write_text(
        "\n".join(
            [
                "=== [12:00:00] 1. RVDK Day-0 OS ===",
                "[SKIP] Already converged",
                "=== [12:00:01] 2. RVDK Hot NVMe ===",
                "[SKIP] Skipping nvme format /dev/nvme0n1 --lbaf=1 (already 4Kn)",
                "\x1b[1;33m[SKIP]\x1b[0m Skipping mkfs.xfs -s size=4096 /dev/vg_braker/lv_pgdata",
                "  \x1b[1;33m[SKIP]\x1b[0m Skipping mkfs.ext4 on /dev/vg_braker/lv_pgdata",
                "=== [12:00:02] 3. RVDK PostgreSQL 18.6 ===",
                "\x1b[1;33m[SKIP]\x1b[0m Skipping pg_createcluster 18 main\r",
                "[SKIP]: Skipping initdb -D /mnt/nvme_pgdata/pgdata",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    helpers = _extract_shell_functions(
        VERIFY_CONVERGENCE_SH,
        (
            "_verify_strip_ansi_stream",
            "_verify_filter_non_skip_lines",
            "_verify_check_destructive_pass2_log",
        ),
    )
    script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            _extract_verify_destructive_re(),
            helpers,
            f"_verify_check_destructive_pass2_log {shlex.quote(str(log_file))}",
        ]
    )
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        env=_isolated_shell_env(tmp_path),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"Expected [SKIP] lines to be ignored:\n{proc.stderr}"


@pytest.mark.parametrize(
    "bad_line",
    [
        "nvme format /dev/nvme0n1 --lbaf=1 --force",
        "\x1b[1;32m[EXEC]\x1b[0m mkfs.xfs -f /dev/vg_braker/lv_pgdata",
        "Running mkfs.ext4 /dev/vg_braker/lv_pgdata",
        "pg_createcluster 18 main --start",
        "\x1b[1;31m[ERR]\x1b[0m initdb -D /mnt/nvme_pgdata/pgdata",
        "mkfs.xfs /mnt/[SKIP] # trailing skip token must not bypass",
    ],
)
def test_verify_destructive_re_catches_real_destructive_lines(
    tmp_path: Path, bad_line: str
) -> None:
    log_file = tmp_path / "pass2-bad.log"
    log_file.write_text(f"[SKIP] Benign skip\n{bad_line}\n", encoding="utf-8")
    helpers = _extract_shell_functions(
        VERIFY_CONVERGENCE_SH,
        (
            "_verify_strip_ansi_stream",
            "_verify_filter_non_skip_lines",
            "_verify_check_destructive_pass2_log",
        ),
    )
    script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            _extract_verify_destructive_re(),
            helpers,
            f"_verify_check_destructive_pass2_log {shlex.quote(str(log_file))}",
        ]
    )
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        env=_isolated_shell_env(tmp_path),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode != 0, f"Expected failure for destructive line {bad_line!r}"
    assert "Pass 2 must not execute" in proc.stderr


def test_verify_stage_skip_coverage_enforces_expected_stages(tmp_path: Path) -> None:
    helpers = _extract_shell_functions(
        VERIFY_CONVERGENCE_SH,
        ("_verify_strip_ansi_stream", "_verify_assert_stage_skip_coverage"),
    )
    valid_log = tmp_path / "valid.log"
    valid_log.write_text(
        "\n".join(
            [
                "=== [12:00:00] 1. RVDK Day-0 OS ===",
                "\x1b[1;33m[SKIP]\x1b[0m Kernel sysctl already converged",
                "=== [12:00:01] 2. RVDK Hot NVMe ===",
                "[SKIP] NVMe already 4Kn",
                "=== [12:00:02] 3. RVDK PostgreSQL 18.6 ===",
                "[SKIP] PG18 cluster initialized",
                "=== [12:00:03] 4. Btrfs RAID 10 Vault Provisioning Skipped ===",
                "[SKIP] Btrfs RAID 10 disabled",
                "=== [12:00:04] 5A. Mosquitto MQTT Broker Skipped ===",
                "[SKIP] Mosquitto disabled",
                "=== [12:00:05] 5B. NFSv4 Vault Server Skipped ===",
                "[SKIP] NFS disabled",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    ok_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            f'_verify_assert_stage_skip_coverage {shlex.quote(str(valid_log))} '
            '"false" "false" "false" "false"',
            'printf "%s|%s\\n" "$SKIP_MARKER_COUNT" "$STAGE_SKIP_SUMMARY"',
        ]
    )
    ok_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", ok_script],
        env=_isolated_shell_env(tmp_path),
        capture_output=True,
        text=True,
        check=False,
    )
    assert ok_proc.returncode == 0, ok_proc.stderr
    assert ok_proc.stdout.strip() == "6|stages=1:1,2:1,3:1,4:1,5A:1,5B:1"

    # Stage 1 has [SKIP] (total > 0), but Stage 2 & Stage 3 lack [SKIP] markers: MUST fail!
    partial_log = tmp_path / "partial.log"
    partial_log.write_text(
        "\n".join(
            [
                "=== [12:00:00] 1. RVDK Day-0 OS ===",
                "[SKIP] Kernel sysctl already converged",
                "=== [12:00:01] 2. RVDK Hot NVMe ===",
                "[OK] Did something without skip",
                "=== [12:00:02] 3. RVDK PostgreSQL 18.6 ===",
                "[OK] Rebuilt cluster",
                "=== [12:00:03] 4. Btrfs RAID 10 Vault Provisioning Skipped ===",
                "[SKIP] Btrfs RAID 10 disabled",
                "=== [12:00:04] 5A. Mosquitto MQTT Broker Skipped ===",
                "[SKIP] Mosquitto disabled",
                "=== [12:00:05] 5B. NFSv4 Vault Server Skipped ===",
                "[SKIP] NFS disabled",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    fail_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            f'_verify_assert_stage_skip_coverage {shlex.quote(str(partial_log))} '
            '"false" "false" "false" "false"',
        ]
    )
    fail_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", fail_script],
        env=_isolated_shell_env(tmp_path),
        capture_output=True,
        text=True,
        check=False,
    )
    assert fail_proc.returncode != 0
    assert "stage-level [SKIP] coverage" in fail_proc.stderr
    assert "2 3" in fail_proc.stderr

    # Disabled Stage 5A/5B without [SKIP] markers must also fail.
    disabled_miss_log = tmp_path / "disabled-miss.log"
    disabled_miss_log.write_text(
        "\n".join(
            [
                "=== [12:00:00] 1. RVDK Day-0 OS ===",
                "[SKIP] Kernel sysctl already converged",
                "=== [12:00:01] 2. RVDK Hot NVMe ===",
                "[SKIP] NVMe already 4Kn",
                "=== [12:00:02] 3. RVDK PostgreSQL 18.6 ===",
                "[SKIP] PG18 cluster initialized",
                "=== [12:00:03] 4. Btrfs RAID 10 Vault Provisioning Skipped ===",
                "[SKIP] Btrfs RAID 10 disabled",
                "=== [12:00:04] 5A. Mosquitto MQTT Broker Skipped ===",
                "[OK] No skip marker emitted",
                "=== [12:00:05] 5B. NFSv4 Vault Server Skipped ===",
                "[OK] No skip marker emitted",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    miss_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            f'_verify_assert_stage_skip_coverage {shlex.quote(str(disabled_miss_log))} '
            '"false" "false" "false" "false"',
        ]
    )
    miss_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", miss_script],
        env=_isolated_shell_env(tmp_path),
        capture_output=True,
        text=True,
        check=False,
    )
    assert miss_proc.returncode != 0
    assert "5A 5B" in miss_proc.stderr

    # SD target mode allows Stage 1 without [SKIP] when Stages 2..5B all skip cleanly.
    sd_log = tmp_path / "sd.log"
    sd_log.write_text(
        "\n".join(
            [
                "=== [12:00:00] 1. RVDK ESP32-P4 BSP Provenance ===",
                "[OK] BSP converged",
                "=== [12:00:01] 2. NVMe 4Kn LVM Provisioning Skipped ===",
                "[SKIP] SD media target",
                "=== [12:00:02] 3. PostgreSQL 18.6 Convergence Skipped ===",
                "[SKIP] PostgreSQL skipped",
                "=== [12:00:03] 4. Btrfs RAID 10 Vault Provisioning Skipped ===",
                "[SKIP] Btrfs RAID skipped",
                "=== [12:00:04] 5A. Mosquitto MQTT Broker Skipped ===",
                "[SKIP] Mosquitto skipped",
                "=== [12:00:05] 5B. NFSv4 Vault Server Skipped ===",
                "[SKIP] NFSv4 skipped",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    sd_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            f'_verify_assert_stage_skip_coverage {shlex.quote(str(sd_log))} '
            '"true" "false" "false" "false"',
            'printf "%s\\n" "$STAGE_SKIP_SUMMARY"',
        ]
    )
    sd_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", sd_script],
        env=_isolated_shell_env(tmp_path),
        capture_output=True,
        text=True,
        check=False,
    )
    assert sd_proc.returncode == 0, sd_proc.stderr
    assert sd_proc.stdout.strip() == "stages=1:0,2:1,3:1,4:1,5A:1,5B:1"


def _extract_forge_rvdk_startup() -> str:
    text = FORGE_SH.read_text(encoding="utf-8")
    start = text.index('_BRAK_RVDK_BIN_EXPLICIT="false"\n')
    end = text.index("\n_brak_resolve_rvdk_cmd()", start)
    return text[start:end]


def test_forge_storage_missing_rvdk_bin_guard_and_dispatch(tmp_path: Path) -> None:
    rvdk_startup = _extract_forge_rvdk_startup()
    helpers = _extract_shell_functions(FORGE_SH, ("_brak_resolve_rvdk_cmd",))
    storage_case = _extract_forge_storage_case()
    node_env = tmp_path / "node.env"
    node_env.write_text(
        'VG_NAME="vg_braker"\nLV_NAME="lv_pgdata"\nNFS_LV_NAME="lv_nfsvault"\n',
        encoding="utf-8",
    )

    path_rvdk_calls = tmp_path / "path_rvdk.calls"
    path_bin = tmp_path / "path_bin"
    _write_executable(
        path_bin / "rvdk",
        (
            "#!/usr/bin/env bash\n"
            f'printf "PATH_DISPATCH:%s\\n" "$*" >> {shlex.quote(str(path_rvdk_calls))}\n'
            'printf "PATH_DISPATCH:%s\\n" "$*"\n'
        ),
    )

    # Case 1: Explicit non-executable RVDK_BIN must fail fast even when `rvdk` exists on PATH
    fail_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            rvdk_startup,
            helpers,
            f"NODE_ENV={shlex.quote(str(node_env))}",
            'ACTION="storage"',
            'set -- "status"',
            storage_case,
        ]
    )
    env_missing = _isolated_shell_env(tmp_path)
    env_missing["RVDK_BIN"] = "/nonexistent/rvdk"
    env_missing["PATH"] = f"{path_bin}:{env_missing.get('PATH', '/usr/bin:/bin')}"
    fail_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", fail_script],
        env=env_missing,
        capture_output=True,
        text=True,
        check=False,
    )
    assert fail_proc.returncode != 0
    assert "RVDK CLI not found at '/nonexistent/rvdk'" in fail_proc.stderr
    assert not path_rvdk_calls.exists()

    # Case 2: Unset RVDK_BIN falls back cleanly to `rvdk` on PATH when system bins are absent
    env_path_fallback = _isolated_shell_env(tmp_path)
    env_path_fallback.pop("RVDK_BIN", None)
    env_path_fallback["PATH"] = f"{path_bin}:{env_path_fallback.get('PATH', '/usr/bin:/bin')}"
    path_ok_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", fail_script],
        env=env_path_fallback,
        capture_output=True,
        text=True,
        check=False,
    )
    if not Path("/usr/local/bin/rvdk").exists() and not Path("/usr/bin/rvdk").exists():
        assert path_ok_proc.returncode == 0, path_ok_proc.stderr
        assert path_ok_proc.stdout.strip() == "PATH_DISPATCH:storage status"

    # Case 3: Valid explicit RVDK_BIN resolves and dispatches storage subcommands cleanly
    mock_rvdk = _write_executable(
        tmp_path / "bin" / "rvdk",
        '#!/usr/bin/env bash\nprintf "DISPATCH:%s\\n" "$*"\n',
    )
    for sub_args, expected in [
        (["grow-psql", "--gb", "10"], "DISPATCH:storage grow --lv lv_pgdata --gb 10"),
        (["grow-nfs", "--gb", "20"], "DISPATCH:storage grow --lv lv_nfsvault --gb 20"),
        (["shrink-nfs", "--gb", "5"], "DISPATCH:storage shrink --lv lv_nfsvault --gb 5"),
        (["status"], "DISPATCH:storage status"),
    ]:
        ok_script = "\n".join(
            [
                f"source {shlex.quote(str(LIB_COMMON_SH))}",
                rvdk_startup,
                helpers,
                f"NODE_ENV={shlex.quote(str(node_env))}",
                'ACTION="storage"',
                "set -- " + " ".join(shlex.quote(a) for a in sub_args),
                storage_case,
            ]
        )
        ok_env = _isolated_shell_env(tmp_path)
        ok_env["RVDK_BIN"] = str(mock_rvdk)
        ok_proc = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", ok_script],
            env=ok_env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert ok_proc.returncode == 0, ok_proc.stderr
        assert ok_proc.stdout.strip() == expected


@pytest.mark.parametrize(
    ("target_board", "fstype", "proc_fs_content", "should_pass"),
    [
        ("starfive-jh7110", "xfs", "nodev\tsysfs\n\text4\n\txfs\n", True),
        ("starfive-jh7110", "ext4", "nodev\tsysfs\n\text4\n\txfs\n", True),
        ("starfive-jh7110", "btrfs", "nodev\tsysfs\n\text4\n\txfs\n", False),
        ("eswin-eic7700x", "xfs", "nodev\tsysfs\n\text4\n\txfs\n", True),
        ("eswin-eic7700x", "ext4", "nodev\tsysfs\n\text4\n\txfs\n", False),
        ("eswin-eic7700x", "ext4", "nodev\tsysfs\n\text4\n", True),
    ],
)
def test_verify_get_data_fs_uuid_jh7110_and_proc_filesystems(
    tmp_path: Path,
    target_board: str,
    fstype: str,
    proc_fs_content: str,
    should_pass: bool,
) -> None:
    verify_text = VERIFY_CONVERGENCE_SH.read_text(encoding="utf-8")
    assert "_verify_get_xfs_uuid" not in verify_text
    assert "_verify_get_data_fs_uuid" in verify_text

    mock_bin = tmp_path / "bin"
    _write_executable(
        mock_bin / "findmnt",
        (
            "#!/usr/bin/env bash\n"
            'case "$3" in\n'
            f'  FSTYPE) printf "{fstype}\\n" ;;\n'
            '  SOURCE) printf "/dev/vg_braker/lv_pgdata\\n" ;;\n'
            '  UUID)   printf "11111111-2222-3333-4444-555555555555\\n" ;;\n'
            "esac\n"
        ),
    )
    proc_fs = tmp_path / "proc_filesystems"
    proc_fs.write_text(proc_fs_content, encoding="utf-8")

    helpers = _extract_shell_functions(
        VERIFY_CONVERGENCE_SH,
        (
            "_verify_kernel_has_xfs",
            "_verify_allows_ext4_data_fs",
            "_verify_get_data_fs_uuid",
        ),
    )
    script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            f"TARGET_BOARD={shlex.quote(target_board)}",
            f"PROC_FILESYSTEMS_PATH={shlex.quote(str(proc_fs))}",
            '_verify_get_data_fs_uuid "/mnt/nvme_pgdata"',
        ]
    )
    env = _isolated_shell_env(tmp_path)
    env["PATH"] = f"{mock_bin}:{env.get('PATH', '/usr/bin:/bin')}"
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if should_pass:
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "11111111-2222-3333-4444-555555555555"
    else:
        assert proc.returncode != 0
        assert "Convergence assertion FAILED" in proc.stderr


@pytest.mark.parametrize(
    ("role", "enable_pg", "enable_nfs", "nvme_dev", "expected_skip"),
    [
        ("visionbox", "false", "false", "/dev/nonexistent-nvme0n1", True),
        ("visionbench", "false", "false", "/dev/nonexistent-nvme0n1", True),
        ("babbagebox", "false", "false", "/dev/nonexistent-nvme0n1", True),
        ("babbagebench", "false", "false", "/dev/nonexistent-nvme0n1", True),
        ("vh", "false", "false", "/dev/nonexistent-nvme0n1", True),
        ("bab", "false", "false", "/dev/nonexistent-nvme0n1", True),
        ("VisionBench", "false", "false", "/dev/nonexistent-nvme0n1", True),
        ("visionbox", "true", "false", "/dev/nonexistent-nvme0n1", False),
        ("visionbench", "false", "true", "/dev/nonexistent-nvme0n1", False),
        ("databench", "false", "false", "/dev/nonexistent-nvme0n1", False),
        ("databroker", "false", "false", "/dev/nonexistent-nvme0n1", False),
        ("devbench", "false", "false", "/dev/nonexistent-nvme0n1", False),
    ],
)
def test_accel_nvme_skip_parity_between_forge_and_verify(
    tmp_path: Path,
    role: str,
    enable_pg: str,
    enable_nfs: str,
    nvme_dev: str,
    expected_skip: bool,
) -> None:
    forge_helpers = _extract_shell_functions(
        FORGE_SH, ("_brak_is_accel_persona", "_brak_should_skip_accel_nvme")
    )
    verify_helpers = _extract_shell_functions(
        VERIFY_CONVERGENCE_SH,
        (
            "_verify_is_accel_persona",
            "_verify_is_accel_nvme_skip",
            "_verify_refresh_node_vars",
        ),
    )
    node_env = tmp_path / "node.env"
    node_env.write_text(
        "\n".join(
            [
                f'NODE_ROLE="{role}"',
                f'ENABLE_POSTGRES="{enable_pg}"',
                f'ENABLE_NFS_SERVER="{enable_nfs}"',
                f'NVME_DEV="{nvme_dev}"',
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            forge_helpers,
            verify_helpers,
            f"NODE_ENV={shlex.quote(str(node_env))}",
            'CLI_ROLE="" CLI_TARGET="" CLI_MOUNT_POINT="" CLI_NVME_DEV=""',
            'CLI_ENABLE_PG="" CLI_ENABLE_NFS="" CLI_ENABLE_MQTT="" CLI_WITH_RAID=""',
            'CLI_MEDIA="" CLI_STAGE_DIR=""',
            "_verify_refresh_node_vars",
            'f_skip="false"; _brak_should_skip_accel_nvme "$NODE_ROLE" && f_skip="true"',
            'v_skip="false"; _verify_is_accel_nvme_skip && v_skip="true"',
            'alias_skip="false"; _brak_should_skip_accel_nvme '
            f"{shlex.quote(role)} && alias_skip=\"true\"",
            'printf "%s|%s|%s\\n" "$f_skip" "$v_skip" "$alias_skip"',
        ]
    )
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        env=_isolated_shell_env(tmp_path),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    expected_str = "true|true|true" if expected_skip else "false|false|false"
    assert proc.stdout.strip() == expected_str


def test_forge_deeptune_board_slug_parameterization_and_graceful_skip(tmp_path: Path) -> None:
    rvdk_engine = tmp_path / "rvdk-engine"
    _write_executable(
        rvdk_engine / "bsp" / "espressif" / "esp32p4" / "deeptune.sh",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    _write_executable(
        rvdk_engine / "boards" / "waveshare" / "esp32-p4-wifi6" / "deeptune.sh",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    _write_executable(
        rvdk_engine / "boards" / "acme" / "esp32-p4-custom" / "deeptune.sh",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    rvdk_log = tmp_path / "rvdk.calls"
    mock_rvdk = _write_executable(
        rvdk_engine / "rvdk",
        (
            "#!/usr/bin/env bash\n"
            f'printf "%s\\n" "$*" >> {shlex.quote(str(rvdk_log))}\n'
        ),
    )

    stage_dir = tmp_path / "p4-sd"
    (stage_dir / "config").mkdir(parents=True)
    (stage_dir / "config" / "node.env").write_text(
        'NODE_ROLE="lilsnitch"\nRVDK_TUNE_PROFILE="iot"\n',
        encoding="utf-8",
    )

    base_env = _isolated_shell_env(tmp_path)
    base_env["RVDK_BIN"] = str(mock_rvdk)
    base_env["RVDK_ENGINE_DIR"] = str(rvdk_engine)

    # 1. Default BOARD_SLUG -> waveshare/esp32-p4-wifi6
    p1 = subprocess.run(
        ["bash", str(FORGE_SH), "deeptune", "--target", "p4", "--stage-dir", str(stage_dir)],
        env=base_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert p1.returncode == 0, p1.stderr
    calls_1 = rvdk_log.read_text(encoding="utf-8").splitlines()
    assert calls_1 == [
        f"bsp/espressif/esp32p4/deeptune.sh --tune iot --stage-dir {stage_dir}",
        f"boards/waveshare/esp32-p4-wifi6/deeptune.sh --tune iot --stage-dir {stage_dir}",
    ]

    # 2. Custom BOARD_SLUG -> acme/esp32-p4-custom (status subcommand)
    rvdk_log.unlink()
    custom_env = dict(base_env)
    custom_env["BOARD_SLUG"] = "acme/esp32-p4-custom"
    p2 = subprocess.run(
        [
            "bash",
            str(FORGE_SH),
            "deeptune",
            "--target",
            "p4",
            "--stage-dir",
            str(stage_dir),
            "status",
        ],
        env=custom_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert p2.returncode == 0, p2.stderr
    calls_2 = rvdk_log.read_text(encoding="utf-8").splitlines()
    assert calls_2 == [
        f"bsp/espressif/esp32p4/deeptune.sh status --stage-dir {stage_dir}",
        f"boards/acme/esp32-p4-custom/deeptune.sh status --stage-dir {stage_dir}",
    ]

    # 3. Missing board script in RVDK -> skips gracefully with [SKIP] and exit 0
    rvdk_log.unlink()
    missing_env = dict(base_env)
    missing_env["BOARD_SLUG"] = "acme/nonexistent-p4"
    p3 = subprocess.run(
        ["bash", str(FORGE_SH), "deeptune", "--target", "p4", "--stage-dir", str(stage_dir)],
        env=missing_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert p3.returncode == 0, p3.stderr
    assert "[SKIP]" in p3.stdout
    assert "boards/acme/nonexistent-p4/deeptune.sh" in p3.stdout
    assert rvdk_log.read_text(encoding="utf-8").splitlines() == [
        f"bsp/espressif/esp32p4/deeptune.sh --tune iot --stage-dir {stage_dir}",
    ]

    # 4. Path-traversal BOARD_SLUG -> fails fast
    bad_env = dict(base_env)
    bad_env["BOARD_SLUG"] = "../etc/passwd"
    p4 = subprocess.run(
        ["bash", str(FORGE_SH), "deeptune", "--target", "p4", "--stage-dir", str(stage_dir)],
        env=bad_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert p4.returncode != 0
    assert "Invalid BOARD_SLUG" in p4.stderr

    # 5. Stage 5D inside forge --stage-dir --deeptune honors BOARD_SLUG and skips gracefully
    _write_executable(
        rvdk_engine / "bsp" / "espressif" / "esp32p4" / "forge.sh",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    rvdk_log.unlink()
    stage5d_proc = subprocess.run(
        [
            "bash",
            str(FORGE_SH),
            "forge",
            "--target",
            "p4",
            "--role",
            "lilsnitch",
            "--stage-dir",
            str(stage_dir),
            "--deeptune",
        ],
        env=missing_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert stage5d_proc.returncode == 0, stage5d_proc.stderr
    assert "[SKIP]" in stage5d_proc.stdout
    assert "boards/acme/nonexistent-p4/deeptune.sh" in stage5d_proc.stdout
    assert rvdk_log.read_text(encoding="utf-8").splitlines() == [
        f"bsp/espressif/esp32p4/forge.sh --stage-dir {stage_dir}",
        f"bsp/espressif/esp32p4/deeptune.sh --tune iot --stage-dir {stage_dir}",
    ]


def test_forge_rvdk_delegation_deprecation_and_compat_gating(tmp_path: Path) -> None:
    helpers = _extract_shell_functions(
        FORGE_SH,
        (
            "_brak_resolve_rvdk_cmd",
            "_brak_resolve_rvdk_engine_dir",
            "_brak_has_rvdk_script",
            "_brak_legacy_compat_allowed",
            "_brak_service_active_or_enabled",
            "_brak_reclaim_hugepages_compat",
            "_brak_disable_hugepages",
            "_brak_disable_postgresql",
            "_brak_disable_mosquitto",
            "_brak_disable_nfs_server",
        ),
    )

    # 1. When RVDK supports --disable hooks, delegate cleanly with zero DEPRECATED warnings
    mock_bin_deleg = tmp_path / "bin_deleg"
    sys_calls_deleg = tmp_path / "sys_deleg.calls"
    _write_executable(
        mock_bin_deleg / "systemctl",
        (
            "#!/usr/bin/env bash\n"
            f'printf "%s\\n" "$*" >> {shlex.quote(str(sys_calls_deleg))}\n'
            "exit 0\n"
        ),
    )
    rvdk_calls_deleg = tmp_path / "rvdk_deleg.calls"
    mock_rvdk_deleg = _write_executable(
        tmp_path / "rvdk_deleg",
        (
            "#!/usr/bin/env bash\n"
            'if [[ "${2:-}" == "--help" ]]; then\n'
            '  printf "Usage: rvdk %s [--disable]\\n" "$1"\n'
            "  exit 0\n"
            "fi\n"
            f'printf "%s\\n" "$*" >> {shlex.quote(str(rvdk_calls_deleg))}\n'
        ),
    )
    deleg_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            'ACTION="forge"',
            'BRAKERRAK_LEGACY_RVDK_COMPAT="true"',
            'NODE_ROLE="visionbench"',
            f"RVDK_BIN={shlex.quote(str(mock_rvdk_deleg))}",
            "_brak_disable_postgresql",
            "_brak_disable_mosquitto",
            "_brak_disable_nfs_server",
        ]
    )
    deleg_env = _isolated_shell_env(tmp_path)
    deleg_env["PATH"] = f"{mock_bin_deleg}:{deleg_env.get('PATH', '/usr/bin:/bin')}"
    deleg_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", deleg_script],
        env=deleg_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert deleg_proc.returncode == 0, deleg_proc.stderr
    assert "DEPRECATED:" not in deleg_proc.stderr
    assert not sys_calls_deleg.exists()
    assert rvdk_calls_deleg.read_text(encoding="utf-8").splitlines() == [
        "postgresql --disable",
        "mods/mosquitto --disable",
        "mods/nfs-vault --disable",
    ]

    # 2. When RVDK lacks --disable hooks & service is active:
    #    - COMPAT=true emits DEPRECATED warning and calls systemctl disable --now
    #    - COMPAT=false fails fast before mutating systemctl
    mock_rvdk_legacy = _write_executable(
        tmp_path / "rvdk_legacy",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    sys_calls_legacy = tmp_path / "sys_legacy.calls"
    mock_bin_legacy = tmp_path / "bin_legacy"
    _write_executable(
        mock_bin_legacy / "systemctl",
        (
            "#!/usr/bin/env bash\n"
            'if [[ "$1" == "is-active" || "$1" == "is-enabled" ]]; then exit 0; fi\n'
            f'printf "%s\\n" "$*" >> {shlex.quote(str(sys_calls_legacy))}\n'
        ),
    )

    compat_env = _isolated_shell_env(tmp_path)
    compat_env["PATH"] = f"{mock_bin_legacy}:{compat_env.get('PATH', '/usr/bin:/bin')}"

    compat_on_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            'ACTION="forge"',
            'BRAKERRAK_LEGACY_RVDK_COMPAT="true"',
            'NODE_ROLE="visionbench"',
            f"RVDK_BIN={shlex.quote(str(mock_rvdk_legacy))}",
            "_brak_disable_mosquitto",
        ]
    )
    compat_on_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", compat_on_script],
        env=compat_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert compat_on_proc.returncode == 0, compat_on_proc.stderr
    assert "DEPRECATED:" in compat_on_proc.stderr
    assert sys_calls_legacy.read_text(encoding="utf-8").splitlines() == [
        "disable --now mosquitto.service",
    ]

    sys_calls_legacy.unlink()
    compat_off_script = "\n".join(
        [
            f"source {shlex.quote(str(LIB_COMMON_SH))}",
            helpers,
            'ACTION="forge"',
            'BRAKERRAK_LEGACY_RVDK_COMPAT="false"',
            'NODE_ROLE="visionbench"',
            f"RVDK_BIN={shlex.quote(str(mock_rvdk_legacy))}",
            "_brak_disable_mosquitto",
        ]
    )
    compat_off_proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", compat_off_script],
        env=compat_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert compat_off_proc.returncode != 0
    assert "BRAKERRAK_LEGACY_RVDK_COMPAT=false" in compat_off_proc.stderr
    assert not sys_calls_legacy.exists()
