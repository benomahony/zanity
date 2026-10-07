from pathlib import Path


def test_writes_under_tmp_path(tmp_path):
    folder = tmp_path / "out"
    path = folder / "file.txt"
    folder.mkdir()
    path.write_text("old")
    assert path.read_text() == "old", "reads back what it wrote"


def test_reads_a_real_file():
    path = Path("settings.toml")
    assert path.read_text() != "", "the real settings file has content"
