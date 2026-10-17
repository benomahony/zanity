def test_parses_number():
    try:
        value = int('3')
    except:
        value = 0
    assert value == 3
