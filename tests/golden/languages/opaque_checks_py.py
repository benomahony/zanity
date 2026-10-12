import unittest


class TotalTest(unittest.TestCase):
    def test_total_includes_tax(self):
        self.assertTrue(total() == 110)

    def test_receipt_lists_tax(self):
        self.assertFalse("tax" not in receipt())

    def test_total_stays_under_limit(self):
        self.assertTrue(total() < LIMIT)

    def test_total_is_positive(self):
        self.assertTrue(total() > 0 and total() < LIMIT)

    def test_total_reads_plainly(self):
        self.assertEqual(total(), 110)


def test_total_in_pytest():
    assert total() == 110
