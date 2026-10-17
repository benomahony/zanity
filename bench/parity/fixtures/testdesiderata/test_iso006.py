import tempfile


def test_scratch_dir_exists():
    assert tempfile.mkdtemp()
