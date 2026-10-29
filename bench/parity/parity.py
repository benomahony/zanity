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
import sys
import tempfile
import time
from pathlib import Path

import page
from score import Server, Zanity, build_corpus, score_inference_live, score_corpus, score_fixtures, score_inference, score_languages, zanity_rules
from timing import LSP_FILE, bench_cli, bench_lsp
from tools import REPO, TOOLS


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zanity", type=Path, default=REPO / "zig-out" / "bin" / "zanity")
    parser.add_argument("--skip-bench", action="store_true", help="score only; keep the timings already in results.json")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--infer-url", help="a System One server, such as a local Kev, to ask both inference linters the named questions about their fixtures")
    parser.add_argument("--infer-model", default="kev-4b", help="the model --infer-url serves")
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


def comparison_results(args: argparse.Namespace, zanity: Zanity) -> dict:
    """Collect one CLI run's scores and measurements. Arguments come from the invoking user's
    parser, and cached results are our own generated JSON; malformed cache data is an error.
    No global state is changed here, and callers own both the cache lifetime and error display."""
    assert args.runs > 0, f"benchmark runs must be positive, not {args.runs}; pass --runs 1 or more"
    assert zanity.binary.is_file(), f"{zanity.binary} is missing; build zanity before collecting comparison results"
    commit = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True)
    data = {"when": time.strftime("%Y-%m-%d"), "commit": commit.stdout.strip(), "runs": args.runs, **scores(zanity)}
    kept = {}
    if args.skip_bench or not args.infer_url:
        try:
            kept = json.loads(page.RESULTS.read_text())
        except FileNotFoundError as error:
            if args.skip_bench:
                raise ValueError(f"{page.RESULTS} has no previous timings to reuse; run parity.py once without --skip-bench") from error
            kept = {}
        if not isinstance(kept, dict):
            raise ValueError(f"{page.RESULTS} must contain a JSON object; regenerate it without --skip-bench")
    if args.infer_url:
        data["inference_live"] = {"model": args.infer_model, "rows": score_inference_live(zanity, Server(args.infer_url, args.infer_model))}
    elif "inference_live" in kept:
        data["inference_live"] = kept["inference_live"]
    if args.skip_bench:
        data |= {key: kept[key] for key in ("cli", "lsp", "lsp_lines", "runs") if key in kept}
    else:
        data["cli"] = bench_cli(zanity, args.runs)
        data["lsp"] = bench_lsp(zanity, args.runs)
        data["lsp_lines"] = len(LSP_FILE.read_text().splitlines())
    return data


def publish_comparison(data: dict) -> None:
    """Atomically replace our fixed results artifact, then derive the comparison pages from
    that complete snapshot. The sibling staging directory is removed even if publication fails."""
    assert "cli" in data, "no timings in comparison data: run once without --skip-bench"
    assert data["commit"], f"git found no commit in {REPO}; run parity from a checkout with a commit"
    with tempfile.TemporaryDirectory(prefix=".parity-results-", dir=page.RESULTS.parent) as pending:
        snapshot = Path(pending) / page.RESULTS.name
        snapshot.write_text(json.dumps(data, indent=2) + "\n")
        snapshot.replace(page.RESULTS)
    page.main()


def main() -> None:
    """Run a local developer CLI with the invoking user's filesystem and process permissions.
    Own a private cache for the run, delegate collection and publication, and report operational
    failures at this command boundary. There is no remote caller or shared mutable application state."""
    args = arguments()
    assert args.runs > 0, f"--runs must be positive, not {args.runs}; pass --runs 1 or more"
    try:
        with tempfile.TemporaryDirectory(prefix="parity-") as temporary:
            zanity = Zanity(args.zanity.resolve(), Path(temporary) / "store.db")
            data = comparison_results(args, zanity)
            assert data["commit"], "comparison results lack a commit; collect results from a git checkout before publishing"
            publish_comparison(data)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"parity: {error}\nFix the reported file or tool failure, then rerun parity.py.", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
