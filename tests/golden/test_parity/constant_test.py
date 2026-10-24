def test_rejects_constant_checks():
    assert True  # parity: constant
    assert 1 + 1 == 2  # parity: constant
    assert "abc" == "abc"  # parity: constant
    actual = calculate()
    assert actual == 2
    assert 2 == actual
    assert calculate() == 2
    if unexpected():
        assert False
    assert f"{actual}" == "2"

class TestFrameworkChecks:
    def test_constants(self):
        self.assertTrue(True)  # parity: constant
        self.assertEqual(2, 1 + 1)  # parity: constant
        self.assertEqual(2, calculate())
        self.assertEqual(calculate(), 2)

def helper():
    assert 2 == 2
