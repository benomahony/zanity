import copy
import json
import unittest

from bench.parity import ratchet


BASELINE = ratchet.snapshot(json.loads(ratchet.RESULTS.read_text()))


class RatchetTest(unittest.TestCase):
    def test_baseline_has_no_changes(self) -> None:
        self.assertEqual(ratchet.regressions(BASELINE, BASELINE), [])
        self.assertEqual(ratchet.additions(BASELINE, BASELINE), [])

    def test_every_kind_of_regression_is_reported(self) -> None:
        current = copy.deepcopy(BASELINE)
        fixture = next(iter(current["fixtures"]))
        question = current["inference_questions"][0]
        language = next(iter(current["language_recall"]))
        rule = next(iter(current["language_recall"][language]))
        del current["fixtures"][fixture]
        current["inference_questions"].remove(question)
        del current["language_recall"][language][rule]
        errors = ratchet.regressions(current, BASELINE)
        self.assertTrue(any(fixture in error for error in errors))
        self.assertTrue(any(question in error for error in errors))
        self.assertTrue(any(f"{language}:{rule}" in error for error in errors))

    def test_improvements_require_a_floor_update(self) -> None:
        floors = copy.deepcopy(BASELINE)
        language = next(iter(floors["language_recall"]))
        rule = next(iter(floors["language_recall"][language]))
        floors["language_recall"][language][rule] -= 1
        self.assertTrue(any("recall rose" in gain for gain in ratchet.additions(BASELINE, floors)))


if __name__ == "__main__":
    unittest.main()
