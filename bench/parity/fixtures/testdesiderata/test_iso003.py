def test_reads_config_file():
    with open('config.ini') as handle:
        assert handle.read()
