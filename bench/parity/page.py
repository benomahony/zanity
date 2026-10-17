"""Write the comparison overview and one page per tool from parity.py's results.

Usage: python3 bench/parity/page.py
"""

import html
import json
from pathlib import Path

from score import LANGUAGES
from tools import BY_NAME, HERE, REPO, TOOLS

RESULTS = HERE / "results.json"
CONTENT = REPO / "docs" / "content"
OVERVIEW = CONTENT / "comparison.smd"
PERFORMANCE = CONTENT / "comparison-performance.smd"
LINKS = {
    "nasa-lsp": "https://github.com/benomahony/nasa-lsp",
    "testdesiderata": "https://github.com/benomahony/testdesiderata",
    "mockbuster": "https://github.com/benomahony/mockbuster",
    "dddlint": "https://github.com/benomahony/dddlint",
    "bonsai": "",
    "nouls": "https://github.com/benomahony/nouls",
}


def badge(text: str, kind: str) -> str:
    """text in a coloured badge: pass, partial, fail or none."""
    assert kind in {"pass", "partial", "fail", "none"}, f"no badge style called {kind!r}"
    assert "]" not in text, f"a ] in {text!r} would end the badge early"
    return f"[{text}]($text.attrs('badge','{kind}'))"


def mark(value: bool | None) -> str:
    assert value in (True, False, None), f"mark takes a yes, a no or nothing, not {value!r}"
    assert not isinstance(value, int) or isinstance(value, bool), f"mark got the number {value}; pass a bool"
    return {True: badge("✓ yes", "pass"), False: badge("✗ no", "fail"), None: badge("– n/a", "none")}[value]


def score(part: int, whole: int, text: str = "") -> str:
    """part of whole in a badge: green when all of it, red when none, amber between."""
    assert 0 <= part <= whole, f"{part} of {whole} is not a share of it; fix the benchmark counts"
    assert whole or not part, f"{part} of nothing; fix the benchmark counts so a match has a measured total"
    kind = "none" if not whole else "pass" if part == whole else "fail" if not part else "partial"
    return badge(text or f"{part}/{whole}", kind)


def megabytes(value: float) -> str:
    assert value > 0, f"a process holds some memory, not {value} bytes"
    assert value < 1 << 40, f"{value} bytes is not a plausible peak; check the units"
    return f"{value / (1 << 20):.0f} MB"


def raw(lines: list[str]) -> list[str]:
    """lines of HTML, passed through Zine as they are."""
    assert lines, f"a raw block needs some HTML, but got {lines!r}"
    fences = [line for line in lines if line.startswith("```")]
    assert not fences, f"the fences {fences} inside the HTML would end the block"
    return ["```=html", *lines, "```", ""]


# A chart row: label, value, the value as text, and whether it is zanity's.
Row = tuple[str, float, str, bool]


def bar(row: Row, most: float) -> str:
    """One chart row: a bar as long as its value is against most, with the text at its end."""
    label, value, text, zanity = row
    assert 0 <= value <= most, f"{value} is outside the chart's 0 to {most}; fix the benchmark value or chart maximum"
    assert most > 0, f"a chart scaled to {most} has no length; pass the largest positive benchmark value"
    width = max(85 * value / most, 0.6)
    side = "zanity" if zanity else "other"
    return (
        f'<div class="chart-row {side}"><span class="chart-label">{html.escape(label)}</span>'
        f'<span class="chart-track"><span class="chart-bar" style="width:{width:.1f}%"></span>'
        f'<span class="chart-value">{html.escape(text)}</span></span></div>'
    )


def chart(rows: list[Row], caption: str) -> list[str]:
    """Bars for rows, all on one scale."""
    assert rows, f"the chart {caption!r} has no rows"
    assert caption, "a chart needs a caption saying what it measures"
    most = max(row[1] for row in rows)
    return raw([f'<figure class="chart"><figcaption>{html.escape(caption)}</figcaption>', *(bar(row, most) for row in rows), "</figure>"])


def verdict(theirs: float, ours: float, words: tuple[str, str]) -> str:
    """How many times better or worse zanity's figure is, in a badge, as HTML."""
    assert theirs > 0, f"the other tool's figure is {theirs}, so there is nothing to compare; rerun its benchmark"
    assert ours > 0, f"zanity's figure is {ours}, so there is nothing to compare; rerun zanity's benchmark"
    better, worse = words
    if theirs >= ours:
        return f'<span class="badge pass">zanity {theirs / ours:.1f}× {better}</span>'
    return f'<span class="badge fail">zanity {ours / theirs:.1f}× {worse}</span>'


def duel(groups: list[tuple[str, float, float]], show, words: tuple[str, str], caption: str) -> list[str]:
    """Each tool beside zanity, one pair of bars per tool, each pair on its own scale."""
    assert groups, f"the chart {caption!r} has no tools"
    assert callable(show), f"show formats a value for the chart, not {show!r}"
    body = []
    for name, theirs, ours in groups:
        most = max(theirs, ours)
        body += [
            f'<div class="duel"><div class="duel-head">{html.escape(name)} {verdict(theirs, ours, words)}</div>',
            bar((name, theirs, show(theirs), False), most),
            bar(("zanity", ours, show(ours), True), most),
            "</div>",
        ]
    return raw([f'<figure class="chart"><figcaption>{html.escape(caption)}</figcaption>', *body, "</figure>"])


def pct(part: int, whole: int) -> str:
    assert part >= 0, f"a count is never negative, but got {part} of {whole}; fix the benchmark counts"
    assert part <= whole or whole == 0, f"{part} of {whole} can't be more than all of it; fix the benchmark counts"
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


def tally(name: str, mine: list[dict]) -> dict:
    """One tool's rules, the fixtures it fires on, how many zanity matches, and what it misses."""
    valid = [r for r in mine if r["old_fires"]]
    gaps = [r["rule"] for r in mine if r["old_fires"] is not False and not r["zanity_fires"]]
    assert mine, f"{name} has no scored rules; rerun parity.py or add its results"
    assert name in BY_NAME, f"{name} is not a tool in tools.py; add it to TOOLS before rendering it"
    return {"name": name, "rules": len(mine), "whole": len(valid), "part": sum(bool(r["zanity_fires"]) for r in valid), "gaps": gaps, "unit": "rules"}


def tallies(data: dict) -> list[dict]:
    """Each tool's tally; nouls last, by its named questions."""
    out = [tally(tool.name, [r for r in data["fixtures"] if r["tool"] == tool.name] or language_rows(data)) for tool in TOOLS]
    questions = data["inference"]["questions"]
    count = len(questions)
    gaps = [q["rule"] for q in questions if not q["present"]]
    out.append({"name": "nouls", "rules": count + data["inference"]["catalogue"], "whole": count, "part": count - len(gaps), "gaps": gaps, "unit": "questions"})
    assert len(out) == len(TOOLS) + 1, f"a tally per tool and one for nouls, not {len(out)}; add every configured tool's results"
    assert all(t["whole"] for t in out), f"every tool must fire on its own fixture, but these do not: {[t['name'] for t in out if not t['whole']]}; fix their fixtures or adapters"
    return out


def summary(data: dict) -> list[str]:
    rows = []
    for t in tallies(data):
        name, part, whole = t["name"], t["part"], t["whole"]
        link = f"[{name}](/comparison-{name}/)"
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
            f'<a href="../comparison-{t["name"]}/" class="card {"pass" if part == whole else "partial"}"><div class="card-name">{t["name"]}</div>'
            f'<div class="card-score">{part}<span>/{whole}</span></div>'
            f'<div class="card-bar"><span style="width:{100 * part / whole:.0f}%"></span></div>'
            f'<div class="card-unit">{t["unit"]} matched</div></a>'
        )
    assert cards, "no tool was tallied"
    assert len(cards) == len(TOOLS) + 1, f"a card per tool and one for nouls, not {len(cards)}"
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
    selected = [BY_NAME[only]] if only else TOOLS
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
    ran = "" if found["key"] else "`TYPESAFE_API_KEY` was not set, so neither nouls nor `zanity check --infer` ran; this compares the questions. "
    return [
        f"nouls asks a model {len(rows)} named questions and one question per error-catalogue family, {families} in all. {ran}The list comes from nouls' own config loader.",
        "",
        *table(["nouls question", "zanity --infer question", "In zanity"], rows),
        f"Of nouls' {families} catalogue questions, {detected} ({pct(detected, families)}) are about a family a deterministic zanity rule detects, so zanity answers them without a model. zanity asks no question per family.",
        "",
    ]


def cli_speed(data: dict) -> list[str]:
    cli = data["cli"]
    base = cli["zanity, all rules, cold"]["mean"]
    warm = cli["zanity, all rules, warm"]["mean"]
    rows = [[name, seconds(r["mean"]), seconds(r["stddev"]), seconds(r["min"]), megabytes(r["memory"]), f"{r['mean'] / base:.1f}×"] for name, r in cli.items()]
    pairs = [(tool.name, cli[tool.name], cli[f"zanity, {tool.name} rules, cold"]) for tool in TOOLS]
    means = [(name, t["mean"], z["mean"]) for name, t, z in pairs]
    fast = min(means, key=lambda mean: mean[1])
    quick = [(name, theirs / ours) for name, theirs, ours in means if name != "bonsai"]
    ratios = [ratio for _, ratio in quick]
    together = sum(t["memory"] for _, t, _ in pairs)
    memory = cli["zanity, all rules, cold"]["memory"]
    assert base > 0, f"zanity's time is the baseline, so it can't be {base} s"
    assert all("memory" in r for r in cli.values()), f"results.json has no memory for {[n for n, r in cli.items() if 'memory' not in r]}; run parity.py again"
    return [
        *raw([
            '<div class="headline">',
            f'<div><strong>{fast[1] / base:.1f}×</strong> faster on every rule, from an empty cache, than the fastest tool, {fast[0]}, on its own {len(BY_NAME[fast[0]].rules)}: {seconds(base)} against {seconds(fast[1])}.</div>',
            f'<div><strong>{min(ratios):.1f}–{max(ratios):.1f}×</strong> faster than {", ".join(name for name, _ in quick)}, each on its own rules; bonsai, which rebuilds its index on every run, is {cli["bonsai"]["mean"] / cli["zanity, bonsai rules, cold"]["mean"]:.0f}× slower.</div>',
            "</div>",
        ]),
        "## Head to head",
        "",
        f"Each tool on the whole corpus, {data['corpus_stats']['lines']:,} lines, beside zanity running only the rules that answer that tool's, from an empty cache. Each pair has its own scale. The mean of {data['runs']} runs after a warm-up, with [hyperfine](https://github.com/sharkdp/hyperfine).",
        "",
        *duel(means, seconds, ("faster", "slower"), "Time to check the corpus, shorter is better"),
        *chart([*((name, theirs, seconds(theirs), False) for name, theirs, _ in means if name != "bonsai"), ("zanity, every rule, cold", base, seconds(base), True), ("zanity, every rule, warm", warm, seconds(warm), True)], "Each tool on its own rules beside zanity on all of them, shorter is better; bonsai, off this scale, is above"),
        "## Memory",
        "",
        f"The most memory each run held, from the kernel's accounting of the process. One zanity run covers every rule, where the same coverage takes all five tools: run side by side, as in a pre-commit hook, they hold {megabytes(together)} at once.",
        "",
        *chart([*((name, t["memory"], megabytes(t["memory"]), False) for name, t, _ in pairs), ("all five at once", together, megabytes(together), False), ("zanity, cold", memory, megabytes(memory), True)], "Peak memory checking the corpus, smaller is better"),
        "## Every command",
        "",
        "The tools ran through the same adapters as above. Cold zanity starts each run with an empty cache; warm reuses the last run's.",
        "",
        *table(["Command", "Mean", "±", "Fastest", "Peak memory", "Against zanity, all rules, cold"], rows, right=5),
    ]


def lsp_speed(data: dict) -> list[str]:
    servers = data["lsp"]
    timed = [(name, r) for name, r in servers.items() if "error" not in r]

    def rows(key: str, show) -> list[Row]:
        assert callable(show), f"show formats a {key} for the chart, not {show!r}"
        measured = [(name, r) for name, r in timed if key in r]
        assert measured, f"no timed server has a {key!r}; run parity.py again"
        return [(name, r[key], show(r[key]), name.startswith("zanity")) for name, r in measured]

    table_rows = []
    for name, r in servers.items():
        if "error" in r:
            table_rows.append([name, r["error"], "", "", ""])
            continue
        table_rows.append([name, seconds(r["first"]), seconds(r["save"]), megabytes(r["memory"]) if "memory" in r else "–", str(r["diagnostics"])])
    assert any(name == "zanity" for name, _ in timed), f"zanity's language server wasn't timed; results.json has {sorted(servers)}"
    assert timed, f"no language server was timed; each failed: {servers}"
    assert timed[-1][0].startswith("zanity"), f"zanity is timed last, so its bars end each chart, not {timed[-1][0]}"
    others = sum(r["memory"] for name, r in timed if not name.startswith("zanity"))
    held = rows("memory", megabytes)
    return [
        "## As language servers, and watching",
        "",
        f"rich's `console.py`, {data['lsp_lines']:,} lines, alone in a workspace; the median of {data['runs']}. First: from starting the server to diagnostics for the opened file. Save: from a change and save to fresh diagnostics. Memory: what the process held with the file open; an editor runs every language server at once, so the others' memory adds up. `zanity check --watch` listens to the system's file events outside any editor and keeps its workspace and parsed-file cache alive between checks. nouls' server needs `TYPESAFE_API_KEY` and did not run.",
        "",
        *chart(rows("first", seconds), "Start to first diagnostics, shorter is better"),
        *chart(rows("save", seconds), "Save to fresh diagnostics, shorter is better"),
        *chart([*held[:-1], ("all of them at once", others, megabytes(others), False), held[-1]], "Memory with the file open, smaller is better"),
        *table(["Server", "First", "Save", "Memory", "Diagnostics"], table_rows, right=4),
    ]


def front(title: str, description: str) -> list[str]:
    assert title, "a comparison page needs a title"
    assert description, "a comparison page needs a description"
    return ['---', f'.title = "{title}",', f'.description = "{description}",', '.date = .date("2026-10-17T00:00:02"),', '.layout = "page.shtml",', '---', ""]


def generated(data: dict) -> list[str]:
    assert data["when"], "results.json needs the date it was generated"
    assert data["commit"], "results.json needs the zanity commit it measured"
    return [f"Generated by `bench/parity/parity.py` on {data['when']}, against zanity `{data['commit']}`.", ""]


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
        *front("Comparisons", "What zanity finds that the linters it consolidates find, and how fast."),
        "zanity replaces six linters. Start here, then open a tool for its rule-by-rule and real-code evidence.",
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
        "Each tool page has its fixture results, recall and agreement on real code. [Performance](/comparison-performance/) has command-line, editor and watch-mode timings.",
        "",
    ])


def render_performance(data: dict) -> str:
    assert data["cli"], "results.json has no command-line timings; rerun parity.py without --skip-bench"
    assert data["lsp"], "results.json has no editor timings; rerun parity.py without --skip-bench"
    return document([
        *front("zanity performance", "Command-line, editor and watch-mode speed and memory beside the tools zanity replaces."),
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
        "The harness needs checkouts of the tools beside zanity's (or `ZANITY_PARITY_SOURCES` naming their parent), each synced with `uv sync`, and hyperfine.",
        "",
        "```sh",
        "zig build",
        "python3 bench/parity/parity.py   # scores, times, and writes every comparison page",
        "python3 bench/parity/page.py     # rewrites the pages from bench/parity/results.json",
        "```",
        "",
    ])


def render_tool(data: dict, name: str) -> str:
    assert name in {t["name"] for t in tallies(data)}, f"{name} has no comparison tally; add its scored results before rendering the page"
    assert name in LINKS, f"{name} has no source link entry; add it to LINKS in page.py"
    external = LINKS[name]
    source = f"[{name}]({external})" if external else name
    body = [
        *front(f"zanity and {name}", f"Rule-by-rule evidence for zanity's coverage of {name}."),
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
    rendered = {OVERVIEW: render_overview(data), PERFORMANCE: render_performance(data), **{CONTENT / f"comparison-{name}.smd": render_tool(data, name) for name in names}}
    assert len(rendered) == len(names) + 2, f"wrote {len(rendered)} pages for {len(names)} tools, performance and one overview; add the missing comparison page in pages()"
    return rendered


def main() -> None:
    assert RESULTS.is_file(), f"{RESULTS} is missing; run bench/parity/parity.py first"
    assert CONTENT.is_dir(), f"{CONTENT} is missing; the docs live in docs/"
    written = pages(json.loads(RESULTS.read_text()))
    existing = {OVERVIEW, *CONTENT.glob("comparison-*.smd")}
    assert existing <= set(written), f"stale comparison pages: {sorted(str(path) for path in existing - set(written))}"
    for path, content in written.items():
        path.write_text(content)
        print(path)


if __name__ == "__main__":
    main()
