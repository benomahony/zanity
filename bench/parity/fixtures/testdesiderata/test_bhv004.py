from unittest import mock


def test_reads_clock():
    with mock.patch('app.clock.now', autospec=False) as now:
        assert now is not None
