import copy
import importlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
page = importlib.import_module("page")


DATA = json.loads(page.RESULTS.read_text())


class ComparisonPagesTest(unittest.TestCase):
    def test_one_overview_and_one_page_per_tool(self) -> None:
        rendered = page.pages(DATA)
        names = [t["name"] for t in page.tallies(DATA)]
        expected = {page.OVERVIEW, page.PERFORMANCE, *(page.SECTION / f"{name}.smd" for name in names)}
        self.assertEqual(set(rendered), expected)
        self.assertEqual(len(rendered), len(names) + 2)
        self.assertEqual(set(page.SECTION.glob("*.smd")), expected)

    def test_a_tool_not_yet_measured_is_left_out(self) -> None:
        name = page.TOOLS[-1].name
        data = copy.deepcopy(DATA)
        data["corpus"].pop(name, None)
        data["fixtures"] = [r for r in data["fixtures"] if r["tool"] != name]
        data["cli"] = {k: v for k, v in data["cli"].items() if name not in k}
        rendered = page.pages(data)
        self.assertNotIn(page.SECTION / f"{name}.smd", rendered)
        self.assertNotIn(name, page.render_performance(data))

    def test_overview_links_to_every_tool_page(self) -> None:
        overview = page.render_overview(DATA)
        names = [t["name"] for t in page.tallies(DATA)]
        self.assertTrue(all(f"'comparison/{name}'" in overview for name in names))
        self.assertIn("'comparison/performance'", overview)
        self.assertNotIn("# Rule by rule", overview)

    def test_overview_is_a_hub_not_the_full_report(self) -> None:
        overview = page.render_overview(DATA)
        self.assertNotIn("## Recall", overview)
        self.assertNotIn("## Agreement", overview)
        self.assertNotIn("# Speed", overview)
        performance = page.render_performance(DATA)
        self.assertIn("# Command line", performance)
        self.assertIn("# Editors and watch mode", performance)

    def test_specialised_evidence_lives_on_the_relevant_page(self) -> None:
        bonsai = page.render_tool(DATA, "bonsai")
        nouls = page.render_tool(DATA, "nouls")
        nasa = page.render_tool(DATA, "nasa-lsp")
        self.assertIn("# Six languages", bonsai)
        self.assertIn("# Inference", nouls)
        self.assertIn("# Rule by rule", nasa)
        self.assertNotIn("# Inference", nasa)

    def test_every_page_has_exactly_one_newline_at_eof(self) -> None:
        for path, content in page.pages(DATA).items():
            with self.subTest(path=path):
                self.assertTrue(content.endswith("\n"))
                self.assertFalse(content.endswith("\n\n"))

    def test_invalid_benchmark_result_says_what_to_change(self) -> None:
        with self.assertRaisesRegex(AssertionError, "fix the benchmark counts"):
            page.score(2, 1)


if __name__ == "__main__":
    unittest.main()
