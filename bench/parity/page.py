"""Write docs/content/comparison.smd from the results parity.py saved.

Usage: python3 bench/parity/page.py
"""

import json
from pathlib import Path

from score import LANGUAGES
from tools import BY_NAME, HERE, REPO, TOOLS

RESULTS = HERE / "results.json"
PAGE = REPO / "docs" / "content" / "comparison.smd"
LINKS = {
    "nasa-lsp": "https://github.com/benomahony/nasa-lsp",
    "testdesiderata": "https://github.com/benomahony/testdesiderata",
    "mockbuster": "https://github.com/benomahony/mockbuster",
    "dddlint": "https://github.com/benomahony/dddlint",
    "bonsai": "",
    "nouls": "https://github.com/benomahony/nouls",
}


def mark(value: bool | None) -> str:
    assert value in (True, False, None), f"mark takes a yes, a no or nothing, not {value!r}"
    assert not isinstance(value, int) or isinstance(value, bool), f"mark got the number {value}; pass a bool"
    return {True: "yes", False: "**no**", None: "–"}[value]


def pct(part: int, whole: int) -> str:
    assert part >= 0, f"a count is never negative, but got {part} of {whole}"
    assert part <= whole or whole == 0, f"{part} of {whole} can't be more than all of it"
    return f"{100 * part / whole:.0f}%" if whole else "–"


def seconds(value: float) -> str:
    assert value >= 0, f"a duration is never negative, but got {value} s"
    assert value < 3600, f"{value} s is not a plausible timing; check the units"
    return f"{value * 1000:.0f} ms" if value < 1 else f"{value:.2f} s"


def codes(names: list[str]) -> str:
    assert all(names), f"a rule name is empty in {names}"
    assert all("`" not in n for n in names), f"a backtick in {names} would break the code span"
    return ", ".join(f"`{n}`" for n in names) or "–"


def table(header: list[str], rows: list[list[str]], right: int = 0) -> list[str]:
    """A Markdown table; the last `right` columns align right, for numbers."""
    ragged = [row for row in rows if len(row) != len(header)]
    assert header, f"a table needs columns; got rows like {rows[:1]}"
    assert not ragged, f"every row fills the {len(header)} columns {header}, but these don't: {ragged[:2]}"
    rule = ["---"] * (len(header) - right) + ["---:"] * right
    return ["| " + " | ".join(cells) + " |" for cells in [header, rule, *rows]] + [""]


def language_rows(data: dict) -> list[dict]:
    """bonsai's smells as summary rows: it fires if it found the smell in any language, and
    zanity fires if it reported any of those findings."""
    rows = []
    for rule in BY_NAME["bonsai"].rules:
        found = [data["languages"][lang]["recall"].get(rule) for lang in LANGUAGES]
        old, matched = sum(f["old"] for f in found if f), sum(f["matched"] for f in found if f)
        rows.append({"rule": rule, "old_fires": old > 0, "zanity_fires": matched > 0 if old else None})
    assert rows, "bonsai maps no smells in tools.py"
    assert set(data["languages"]) == set(LANGUAGES), f"results.json scored {sorted(data['languages'])}, not {LANGUAGES}"
    return rows


def summary(data: dict) -> list[str]:
    rows = []
    for tool in TOOLS:
        mine = [r for r in data["fixtures"] if r["tool"] == tool.name] or language_rows(data)
        valid = [r for r in mine if r["old_fires"]]
        answered = sum(bool(r["zanity_fires"]) for r in valid)
        gaps = [r["rule"] for r in mine if r["old_fires"] is not False and not r["zanity_fires"]]
        rows.append([f"[{tool.name}]({LINKS[tool.name]})" if LINKS[tool.name] else tool.name, str(len(mine)), f"{len(valid)}", f"{answered}/{len(valid)}", codes(gaps)])
    questions = data["inference"]["questions"]
    asked = sum(q["present"] for q in questions)
    missing = [q["rule"] for q in questions if not q["present"]]
    rows.append([f"[nouls]({LINKS['nouls']})", str(len(questions) + data["inference"]["catalogue"]), "–", f"{asked}/{len(questions)} questions", codes(missing)])
    assert len(rows) == len(TOOLS) + 1, "a row per tool and one for nouls"
    assert data["fixtures"], "no fixtures were scored"
    return table(["Tool", "Rules", "Fixtures it fires on", "zanity fires on", "zanity misses"], rows)


def rule_by_rule(data: dict) -> list[str]:
    rows = [
        [r["tool"], f"`{r['rule']}`", codes(r["zanity"]), mark(r["old_fires"]), mark(r["zanity_fires"]), mark(r["same_line"]), r["note"]]
        for r in data["fixtures"]
    ]
    unknown = sorted({r[0] for r in rows} - set(BY_NAME))
    assert rows, "no fixtures were scored; run parity.py again"
    assert not unknown, f"results.json names tools tools.py doesn't have: {unknown}; run parity.py again"
    return table(["Tool", "Its rule", "zanity rule", "It fires", "zanity fires", "Same line", "Note"], rows)


def languages(data: dict) -> list[str]:
    tool = BY_NAME["bonsai"]
    rows = []
    for rule, targets in tool.rules.items():
        cells = []
        for language in LANGUAGES:
            found = data["languages"][language]["recall"].get(rule)
            cells.append(f"{found['matched']}/{found['old']}" if found else "–")
        rows.append([f"`{rule}`", *cells])
    assert len(rows) == len(tool.rules), "a row per bonsai smell"
    assert set(data["languages"]) == set(LANGUAGES), "every language was scored"
    return table(["Smell", *LANGUAGES], rows, right=len(LANGUAGES))


def corpus(data: dict) -> list[str]:
    recall_rows, agreement_rows = [], []
    for tool in TOOLS:
        scored = data["corpus"][tool.name]
        for rule, s in scored["recall"].items():
            matched, old = s["matched"], s["old"]
            recall_rows.append([tool.name, f"`{rule}`", codes(tool.rules[rule]), tool.notes.get(rule, ""), str(old), str(matched), pct(matched, old)])
        for rule, s in scored["agreement"].items():
            matched, found = s["matched"], s["zanity"]
            agreement_rows.append([tool.name, f"`{rule}`", str(found), str(matched), pct(matched, found)])
    assert recall_rows, "no old tool found anything in the corpus"
    assert agreement_rows, "zanity found nothing in the corpus"
    return [
        "## Recall",
        "",
        "Of each tool's findings, how many zanity reports on the same lines with a mapped rule.",
        "",
        *table(["Tool", "Its rule", "zanity rule", "Note", "Its findings", "zanity too", "Recall"], recall_rows, right=3),
        "## Agreement",
        "",
        "Of zanity's findings, how many the tool also reports. Low agreement is zanity finding what the tool doesn't, which can be either tool's mistake.",
        "",
        *table(["Tool", "zanity rule", "zanity findings", "Tool too", "Agreement"], agreement_rows, right=3),
    ]


def inference(data: dict) -> list[str]:
    found = data["inference"]
    rows = [[f"`{q['rule']}`", f"`{q['zanity']}`" if q["zanity"] else "–", mark(q["present"])] for q in found["questions"]]
    families, detected = found["catalogue"], found["deterministic"]
    assert rows, f"nouls listed no named questions beside its {families} catalogue ones; check its config"
    assert families >= detected, f"{detected} detected families can't outnumber the {families} in the catalogue"
    ran = "" if found["key"] else "`TYPESAFE_API_KEY` was not set, so neither nouls nor `zanity check --infer` ran; this compares the questions. "
    return [
        f"nouls asks a model {len(rows)} named questions and one question per error-catalogue family, {families} in all. {ran}The list comes from nouls' own config loader.",
        "",
        *table(["nouls question", "zanity --infer question", "In zanity"], rows),
        f"Of nouls' {families} catalogue questions, {detected} ({pct(detected, families)}) are about a family a deterministic zanity rule detects, so zanity answers them without a model. zanity asks no question per family.",
        "",
    ]


def speed(data: dict) -> list[str]:
    cli = data["cli"]
    base = cli["zanity, all rules, cold"]["mean"]
    old = sum(cli[tool.name]["mean"] for tool in TOOLS)
    rows = [[name, seconds(r["mean"]), seconds(r["stddev"]), seconds(r["min"]), f"{r['mean'] / base:.1f}×"] for name, r in cli.items()]
    rows.append(["the five tools, one after another", seconds(old), "", "", f"{old / base:.1f}×"])
    servers = [[name, r["error"], "", ""] if "error" in r else [name, seconds(r["first"]), seconds(r["save"]), str(r["diagnostics"])] for name, r in data["lsp"].items()]
    assert base > 0, f"zanity's time is the baseline, so it can't be {base} s"
    assert servers, f"no language server was timed; results.json has {sorted(data)}"
    return [
        "## From the command line",
        "",
        f"The whole corpus, {data['runs']} runs after a warm-up, with [hyperfine](https://github.com/sharkdp/hyperfine). The tools ran through the same adapters as above. Cold zanity starts each run with an empty cache.",
        "",
        *table(["Command", "Mean", "±", "Fastest", "Against zanity, all rules, cold"], rows, right=4),
        "## As language servers",
        "",
        f"rich's `console.py`, {data['lsp_lines']:,} lines, alone in a workspace; the median of {data['runs']}. First: from starting the server to diagnostics for the opened file. Save: from a change and save to fresh diagnostics. nouls' server needs `TYPESAFE_API_KEY` and did not run.",
        "",
        *table(["Server", "First", "Save", "Diagnostics"], servers, right=3),
    ]


def render(data: dict) -> str:
    stats = data["corpus_stats"]
    assert data["fixtures"], "results.json has no fixtures; run parity.py"
    assert stats["files"], "results.json has an empty corpus; run parity.py"
    front = ['---', '.title = "Against the tools it replaces",', '.description = "What zanity finds that the linters it consolidates find, rule by rule, and how fast.",', '.date = .date("2026-10-17T00:00:02"),', '.layout = "page.shtml",', '---', ""]
    return "\n".join([
        *front,
        "zanity replaces six linters. This page runs each of them through its own Python library, beside zanity, on the same code, and reports what each finds.",
        f"It is generated by `bench/parity/parity.py` on {data['when']}, against zanity `{data['commit']}`; see [how to rerun it](#rerun).",
        "",
        "# Summary",
        "",
        "Each rule has a small fixture written to trigger it. A fixture counts only if the old tool fires on it.",
        "",
        *summary(data),
        "# Rule by rule",
        "",
        "Same line: zanity reports it on the tool's line, give or take one. A note says where zanity differs on purpose.",
        "",
        *rule_by_rule(data),
        "# Six languages",
        "",
        "bonsai's own fixtures, in place: its findings, and how many of them zanity reports on the same lines.",
        "",
        *languages(data),
        f"# Real code",
        "",
        f"{stats['files']} Python files, {stats['lines']:,} lines: [rich](https://github.com/Textualize/rich) and [click](https://github.com/pallets/click), and the old tools' own test suites. Nobody wrote this code to trigger a rule.",
        "",
        *corpus(data),
        "# Inference",
        "",
        *inference(data),
        "# Speed",
        "",
        "On an M3 Max whose endpoint security slows every file open by a binary Apple didn't sign, which taxes zanity and the Python tools alike.",
        "",
        *speed(data),
        "# [Rerun]($heading.id('rerun'))",
        "",
        "The harness needs checkouts of the tools beside zanity's (or `ZANITY_PARITY_SOURCES` naming their parent), each synced with `uv sync`, and hyperfine.",
        "",
        "```sh",
        "zig build",
        "python3 bench/parity/parity.py   # scores, times, and writes this page",
        "python3 bench/parity/page.py     # writes this page again from bench/parity/results.json",
        "```",
        "",
    ])


def main() -> None:
    assert RESULTS.is_file(), f"{RESULTS} is missing; run bench/parity/parity.py first"
    assert PAGE.parent.is_dir(), f"{PAGE.parent} is missing; the docs live in docs/"
    PAGE.write_text(render(json.loads(RESULTS.read_text())))
    print(PAGE)


if __name__ == "__main__":
    main()
