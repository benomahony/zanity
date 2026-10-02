import sys
import unittest

import pytest


@pytest.mark.skip
def test_marked():
    assert True, "never runs"


@pytest.mark.skip(reason="flaky")
def test_marked_with_reason():
    assert True, "never runs"


@pytest.mark.skipif(sys.platform == "win32", reason="posix only")
def test_conditional():
    assert True, "runs where it can"


@pytest.mark.xfail
def test_expected_failure():
    assert False, "fails"


@pytest.mark.xfail(strict=True)
def test_strict_expected_failure():
    assert False, "fails"


def test_skipped_in_body():
    pytest.skip("not ready")


def test_skipped_when_needed():
    if sys.platform == "win32":
        pytest.skip("posix only")
    assert True, "runs"


class TestCase(unittest.TestCase):
    @unittest.skip("broken")
    def test_off(self):
        self.skipTest("also off")
