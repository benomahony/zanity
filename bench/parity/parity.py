"""Run zanity and the linters it replaces on the same code, and write the comparison page.

Each linter runs through its own library, imported by an adapter in adapters/ under the
linter's own virtualenv, so what it reports is what it would report for a user:

- fixtures: one small trigger per rule. A fixture counts only if its linter fires on it; then
  zanity runs with the rules mapped to that rule.
- bonsai's own fixtures in six languages, scored finding by finding.
- a real-world corpus, scored finding by finding, then timed with hyperfine and over the
  language server protocol.

Usage: python3 bench/parity/parity.py [--zanity PATH] [--skip-bench] [--runs N]
"""

import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path

import page
from score import Zanity, build_corpus, score_corpus, score_fixtures, score_inference, score_languages, zanity_rules
from timing import LSP_FILE, bench_cli, bench_lsp
from tools import REPO, TOOLS


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zanity", type=Path, default=REPO / "zig-out" / "bin" / "zanity")
    parser.add_argument("--skip-bench", action="store_true", help="score only; keep the timings already in results.json")
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    assert args.runs > 0, f"--runs must be at least 1, not {args.runs}"
    assert args.zanity.is_file(), f"{args.zanity} is missing; run `zig build`"
    return args


def scores(zanity: Zanity) -> dict:
    rules = zanity_rules()
    unknown = sorted({t for tool in TOOLS for t in tool.targets} - set(rules))
    assert not unknown, f"tools.py maps to {unknown}, which zanity doesn't have; correct those rule names in tools.py"
    data = {"fixtures": [row for tool in TOOLS if tool.name != "bonsai" for row in score_fixtures(tool, zanity)]}
    data["languages"] = score_languages(zanity)
    data["corpus_stats"] = build_corpus()
    data["corpus"] = score_corpus(zanity)
    data["inference"] = score_inference(rules)
    assert data["fixtures"], "no fixtures were scored; add fixtures or fix their adapters before rerunning"
    return data


def main() -> None:
    args = arguments()
    zanity = Zanity(args.zanity.resolve(), Path(tempfile.mkdtemp(prefix="parity-")) / "store.db")
    commit = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True)
    data = {"when": time.strftime("%Y-%m-%d"), "commit": commit.stdout.strip(), "runs": args.runs, **scores(zanity)}
    if args.skip_bench and page.RESULTS.is_file():
        kept = json.loads(page.RESULTS.read_text())
        data |= {key: kept[key] for key in ("cli", "lsp", "lsp_lines", "runs") if key in kept}
    elif not args.skip_bench:
        data["cli"] = bench_cli(zanity, args.runs)
        data["lsp"] = bench_lsp(zanity, args.runs)
        data["lsp_lines"] = len(LSP_FILE.read_text().splitlines())
    assert "cli" in data, "no timings: run once without --skip-bench"
    assert data["commit"], f"git found no commit in {REPO}"
    page.RESULTS.write_text(json.dumps(data, indent=2) + "\n")
    page.main()


if __name__ == "__main__":
    main()
