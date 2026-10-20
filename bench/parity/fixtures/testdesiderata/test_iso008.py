import subprocess


def test_cli_prints_version():
    assert subprocess.run(['app', '--version']).returncode == 0
