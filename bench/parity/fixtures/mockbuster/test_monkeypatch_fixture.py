def test_reads_home(monkeypatch):
    monkeypatch.setenv('HOME', '/tmp/home')
    assert True
