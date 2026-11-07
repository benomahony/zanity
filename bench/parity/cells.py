"""The Markdown and HTML pieces the comparison pages are built from: badges, scores, sizes and
durations, bar charts, head-to-head charts and tables, and which tools results.json measured."""

import html
from tools import TOOLS, Tool


MEGABYTE = 1 << 20


# No process measured here could hold a terabyte; a peak this large means the units are wrong.
MAX_PLAUSIBLE_PEAK = 1 << 40


LINKS = {
    "nasa-lsp": "https://github.com/benomahony/nasa-lsp",
    "testdesiderata": "https://github.com/benomahony/testdesiderata",
    "mockbuster": "https://github.com/benomahony/mockbuster",
    "dddlint": "https://github.com/benomahony/dddlint",
    "bonsai": "",
    "lizard": "https://github.com/terryyin/lizard",
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
    assert value < MAX_PLAUSIBLE_PEAK, f"{value} bytes is not a plausible peak; check the units"
    return f"{value / MEGABYTE:.0f} MB"


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


def seconds(duration_seconds: float) -> str:
    """Round a timing's display label to milliseconds or hundredths of a second.
    Formatting never replaces or converts the numeric measurement kept in results.json."""
    assert duration_seconds >= 0, f"a duration is never negative, but got {duration_seconds} s"
    assert duration_seconds < 3600, f"{duration_seconds} s is not a plausible timing; check the units"
    if duration_seconds < 1:
        milliseconds = duration_seconds * 1000
        return f"{milliseconds:.0f} ms"
    return f"{duration_seconds:.2f} s"


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


def measured(data: dict, key: str = "corpus") -> list[Tool]:
    """The tools results.json has scored, or timed with key "cli", so a tool added to tools.py appears once parity.py has run it."""
    assert key in data, f"results.json has no {key!r}; run parity.py"
    tools = [tool for tool in TOOLS if tool.name in data[key]]
    assert tools, "results.json scored none of the tools in tools.py; run parity.py"
    return tools


def generated(data: dict) -> list[str]:
    assert data["when"], "results.json needs the date it was generated"
    assert data["commit"], "results.json needs the zanity commit it measured"
    return [f"Generated by `bench/parity/parity.py` on {data['when']}, against zanity `{data['commit']}`.", ""]
