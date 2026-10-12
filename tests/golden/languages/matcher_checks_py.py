from hamcrest import assert_that, equal_to
import hamcrest


def test_total_includes_tax():
    assert_that(total(), equal_to(110))


def test_total_rounds_to_cents():
    hamcrest.assert_that(total(), equal_to(110))


def test_total_prints_receipt():
    print(total())
