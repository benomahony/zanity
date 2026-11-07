"""Write the comparison overview and one page per tool from parity.py's results.

Usage: python3 bench/parity/page.py
"""

import json
from pathlib import Path

from score import LANGUAGES
from tools import BY_NAME, HERE, REPO, TOOLS
from cells import LINKS, badge, codes, generated, mark, measured, pct, raw, score, table
from performance import cli_speed, lsp_speed

RESULTS = HERE / "results.json"
CONTENT = REPO / "docs" / "content"
SECTION = CONTENT / "comparison"
OVERVIEW = SECTION / "index.smd"
PERFORMANCE = SECTION / "performance.smd"


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


def tally(name: str, mine: list[dict]) -> dict:
    """One tool's rules, the fixtures it fires on, how many zanity matches, and what it misses."""
    valid = [r for r in mine if r["old_fires"]]
    gaps = [r["rule"] for r in mine if r["old_fires"] is not False and not r["zanity_fires"]]
    assert mine, f"{name} has no scored rules; rerun parity.py or add its results"
    assert name in BY_NAME, f"{name} is not a tool in tools.py; add it to TOOLS before rendering it"
    return {"name": name, "rules": len(mine), "whole": len(valid), "part": sum(bool(r["zanity_fires"]) for r in valid), "gaps": gaps, "unit": "rules"}


def tallies(data: dict) -> list[dict]:
    """Each tool's tally; nouls last, by its named questions."""
    out = [tally(tool.name, [r for r in data["fixtures"] if r["tool"] == tool.name] or language_rows(data)) for tool in measured(data)]
    questions = data["inference"]["questions"]
    count = len(questions)
    gaps = [q["rule"] for q in questions if not q["present"]]
    out.append({"name": "nouls", "rules": count + data["inference"]["catalogue"], "whole": count, "part": count - len(gaps), "gaps": gaps, "unit": "questions"})
    assert len(out) == len(measured(data)) + 1, f"a tally per tool and one for nouls, not {len(out)}; add every configured tool's results"
    assert all(t["whole"] for t in out), f"every tool must fire on its own fixture, but these do not: {[t['name'] for t in out if not t['whole']]}; fix their fixtures or adapters"
    return out


def summary(data: dict) -> list[str]:
    rows = []
    for t in tallies(data):
        name, part, whole = t["name"], t["part"], t["whole"]
        link = f"[{name}]($link.page('comparison/{name}'))"
        fixtures = "–" if t["unit"] == "questions" else str(whole)
        rows.append([link, str(t["rules"]), fixtures, score(part, whole, f"{part}/{whole} {t['unit']}"), codes(t["gaps"])])
    assert rows, "no tool was tallied; add tools to tools.py and rerun parity.py"
    assert data["fixtures"], "no fixtures were scored; run parity.py without skipping scores"
    return table(["Tool", "Rules", "Fixtures it fires on", "zanity fires on", "zanity misses"], rows)


def scoreboard(data: dict) -> list[str]:
    """A card per tool: the share of its rules zanity matches, as a number and a bar."""
    cards = []
    for t in tallies(data):
        part, whole = t["part"], t["whole"]
        cards.append(
            f'<a href="{t["name"]}/" class="card {"pass" if part == whole else "partial"}"><div class="card-name">{t["name"]}</div>'
            f'<div class="card-score">{part}<span>/{whole}</span></div>'
            f'<div class="card-bar"><span style="width:{100 * part / whole:.0f}%"></span></div>'
            f'<div class="card-unit">{t["unit"]} matched</div></a>'
        )
    assert cards, "no tool was tallied; check that results.json holds each tool's rules"
    assert len(cards) == len(measured(data)) + 1, f"a card per tool and one for nouls, not {len(cards)}; add the missing tool to TOOLS"
    return raw(['<div class="scoreboard">', *cards, "</div>"])


def rule_by_rule(data: dict, name: str) -> list[str]:
    rows = [
        [f"`{r['rule']}`", codes(r["zanity"]), mark(r["old_fires"]), mark(r["zanity_fires"]), mark(r["same_line"]), r["note"]]
        for r in data["fixtures"] if r["tool"] == name
    ]
    assert name in BY_NAME, f"{name} is not a tool in tools.py"
    assert rows, f"no {name} fixtures were scored; run parity.py again"
    return table(["Its rule", "zanity rule", "It fires", "zanity fires", "Same line", "Note"], rows)


def languages(data: dict) -> list[str]:
    tool = BY_NAME["bonsai"]
    rows = []
    for rule, targets in tool.rules.items():
        cells = []
        for language in LANGUAGES:
            found = data["languages"][language]["recall"].get(rule)
            cells.append(score(found["matched"], found["old"]) if found else badge("–", "none"))
        rows.append([f"`{rule}`", *cells, tool.notes.get(rule, "")])
    assert len(rows) == len(tool.rules), "a row per bonsai smell"
    assert set(data["languages"]) == set(LANGUAGES), "every language was scored"
    return table(["Smell", *LANGUAGES, "Note"], rows)


def corpus(data: dict, only: str | None = None) -> list[str]:
    recall_rows, agreement_rows = [], []
    selected = [BY_NAME[only]] if only else measured(data)
    for tool in selected:
        scored = data["corpus"][tool.name]
        for rule, s in scored["recall"].items():
            matched, old = s["matched"], s["old"]
            recall_rows.append([tool.name, f"`{rule}`", codes(tool.rules[rule]), tool.notes.get(rule, ""), str(old), str(matched), score(matched, old, pct(matched, old))])
        for rule, s in scored["agreement"].items():
            matched, found = s["matched"], s["zanity"]
            agreement_rows.append([tool.name, f"`{rule}`", str(found), str(matched), pct(matched, found)])
    assert recall_rows, "no old tool found anything in the corpus; fix the corpus or tool adapters and rerun parity.py"
    assert agreement_rows, "zanity found nothing in the corpus; fix the corpus or rule mappings and rerun parity.py"
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
    asked = found.get("asked", 0)
    left = families - detected - asked
    return [
        f"nouls asks a model {len(rows)} named questions and one question per error-catalogue family, {families} in all. The list comes from nouls' own config loader.",
        "",
        *table(["nouls question", "zanity --infer question", "In zanity"], rows),
        f"Of nouls' {families} catalogue questions, {detected} ({pct(detected, families)}) are about a family a deterministic zanity rule detects, so zanity answers them without a model, and zanity `--infer` asks {asked} ({pct(asked, families)}) itself, as rules named for their family. The other {left} are about families only C, C++, PHP or Perl can have, which zanity has no grammar for.",
        "",
        *live(data),
    ]


def live(data: dict) -> list[str]:
    """Both tools' answers from the same model to each named question about its fixture."""
    found = data.get("inference_live")
    if not found:
        return ["Neither nouls nor `zanity check --infer` has been run here against a model; `parity.py --infer-url` runs both against a System One server, such as a local Kev.", ""]
    rows = found["rows"]
    assert rows, f"results.json has live inference for {found.get('model')} with no rows; rerun parity.py --infer-url"
    show = lambda p: "–" if p is None else f"{p:.2f}"
    table_rows = [[f"`{r['rule']}`", f"`{r['zanity']}`", show(r["theirs"]), mark(r["theirs_fires"]), show(r["ours"]), mark(r["ours_fires"]), codes(r["settled"])] for r in rows]
    both = sum(r["theirs_fires"] and r["ours_fires"] for r in rows)
    assert all(r["rule"] for r in rows), f"a live row has no question: {[r for r in rows if not r['rule']][:1]}"
    return [
        "# Asking the same model",
        "",
        f"Each named question asked about a fixture written to have the problem it asks about, by both tools, of the same model, {found['model']}, served locally. The probability is how sure the model was that the problem is there; a finding needs 0.8. Settled: a deterministic zanity rule found it, so zanity didn't need to ask. Both reported {both} of {len(rows)}.",
        "",
        *table(["nouls question", "zanity question", "nouls p", "nouls reports", "zanity p", "zanity reports", "Settled by"], table_rows),
    ]


def front(title: str, description: str, newer: int = 2) -> list[str]:
    assert title, "a comparison page needs a title"
    assert description, "a comparison page needs a description"
    return ['---', f'.title = "{title}",', f'.description = "{description}",', f'.date = .date("2026-10-17T00:00:{newer:02}"),', '.layout = "page.shtml",', '---', ""]


def document(lines: list[str]) -> str:
    """One generated document, with exactly one newline at EOF."""
    assert lines, "a generated document cannot be empty; pass the page's frontmatter and body"
    rendered = "\n".join(lines).rstrip() + "\n"
    assert rendered and not rendered.endswith("\n\n"), f"document must end with exactly one newline, got {rendered[-2:]!r}; strip trailing blank lines in document()"
    return rendered


def render_overview(data: dict) -> str:
    assert data["fixtures"], "results.json has no fixtures; run parity.py"
    assert data["inference"]["questions"], "results.json has no inference questions; fix the nouls adapter and rerun parity.py"
    return document([
        *front("Comparisons", f"Rule-by-rule coverage and speed beside {len(tallies(data))} other linters."),
        "Each card links to that tool's evidence.",
        *generated(data),
        "",
        "# Summary",
        "",
        "Each rule has a small fixture written to trigger it. A fixture counts only if the old tool fires on it. Green: zanity matches every rule. Amber: some. Red: none.",
        "",
        *scoreboard(data),
        *summary(data),
        "# Evidence",
        "",
        "Each tool page has its fixture results, recall and agreement on real code. [Performance]($link.page('comparison/performance')) has command-line, editor and watch-mode timings.",
        "",
    ])


def render_performance(data: dict) -> str:
    assert data["cli"], "results.json has no command-line timings; rerun parity.py without --skip-bench"
    assert data["lsp"], "results.json has no editor timings; rerun parity.py without --skip-bench"
    return document([
        *front("Performance", "Command-line, editor and watch-mode speed and memory beside the tools zanity replaces.", 0),
        *generated(data),
        "# Command line",
        "",
        "On an M3 Max whose endpoint security slows every file open by a binary Apple didn't sign, which taxes zanity and the Python tools alike.",
        "",
        *cli_speed(data),
        "# Editors and watch mode",
        "",
        *lsp_speed(data),
        "# [Rerun]($heading.id('rerun'))",
        "",
        "The harness needs checkouts of the tools beside zanity's (or `ZANITY_PARITY_SOURCES` naming their parent), each synced with `uv sync` (Lizard has no `pyproject.toml`, so `uv venv && uv pip install -e .` in its checkout), and hyperfine.",
        "",
        "```sh",
        "zig build",
        "python3 bench/parity/parity.py   # scores, times, and writes every comparison page",
        "python3 bench/parity/parity.py --skip-bench --infer-url http://127.0.0.1:8009 --infer-model kev-4b   # also asks both inference linters, through a local Kev",
        "python3 bench/parity/page.py     # rewrites the pages from bench/parity/results.json",
        "```",
        "",
    ])


def render_tool(data: dict, name: str) -> str:
    names = [t["name"] for t in tallies(data)]
    assert name in names, f"{name} has no comparison tally; add its scored results before rendering the page"
    assert name in LINKS, f"{name} has no source link entry; add it to LINKS in page.py"
    external = LINKS[name]
    source = f"[{name}]({external})" if external else name
    body = [
        *front(name, f"Rule-by-rule evidence for zanity's coverage of {name}.", len(names) - names.index(name)),
        f"This page compares zanity with {source} on the same source files.",
        *generated(data),
    ]
    if name == "nouls":
        body += ["# Inference", "", *inference(data)]
    elif name == "bonsai":
        body += [
            "# Six languages",
            "",
            "bonsai's own fixtures, in place: its findings, and how many of them zanity reports on the same lines.",
            "",
            *languages(data),
            "# Real code",
            "",
            *corpus(data, name),
        ]
    else:
        body += [
            "# Rule by rule",
            "",
            "Same line means zanity reports it on the tool's line, give or take one. A note identifies deliberate differences.",
            "",
            *rule_by_rule(data, name),
            "# Real code",
            "",
            *corpus(data, name),
        ]
    return document(body)


def pages(data: dict) -> dict[Path, str]:
    names = [t["name"] for t in tallies(data)]
    assert len(names) == len(set(names)), f"comparison tool names must be unique, not {names}; remove or rename the duplicate in tools.py"
    rendered = {OVERVIEW: render_overview(data), PERFORMANCE: render_performance(data), **{SECTION / f"{name}.smd": render_tool(data, name) for name in names}}
    assert len(rendered) == len(names) + 2, f"wrote {len(rendered)} pages for {len(names)} tools, performance and one overview; add the missing comparison page in pages()"
    return rendered


def main() -> None:
    assert RESULTS.is_file(), f"{RESULTS} is missing; run bench/parity/parity.py first"
    assert SECTION.is_dir(), f"{SECTION} is missing; the comparison pages live in docs/content/comparison/"
    written = pages(json.loads(RESULTS.read_text()))
    existing = set(SECTION.glob("*.smd"))
    assert existing <= set(written), f"stale comparison pages: {sorted(str(path) for path in existing - set(written))}"
    for path, content in written.items():
        path.write_text(content)
        print(path)


if __name__ == "__main__":
    main()
