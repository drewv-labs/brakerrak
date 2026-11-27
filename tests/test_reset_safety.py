"""Regression tests for scripts/reset-day0.sh safety interlocks and hardening."""

from __future__ import annotations

import os
import re
import shlex
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
RESET_DAY0_SH = REPO_ROOT / "scripts" / "reset-day0.sh"


def _isolated_env(tmp_path: Path, extra_path: Path | None = None) -> dict[str, str]:
    tmp_dir = tmp_path / "tmp"
    xdg_dir = tmp_path / "xdg"
    tmp_dir.mkdir(exist_ok=True)
    xdg_dir.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(tmp_dir)
    env["XDG_RUNTIME_DIR"] = str(xdg_dir)
    env["BRAKERRAK_NO_PROGBAR"] = "1"
    env["BRAKERRAK_UMOUNT_RETRY_SLEEP"] = "0.01"
    env["TERM"] = "dumb"
    if extra_path is not None:
        env["PATH"] = f"{extra_path}:{env.get('PATH', '/usr/bin:/bin')}"
    return env


def _write_exec(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)
    return path


def _run_bash(
    script: str,
    env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_nvme_wipe_candidates_excludes_other_namespaces_and_non_numeric_suffixes(
    tmp_path: Path,
) -> None:
    dev_dir = tmp_path / "dev"
    dev_dir.mkdir()
    for name in (
        "nvme0n1",
        "nvme0n1p1",
        "nvme0n1p2",
        "nvme0n1p10",
        "nvme0n10",
        "nvme0n10p1",
        "nvme0n1p1extra",
        "nvme0n2",
    ):
        (dev_dir / name).touch()

    target_dev = dev_dir / "nvme0n1"
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_device_is_protected() {{ return 1; }}
_reset_nvme_wipe_candidates {shlex.quote(str(target_dev))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path))
    assert proc.returncode == 0, proc.stderr

    candidates = [line for line in proc.stdout.splitlines() if line.strip()]
    assert set(candidates) == {
        str(dev_dir / "nvme0n1"),
        str(dev_dir / "nvme0n1p1"),
        str(dev_dir / "nvme0n1p2"),
        str(dev_dir / "nvme0n1p10"),
    }
    assert str(dev_dir / "nvme0n10") not in candidates
    assert str(dev_dir / "nvme0n10p1") not in candidates
    assert str(dev_dir / "nvme0n1p1extra") not in candidates
    assert str(dev_dir / "nvme0n2") not in candidates


def test_nvme_wipe_candidates_filters_protected_devices_and_restores_nullglob(
    tmp_path: Path,
) -> None:
    dev_dir = tmp_path / "dev"
    dev_dir.mkdir()
    for name in ("nvme0n1", "nvme0n1p1", "nvme0n1p2", "nvme0n10"):
        (dev_dir / name).touch()

    target_dev = dev_dir / "nvme0n1"
    protected_part = dev_dir / "nvme0n1p2"
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_device_is_protected() {{
    [[ "$1" == {shlex.quote(str(protected_part))} ]]
}}
shopt -u nullglob
_reset_nvme_wipe_candidates {shlex.quote(str(target_dev))}
if shopt -q nullglob; then
    echo "LEAKED_NULLGLOB" >&2
    exit 91
fi
"""
    proc = _run_bash(script, _isolated_env(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "LEAKED_NULLGLOB" not in proc.stderr

    candidates = [line for line in proc.stdout.splitlines() if line.strip()]
    assert candidates == [str(dev_dir / "nvme0n1"), str(dev_dir / "nvme0n1p1")]
    assert str(protected_part) not in candidates
    assert "excluding protected block device" in proc.stderr


def test_nvme_wipe_candidates_handles_no_partitions_and_rejects_regular_files_by_default(
    tmp_path: Path,
) -> None:
    dev_dir = tmp_path / "dev"
    dev_dir.mkdir()
    target_dev = dev_dir / "nvme0n1"
    target_dev.touch()

    # With _reset_is_block_device mocked, only the whole disk is returned (no literal p[0-9]*).
    script_mock = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_device_is_protected() {{ return 1; }}
_reset_nvme_wipe_candidates {shlex.quote(str(target_dev))}
"""
    proc_mock = _run_bash(script_mock, _isolated_env(tmp_path))
    assert proc_mock.returncode == 0, proc_mock.stderr
    assert proc_mock.stdout.splitlines() == [str(target_dev)]

    # Without mocking _reset_is_block_device, a non-block regular file is never yielded.
    script_default = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_nvme_wipe_candidates {shlex.quote(str(target_dev))}
"""
    proc_default = _run_bash(script_default, _isolated_env(tmp_path))
    assert proc_default.returncode == 0, proc_default.stderr
    assert proc_default.stdout.strip() == ""


def test_wipe_nvme_targets_only_touches_unprotected_candidates(tmp_path: Path) -> None:
    dev_dir = tmp_path / "dev"
    dev_dir.mkdir()
    for name in ("nvme0n1", "nvme0n1p1", "nvme0n1p2", "nvme0n10", "nvme0n10p1"):
        (dev_dir / name).touch()

    bin_dir = tmp_path / "bin"
    log_file = tmp_path / "wipe.log"
    _write_exec(
        bin_dir / "pvremove",
        f'#!/usr/bin/env bash\nprintf "pvremove:%s\\n" "$*" >> {shlex.quote(str(log_file))}\n',
    )
    _write_exec(
        bin_dir / "wipefs",
        f'#!/usr/bin/env bash\nprintf "wipefs:%s\\n" "$*" >> {shlex.quote(str(log_file))}\n',
    )

    target_dev = dev_dir / "nvme0n1"
    protected_part = dev_dir / "nvme0n1p2"
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_device_is_protected() {{
    [[ "$1" == {shlex.quote(str(protected_part))} ]]
}}
_reset_dev_is_mounted() {{ return 1; }}
_reset_wipe_nvme_targets {shlex.quote(str(target_dev))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode == 0, proc.stderr

    log_lines = log_file.read_text(encoding="utf-8").splitlines()
    assert f"pvremove:-ff -y {dev_dir / 'nvme0n1'}" in log_lines
    assert f"pvremove:-ff -y {dev_dir / 'nvme0n1p1'}" in log_lines
    wipefs_lines = [line for line in log_lines if line.startswith("wipefs:")]
    assert wipefs_lines == [
        f"wipefs:-af {dev_dir / 'nvme0n1p1'}",
        f"wipefs:-af {dev_dir / 'nvme0n1'}",
    ]
    joined = "\n".join(log_lines)
    assert "nvme0n10" not in joined
    assert "nvme0n1p2" not in joined


def test_no_lazy_umount_in_reset_day0_script() -> None:
    text = RESET_DAY0_SH.read_text(encoding="utf-8")
    assert not re.search(r"\bumount\b[^\n]*\s-(?:[a-zA-Z]*l[a-zA-Z]*|-lazy)\b", text)
    assert "umount -l" not in text
    assert "--lazy" not in text


def test_strict_umount_prints_fuser_holders_and_fails_fast_without_lazy_fallback(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    umount_log = tmp_path / "umount.log"
    _write_exec(
        bin_dir / "umount",
        f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {shlex.quote(str(umount_log))}
echo "umount: $1: target is busy." >&2
exit 32
""",
    )
    _write_exec(
        bin_dir / "fuser",
        """#!/usr/bin/env bash
if [[ "${1:-}" == "-vm" ]]; then
    echo "                     USER        PID ACCESS COMMAND" >&2
    echo "/mnt/nvme_pgdata:    postgres   4242 ..c.. postgres"
    exit 0
fi
exit 1
""",
    )

    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_strict_umount "/mnt/nvme_pgdata"
echo "SHOULD_NOT_REACH_DESTRUCTIVE_STEP"
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode != 0
    assert "SHOULD_NOT_REACH_DESTRUCTIVE_STEP" not in proc.stdout
    assert "Active holders on '/mnt/nvme_pgdata'" in proc.stderr
    assert "4242" in proc.stderr
    assert "Safety Interlock: failed to unmount '/mnt/nvme_pgdata'" in proc.stderr

    calls = umount_log.read_text(encoding="utf-8").splitlines()
    assert calls == ["/mnt/nvme_pgdata"] * 5
    assert all("-l" not in c and "--lazy" not in c for c in calls)


def test_strict_umount_fails_fast_even_when_fuser_unavailable(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in (
        "awk",
        "basename",
        "bash",
        "cat",
        "chmod",
        "dirname",
        "mkdir",
        "mktemp",
        "mv",
        "rm",
        "tr",
    ):
        found = shutil.which(tool)
        if found is not None:
            (bin_dir / tool).symlink_to(found)
    _write_exec(
        bin_dir / "umount",
        '#!/usr/bin/env bash\necho "target is busy" >&2\nexit 1\n',
    )

    env = _isolated_env(tmp_path)
    env["PATH"] = str(bin_dir)
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_strict_umount "/mnt/nvme_pgdata"
"""
    proc = _run_bash(script, env)
    assert proc.returncode != 0
    assert "Safety Interlock: failed to unmount '/mnt/nvme_pgdata'" in proc.stderr


def test_wipe_nvme_targets_aborts_before_pvremove_or_wipefs_if_partition_busy(
    tmp_path: Path,
) -> None:
    dev_dir = tmp_path / "dev"
    dev_dir.mkdir()
    (dev_dir / "nvme0n1").touch()
    (dev_dir / "nvme0n1p1").touch()

    bin_dir = tmp_path / "bin"
    destructive_marker = tmp_path / "wipe_executed"
    _write_exec(
        bin_dir / "umount",
        '#!/usr/bin/env bash\necho "partition mounted and busy" >&2\nexit 32\n',
    )
    _write_exec(
        bin_dir / "fuser",
        '#!/usr/bin/env bash\n[[ "${1:-}" == "-vm" ]] && echo "holder 7788" >&2\nexit 0\n',
    )
    for cmd in ("pvremove", "wipefs"):
        _write_exec(
            bin_dir / cmd,
            f'#!/usr/bin/env bash\ntouch {shlex.quote(str(destructive_marker))}\n',
        )

    target_dev = dev_dir / "nvme0n1"
    part_dev = dev_dir / "nvme0n1p1"
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_device_is_protected() {{ return 1; }}
_reset_dev_is_mounted() {{ [[ "$1" == {shlex.quote(str(part_dev))} ]]; }}
_reset_wipe_nvme_targets {shlex.quote(str(target_dev))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode != 0
    assert "7788" in proc.stderr
    assert "Safety Interlock: failed to unmount" in proc.stderr
    assert not destructive_marker.exists()


def test_unmount_vg_devices_aborts_before_vgremove_and_nvme_format_when_busy(
    tmp_path: Path,
) -> None:
    mapper_dir = tmp_path / "dev" / "mapper"
    vg_dir = tmp_path / "dev" / "vg_braker"
    mapper_dir.mkdir(parents=True)
    vg_dir.mkdir(parents=True)
    dm_node = mapper_dir / "vg_braker-lv_pgdata"
    dm_node.touch()

    bin_dir = tmp_path / "bin"
    destructive_marker = tmp_path / "destructive_ran"
    _write_exec(
        bin_dir / "findmnt",
        """#!/usr/bin/env bash
echo "/mnt/nvme_pgdata"
""",
    )
    _write_exec(
        bin_dir / "fuser",
        """#!/usr/bin/env bash
if [[ "${1:-}" == "-vm" ]]; then
    echo "busyholder 9911 postgres" >&2
    exit 0
fi
exit 1
""",
    )
    _write_exec(
        bin_dir / "umount",
        '#!/usr/bin/env bash\necho "device is busy" >&2\nexit 32\n',
    )
    for cmd in ("vgremove", "wipefs", "nvme"):
        _write_exec(
            bin_dir / cmd,
            f'#!/usr/bin/env bash\ntouch {shlex.quote(str(destructive_marker))}\n',
        )

    dev_dir = tmp_path / "dev"
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_unmount_vg_devices \\
    "vg_braker" {shlex.quote(str(mapper_dir))} {shlex.quote(str(dev_dir))}
vgremove -ff -y vg_braker
wipefs -af /dev/nvme0n1
nvme format /dev/nvme0n1 -l 0 --force
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode != 0
    assert "9911" in proc.stderr
    assert "Safety Interlock: failed to unmount" in proc.stderr
    assert not destructive_marker.exists()


def test_unmount_vg_devices_skips_unmounted_lvs_cleanly(tmp_path: Path) -> None:
    mapper_dir = tmp_path / "dev" / "mapper"
    vg_dir = tmp_path / "dev" / "vg_braker"
    mapper_dir.mkdir(parents=True)
    vg_dir.mkdir(parents=True)
    (mapper_dir / "vg_braker-lv_pgdata").touch()

    bin_dir = tmp_path / "bin"
    _write_exec(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 1\n")
    _write_exec(bin_dir / "umount", "#!/usr/bin/env bash\nexit 99\n")

    dev_dir = tmp_path / "dev"
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_unmount_vg_devices \\
    "vg_braker" {shlex.quote(str(mapper_dir))} {shlex.quote(str(dev_dir))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode == 0, proc.stderr


@pytest.mark.parametrize(
    "bad_hostname",
    [
        "a/b",
        "a&b",
        "../etc",
        "-bad",
        "bad-",
        "",
        "a" * 64,
        "bad host",
        "bad.domain",
        "bad_host",
        r"bad\1",
        "bad\nhost",
        "bad;id",
        "-",
    ],
)
def test_validate_hostname_and_cli_fail_fast_on_malformed_inputs(
    tmp_path: Path,
    bad_hostname: str,
) -> None:
    # 1. Direct validator check
    val_script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_validate_hostname {shlex.quote(bad_hostname)}
"""
    val_proc = _run_bash(val_script, _isolated_env(tmp_path))
    assert val_proc.returncode != 0, f"Expected validator rejection for {bad_hostname!r}"

    # 2. End-to-end CLI invocation check (both --hostname <val> and --hostname=<val>)
    bin_dir = tmp_path / "bin"
    sudo_marker = tmp_path / "sudo_called"
    _write_exec(
        bin_dir / "sudo",
        f'#!/usr/bin/env bash\ntouch {shlex.quote(str(sudo_marker))}\nexit 0\n',
    )
    env = _isolated_env(tmp_path, extra_path=bin_dir)

    cli_sep = subprocess.run(
        ["bash", str(RESET_DAY0_SH), "--confirm-destroy", "--hostname", bad_hostname],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert cli_sep.returncode != 0, f"Expected CLI rejection for --hostname {bad_hostname!r}"
    assert not sudo_marker.exists(), "Malformed --hostname must fail before sudo re-exec"

    cli_eq = subprocess.run(
        ["bash", str(RESET_DAY0_SH), "--confirm-destroy", f"--hostname={bad_hostname}"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert cli_eq.returncode != 0, f"Expected CLI rejection for --hostname={bad_hostname!r}"
    assert not sudo_marker.exists(), "Malformed --hostname= must fail before sudo re-exec"


@pytest.mark.parametrize(
    "good_hostname",
    [
        "a",
        "1",
        "ab",
        "starfive",
        "ubuntu",
        "brakerbox-vf2",
        "Node-01",
        "a" + ("b" * 61) + "c",
    ],
)
def test_validate_hostname_accepts_valid_rfc1123_labels(
    tmp_path: Path,
    good_hostname: str,
) -> None:
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_validate_hostname {shlex.quote(good_hostname)}
"""
    proc = _run_bash(script, _isolated_env(tmp_path))
    assert proc.returncode == 0, f"Expected acceptance for {good_hostname!r}: {proc.stderr}"


@pytest.mark.parametrize("new_host", ["starfive", "brakerbox-vf2", "a", "x" * 63])
def test_update_hosts_file_rewrites_via_awk_and_atomic_write(
    tmp_path: Path,
    new_host: str,
) -> None:
    hosts_file = tmp_path / "hosts"
    original = (
        "127.0.0.1\tlocalhost\n"
        "127.0.1.1\told-node.localdomain old-node\n"
        "127.0.1.10\tsibling-node\n"
        "# 127.0.1.1\tcommented-entry\n"
        "\n"
        "::1\tlocalhost ip6-localhost ip6-loopback\n"
    )
    hosts_file.write_text(original, encoding="utf-8")
    hosts_file.chmod(0o640)

    # Poison sed on PATH to guarantee awk + brak_atomic_write is used instead of sed.
    bin_dir = tmp_path / "bin"
    _write_exec(
        bin_dir / "sed",
        '#!/usr/bin/env bash\necho "sed must not be used for hosts rewrite" >&2\nexit 99\n',
    )

    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_update_hosts_file {shlex.quote(new_host)} {shlex.quote(str(hosts_file))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode == 0, proc.stderr

    expected = (
        "127.0.0.1\tlocalhost\n"
        f"127.0.1.1\t{new_host}\n"
        "127.0.1.10\tsibling-node\n"
        "# 127.0.1.1\tcommented-entry\n"
        "\n"
        "::1\tlocalhost ip6-localhost ip6-loopback\n"
    )
    assert hosts_file.read_text(encoding="utf-8") == expected
    assert stat.S_IMODE(hosts_file.stat().st_mode) == 0o640
    # No leftover atomic temp files in target directory
    assert [p.name for p in tmp_path.iterdir() if p.is_file()] == ["hosts"]


def test_update_hosts_file_rejects_invalid_hostname_without_mutation(tmp_path: Path) -> None:
    hosts_file = tmp_path / "hosts"
    original = "127.0.0.1\tlocalhost\n127.0.1.1\toldhost\n"
    hosts_file.write_text(original, encoding="utf-8")

    for bad in ("a/b", "a&b", "../etc", "-bad", "bad-", ""):
        script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_update_hosts_file {shlex.quote(bad)} {shlex.quote(str(hosts_file))}
"""
        proc = _run_bash(script, _isolated_env(tmp_path))
        assert proc.returncode != 0
        assert hosts_file.read_text(encoding="utf-8") == original


def test_reset_script_uses_awk_and_brak_atomic_write_for_hosts() -> None:
    text = RESET_DAY0_SH.read_text(encoding="utf-8")
    sed_lines = [line for line in text.splitlines() if "sed -i" in line]
    assert all("hosts" not in line for line in sed_lines)
    assert "brak_atomic_write" in text
    assert "_reset_update_hosts_file" in text


def test_sudo_preserve_env_includes_rvdk_bin_at_runtime(tmp_path: Path) -> None:
    if os.geteuid() == 0:
        pytest.skip("sudo re-exec only occurs when invoked as non-root")

    bin_dir = tmp_path / "bin"
    args_file = tmp_path / "sudo_args.txt"
    _write_exec(
        bin_dir / "sudo",
        f"""#!/usr/bin/env bash
printf '%s\\n' "$@" > {shlex.quote(str(args_file))}
exit 0
""",
    )
    env = _isolated_env(tmp_path, extra_path=bin_dir)
    env["RVDK_BIN"] = "/opt/custom/bin/rvdk"

    proc = subprocess.run(
        ["bash", str(RESET_DAY0_SH), "--confirm-destroy", "--hostname", "starfive"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr

    sudo_args = args_file.read_text(encoding="utf-8").splitlines()
    preserve_args = [a for a in sudo_args if a.startswith("--preserve-env=")]
    assert len(preserve_args) == 1
    preserved_vars = preserve_args[0].split("=", 1)[1].split(",")
    assert "RVDK_BIN" in preserved_vars


def test_reset_rvdk_teardown_invokes_preserved_rvdk_bin(tmp_path: Path) -> None:
    custom_rvdk = tmp_path / "custom-rvdk"
    rvdk_log = tmp_path / "rvdk_calls.txt"
    _write_exec(
        custom_rvdk,
        f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> {shlex.quote(str(rvdk_log))}\nexit 0\n',
    )

    env = _isolated_env(tmp_path)
    env["RVDK_BIN"] = str(custom_rvdk)
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_rvdk_teardown
"""
    proc = _run_bash(script, env)
    assert proc.returncode == 0, proc.stderr
    assert rvdk_log.read_text(encoding="utf-8").splitlines() == ["reset"]


def test_wipe_nvme_targets_aborts_when_child_lv_mounted_even_with_findmnt_present(
    tmp_path: Path,
) -> None:
    dev_dir = tmp_path / "dev"
    dev_dir.mkdir()
    (dev_dir / "nvme0n1").touch()
    (dev_dir / "nvme0n1p1").touch()

    bin_dir = tmp_path / "bin"
    destructive_marker = tmp_path / "destructive_ran"
    # Simulate real findmnt --source behavior: returns empty on parent nvme0n1 / nvme0n1p1
    # when a descendant dm/LVM device (e.g. /dev/mapper/vg_other-lv_data) is mounted.
    _write_exec(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 1\n")
    _write_exec(
        bin_dir / "lsblk",
        """#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "-d" ]]; then
        exit 0
    fi
done
echo "/mnt/other_vg_data"
""",
    )
    _write_exec(
        bin_dir / "fuser",
        '#!/usr/bin/env bash\n[[ "${1:-}" == "-vm" ]] && echo "holder 5566" >&2\nexit 0\n',
    )
    for cmd in ("pvremove", "wipefs", "nvme"):
        _write_exec(
            bin_dir / cmd,
            f'#!/usr/bin/env bash\ntouch {shlex.quote(str(destructive_marker))}\n',
        )

    target_dev = dev_dir / "nvme0n1"
    wipe_script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_device_is_protected() {{ return 1; }}
_reset_wipe_nvme_targets {shlex.quote(str(target_dev))}
pvremove -ff -y {shlex.quote(str(target_dev))}
wipefs -af {shlex.quote(str(target_dev))}
nvme format {shlex.quote(str(target_dev))} -l 0 --force
"""
    env = _isolated_env(tmp_path, extra_path=bin_dir)
    proc = _run_bash(wipe_script, env)
    assert proc.returncode != 0
    assert "5566" in proc.stderr
    assert "remains mounted" in proc.stderr
    assert not destructive_marker.exists()

    # Also verify pre-nvme-format descendant mount guard catches child mounts directly.
    format_guard_script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
if _reset_dev_tree_is_mounted {shlex.quote(str(target_dev))}; then
    _reset_report_active_holders {shlex.quote(str(target_dev))}
    log_fatal "Safety Interlock: refusing nvme format while descendant mounted."
fi
nvme format {shlex.quote(str(target_dev))} -l 0 --force
"""
    guard_proc = _run_bash(format_guard_script, env)
    assert guard_proc.returncode != 0
    assert "5566" in guard_proc.stderr
    assert not destructive_marker.exists()


def test_dev_tree_is_mounted_detects_proc_mounts_child_via_source_touches_disk(
    tmp_path: Path,
) -> None:
    proc_mounts = tmp_path / "proc_mounts"
    proc_mounts.write_text(
        "/dev/mapper/vg_other-lv_data /mnt/other ext4 rw,relatime 0 0\n",
        encoding="utf-8",
    )

    bin_dir = tmp_path / "bin"
    _write_exec(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 1\n")
    _write_exec(bin_dir / "lsblk", "#!/usr/bin/env bash\nexit 0\n")

    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_source_touches_disk() {{
    [[ "$1" == "/dev/mapper/vg_other-lv_data" && "$2" == "nvme0n1" ]]
}}
_reset_dev_tree_is_mounted "/dev/nvme0n1" {shlex.quote(str(proc_mounts))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode == 0, proc.stderr


def test_wipe_nvme_targets_unmounts_partitions_before_whole_disk(tmp_path: Path) -> None:
    dev_dir = tmp_path / "dev"
    dev_dir.mkdir()
    target_dev = dev_dir / "nvme0n1"
    part_dev = dev_dir / "nvme0n1p1"
    target_dev.touch()
    part_dev.touch()

    bin_dir = tmp_path / "bin"
    state_unmounted = tmp_path / "part_unmounted"
    ops_log = tmp_path / "ops.log"
    _write_exec(
        bin_dir / "findmnt",
        f"""#!/usr/bin/env bash
if [[ -f {shlex.quote(str(state_unmounted))} ]]; then
    exit 1
fi
for arg in "$@"; do
    if [[ "$arg" == {shlex.quote(str(part_dev))} ]]; then
        echo "/mnt/scratch"
        exit 0
    fi
done
exit 1
""",
    )
    _write_exec(
        bin_dir / "umount",
        f"""#!/usr/bin/env bash
printf 'umount:%s\\n' "$1" >> {shlex.quote(str(ops_log))}
if [[ "$1" == {shlex.quote(str(part_dev))} ]]; then
    touch {shlex.quote(str(state_unmounted))}
    exit 0
fi
exit 1
""",
    )
    _write_exec(
        bin_dir / "pvremove",
        f'#!/usr/bin/env bash\nprintf "pvremove:%s\\n" "$*" >> {shlex.quote(str(ops_log))}\n',
    )
    _write_exec(
        bin_dir / "wipefs",
        f'#!/usr/bin/env bash\nprintf "wipefs:%s\\n" "$*" >> {shlex.quote(str(ops_log))}\n',
    )

    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_is_block_device() {{ [[ -e "$1" ]]; }}
_reset_device_is_protected() {{ return 1; }}
_reset_wipe_nvme_targets {shlex.quote(str(target_dev))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode == 0, proc.stderr

    ops = ops_log.read_text(encoding="utf-8").splitlines()
    assert ops == [
        f"umount:{part_dev}",
        f"pvremove:-ff -y {part_dev}",
        f"pvremove:-ff -y {target_dev}",
        f"wipefs:-af {part_dev}",
        f"wipefs:-af {target_dev}",
    ]


@pytest.mark.parametrize(
    ("initial_hosts", "expected_hosts"),
    [
        (
            "127.0.0.1\tlocalhost\n::1\tlocalhost\n",
            "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\tstarfive\n",
        ),
        (
            "127.0.0.1\tlocalhost",
            "127.0.0.1\tlocalhost\n127.0.1.1\tstarfive\n",
        ),
        (
            "",
            "127.0.1.1\tstarfive\n",
        ),
        (
            (
                "127.0.0.1\tlocalhost\n"
                "127.0.1.1\told-host-one\n"
                "127.0.1.10\tsibling-node\n"
                "127.0.1.1\told-host-two\n"
            ),
            (
                "127.0.0.1\tlocalhost\n"
                "127.0.1.1\tstarfive\n"
                "127.0.1.10\tsibling-node\n"
            ),
        ),
    ],
)
def test_update_hosts_file_handles_missing_and_duplicate_127_0_1_1_entries(
    tmp_path: Path,
    initial_hosts: str,
    expected_hosts: str,
) -> None:
    hosts_file = tmp_path / "hosts"
    hosts_file.write_text(initial_hosts, encoding="utf-8")

    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_update_hosts_file "starfive" {shlex.quote(str(hosts_file))}
"""
    proc = _run_bash(script, _isolated_env(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert hosts_file.read_text(encoding="utf-8") == expected_hosts


def test_select_512_lbaf_requires_ms0_and_prefers_lowest_rp(tmp_path: Path) -> None:
    # 1. Ignores ms:8 lbads:9 (even with rp:0) and selects ms:0 lbads:9 with lowest rp:
    mixed_id_ns = """\
NVME Identify Namespace 1:
nlbaf   : 3
lbaf  0 : ms:8   lbads:9  rp:0 (in use)
lbaf  1 : ms:0   lbads:9  rp:0x2
lbaf  2 : ms:0   lbads:9  rp:0x1
lbaf  3 : ms:0   lbads:12 rp:0
"""
    id_file = tmp_path / "id_ns_mixed.txt"
    id_file.write_text(mixed_id_ns, encoding="utf-8")

    bin_dir = tmp_path / "bin"
    _write_exec(
        bin_dir / "nvme",
        f'#!/usr/bin/env bash\ncat {shlex.quote(str(id_file))}\n',
    )
    env = _isolated_env(tmp_path, extra_path=bin_dir)

    script_dev = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_select_512_lbaf "/dev/nvme0n1"
"""
    proc_dev = _run_bash(script_dev, env)
    assert proc_dev.returncode == 0, proc_dev.stderr
    assert proc_dev.stdout.strip() == "2"

    # 2. Returns empty when only metadata-bearing 512B (ms:8 / ms:16) or 4Kn (lbads:12) exist
    no_ms0_512 = """\
lbaf  0 : ms:8   lbads:9  rp:0x1
lbaf  1 : ms:16  lbads:9  rp:0
lbaf  2 : ms:0   lbads:12 rp:0 (in use)
"""
    no_ms0_file = tmp_path / "id_ns_noms0.txt"
    no_ms0_file.write_text(no_ms0_512, encoding="utf-8")
    script_empty = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
_reset_select_512_lbaf < {shlex.quote(str(no_ms0_file))}
"""
    proc_empty = _run_bash(script_empty, env)
    assert proc_empty.returncode == 0, proc_empty.stderr
    assert proc_empty.stdout.strip() == ""


def test_strict_umount_retries_and_succeeds_after_initial_target_is_busy(
    tmp_path: Path,
) -> None:
    text = RESET_DAY0_SH.read_text(encoding="utf-8")
    assert 'BRAKERRAK_UMOUNT_RETRY_SLEEP:-0.5' in text

    bin_dir = tmp_path / "bin"
    count_file = tmp_path / "umount_count.txt"
    events_log = tmp_path / "events.log"
    _write_exec(
        bin_dir / "umount",
        f"""#!/usr/bin/env bash
cnt=0
[[ -f {shlex.quote(str(count_file))} ]] && cnt="$(cat {shlex.quote(str(count_file))})"
cnt=$(( cnt + 1 ))
printf '%d\n' "$cnt" > {shlex.quote(str(count_file))}
printf 'umount:%d:%s\n' "$cnt" "$*" >> {shlex.quote(str(events_log))}
if (( cnt < 3 )); then
    echo "umount: $1: target is busy." >&2
    exit 32
fi
exit 0
""",
    )
    _write_exec(
        bin_dir / "udevadm",
        f'#!/usr/bin/env bash\nprintf "udevadm:%s\\n" "$*" >> {shlex.quote(str(events_log))}\n',
    )
    _write_exec(
        bin_dir / "fuser",
        f'#!/usr/bin/env bash\nprintf "fuser:%s\\n" "$*" >> {shlex.quote(str(events_log))}\n',
    )

    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_strict_umount "/mnt/nvme_pgdata"
printf "UNMOUNT_OK\n"
"""
    proc = _run_bash(script, _isolated_env(tmp_path, extra_path=bin_dir))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "UNMOUNT_OK"

    events = events_log.read_text(encoding="utf-8").splitlines()
    umount_events = [e for e in events if e.startswith("umount:")]
    assert umount_events == [
        "umount:1:/mnt/nvme_pgdata",
        "umount:2:/mnt/nvme_pgdata",
        "umount:3:/mnt/nvme_pgdata",
    ]
    assert events.count("udevadm:settle") == 2


def test_pgdg_backup_dir_relocated_off_run_tmpfs() -> None:
    text = RESET_DAY0_SH.read_text(encoding="utf-8")
    assert '${RUNTIME_DIR}/pgdg-deb-backup' not in text
    expected_dir = (
        'PGDG_BACKUP_DIR="${BRAKERRAK_PGDG_BACKUP_DIR:-/var/cache/brakerrak/pgdg-deb-backup}"'
    )
    assert expected_dir in text
    assert "install -d -m 0700" in text

    # Static check: no PGDG_BACKUP_DIR assignment references /run
    for line in text.splitlines():
        if "PGDG_BACKUP_DIR=" in line:
            assert "/run" not in line


def test_riscv64_sd_media_executes_databroker_service_teardown_unlike_mcu(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    sys_log = tmp_path / "systemctl.log"
    _write_exec(
        bin_dir / "systemctl",
        f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> {shlex.quote(str(sys_log))}\n',
    )
    _write_exec(bin_dir / "pkill", "#!/usr/bin/env bash\nexit 0\n")

    env = _isolated_env(tmp_path, extra_path=bin_dir)

    # 1. riscv64 + STORAGE_MEDIA="sd": NOT an MCU target -> stops postgresql/mosquitto/nfs-ganesha
    rv64_script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
DT_MODEL="StarFive VisionFive 2 v1.3B"
TARGET_ARCH="riscv64"
STORAGE_MEDIA="sd"
NODE_ROLE="databroker"
TARGET_BOARD="starfive-jh7110"
is_mcu="false"
if _reset_is_mcu_target "$DT_MODEL" "$TARGET_ARCH" "$NODE_ROLE" "$TARGET_BOARD"; then
    is_mcu="true"
fi
_reset_stop_databroker_services "$is_mcu"
printf "IS_MCU=%s\n" "$is_mcu"
"""
    rv64_proc = _run_bash(rv64_script, env)
    assert rv64_proc.returncode == 0, rv64_proc.stderr
    assert rv64_proc.stdout.strip() == "IS_MCU=false"
    calls = sys_log.read_text(encoding="utf-8")
    assert "stop postgresql" in calls
    assert "mosquitto" in calls
    assert "nfs-ganesha.service" in calls

    # 2. espressif-esp32p4 / riscv32 MCU target: skips host systemctl service teardown
    sys_log.unlink()
    mcu_script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
is_mcu="false"
if _reset_is_mcu_target "Espressif ESP32-P4" "riscv32" "snitchbench" "espressif-esp32p4"; then
    is_mcu="true"
fi
_reset_stop_databroker_services "$is_mcu"
printf "IS_MCU=%s\n" "$is_mcu"
"""
    mcu_proc = _run_bash(mcu_script, env)
    assert mcu_proc.returncode == 0, mcu_proc.stderr
    assert "IS_MCU=true" in mcu_proc.stdout
    assert not sys_log.exists()


def test_reset_rvdk_teardown_compat_false_fails_fast_when_rvdk_reset_absent(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    apt_marker = tmp_path / "apt_called"
    _write_exec(
        bin_dir / "apt-get",
        f'#!/usr/bin/env bash\ntouch {shlex.quote(str(apt_marker))}\nexit 0\n',
    )

    # Case 1: rvdk binary absent + BRAKERRAK_LEGACY_RVDK_COMPAT=false -> fails fast
    env_absent = _isolated_env(tmp_path, extra_path=bin_dir)
    env_absent["BRAKERRAK_LEGACY_RVDK_COMPAT"] = "false"
    env_absent["RVDK_BIN"] = str(tmp_path / "nonexistent-rvdk")
    script = f"""
source {shlex.quote(str(RESET_DAY0_SH))}
brak_log_init "RESET"
_reset_rvdk_teardown
"""
    proc_absent = _run_bash(script, env_absent)
    assert proc_absent.returncode != 0
    assert "BRAKERRAK_LEGACY_RVDK_COMPAT=false" in proc_absent.stderr
    assert not apt_marker.exists()

    # Case 2: rvdk binary present but `rvdk reset` unsupported + COMPAT=false -> fails fast
    failing_rvdk = _write_exec(
        tmp_path / "rvdk-no-reset",
        '#!/usr/bin/env bash\necho "unknown subcommand: reset" >&2\nexit 2\n',
    )
    env_unsupported = _isolated_env(tmp_path, extra_path=bin_dir)
    env_unsupported["BRAKERRAK_LEGACY_RVDK_COMPAT"] = "false"
    env_unsupported["RVDK_BIN"] = str(failing_rvdk)
    proc_unsup = _run_bash(script, env_unsupported)
    assert proc_unsup.returncode != 0
    assert "BRAKERRAK_LEGACY_RVDK_COMPAT=false" in proc_unsup.stderr
    assert not apt_marker.exists()
