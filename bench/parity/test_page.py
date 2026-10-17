import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import page  # noqa: E402


DATA = json.loads(page.RESULTS.read_text())


class ComparisonPagesTest(unittest.TestCase):
    def test_one_overview_and_one_page_per_tool(self) -> None:
        rendered = page.pages(DATA)
        names = [t["name"] for t in page.tallies(DATA)]
        expected = {page.OVERVIEW, *(page.CONTENT / f"comparison-{name}.smd" for name in names)}
        self.assertEqual(set(rendered), expected)
        self.assertEqual(len(rendered), len(names) + 1)
        self.assertEqual({page.OVERVIEW, *page.CONTENT.glob("comparison-*.smd")}, expected)

    def test_overview_links_to_every_tool_page(self) -> None:
        overview = page.render_overview(DATA)
        names = [t["name"] for t in page.tallies(DATA)]
        self.assertTrue(all(f"/comparison-{name}/" in overview for name in names))
        self.assertNotIn("# Rule by rule", overview)

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
