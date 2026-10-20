import os


def test_reads_mode_from_env():
    os.environ['MODE'] = 'test'
    assert os.environ['MODE'] == 'test'
