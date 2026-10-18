"""Write the site's introduction and rules pages from README.md, which stays the one source.

The introduction is the README from its first paragraph to its rules; the rules page is its
rules section. Every rule in zanity.schema.json must appear on the rules page.

Usage: python3 docs/sync.py
"""

import json
import re
from pathlib import Path

DOCS = Path(__file__).parent.resolve()
REPO = DOCS.parent
CONTENT = DOCS / "content"
PAGES = {
    "index.smd": ("zanity", "Fast, deterministic sanity checks for code written by people and agents.", "index.shtml", "## Install", "## Rules"),
    "rules.smd": ("Rules", "Every rule zanity runs, what it flags, and how severe it is.", "page.shtml", "## Rules", "## Contributing"),
}


def section(readme: list[str], start: str, end: str) -> list[str]:
    """The README's lines from the heading start up to the heading end, headings one level up so
    the site's page title stays the only top heading."""
    first, last = readme.index(start), readme.index(end)
    assert first < last, f"README.md has '{end}' before '{start}'; keep the sections in order"
    assert last - first > 3, f"README.md's '{start}' section is empty"
    body, fenced = [], False
    for line in readme[first + (1 if start == "## Rules" else 0) : last]:
        fenced ^= line.startswith("```")
        body.append(heading(line[1:]) if line.startswith("##") and not fenced else line)
    return body


def heading(line: str) -> str:
    """A heading with the id GitHub gives it, so the README's links to its own sections work on
    the site too."""
    hashes, _, title = line.partition(" ")
    slug = re.sub(r"[^a-z0-9 -]", "", title.lower()).replace(" ", "-")
    assert set(hashes) == {"#"}, f"{line!r} is not a Markdown heading; pass a line beginning with one or more # characters"
    assert slug, f"the heading {line!r} has no letters or digits to make an id from; add a word or number"
    return f"{hashes} [{title}]($heading.id('{slug}'))"


def page(spec: tuple[str, str, str], body: list[str], order: int) -> str:
    """A SuperMD page: its title, description and layout, then body. order sets the date, which
    orders the pages."""
    title, description, layout = spec
    front = ["---", f'.title = "{title}",', f'.description = "{description}",', f'.date = .date("2026-10-17T00:00:0{order}"),', f'.layout = "{layout}",', "---", ""]
    assert '"' not in title + description, f"a quote in {title!r} or {description!r} would end the frontmatter string early"
    assert body, f"no content for {title}"
    return "\n".join(front + body).rstrip() + "\n"


def intro(readme: list[str]) -> list[str]:
    """The README's opening paragraphs, between its title and its first section."""
    start = readme.index("# zanity") + 1
    lines = readme[start : readme.index("## Install")]
    assert lines, f"README.md has nothing between its title, line {start}, and ## Install"
    html = [line for line in lines if line.startswith("<")]
    assert not html, f"SuperMD has no raw HTML; take {html[:2]} out of the README's opening"
    return [line for line in lines if not line.startswith("Fast, deterministic")]


CATALOGUE_RULE = re.compile(r"^(cwe|ext)-")


def catalogue_questions() -> list[str]:
    """A table of the questions --infer asks for each catalogue family no rule detects."""
    questions = json.loads((REPO / "catalogue" / "questions.json").read_text())
    assert questions, "catalogue/questions.json lists no questions; run catalogue/questions.py"
    asked = {"function": "each function", "file": "each file", "project": "the build and CI files"}
    rows = [f"| `{q['id'].lower()}` | {asked[q['scope']]} | {q['message'].partition('. ')[0]} | {q['severity']} |" for q in questions]
    assert len(rows) == len({q["id"] for q in questions}), "catalogue/questions.json lists a family twice"
    return [
        "",
        "# [Catalogue questions]($heading.id('catalogue-questions'))",
        "",
        f"With `--infer`, zanity also asks the model one question for each of {len(rows)} families of the engineering error catalogue that no deterministic rule detects. Each is a rule named for its family: select or disable it, or its whole family of findings, by that name.",
        "",
        "| Rule | Asked about | Finding | Severity |",
        "|---|---|---|---|",
        *rows,
    ]


def undescribed(rules_page: str) -> list[str]:
    """A table of the rules README.md doesn't describe, from what the schema says of each."""
    schema = json.loads((REPO / "zanity.schema.json").read_text())
    entries = [e for e in schema["definitions"]["rule"]["oneOf"] if not e["description"].startswith("The NASA code") and not CATALOGUE_RULE.match(e["const"])]
    missing = [e for e in entries if f"`{e['const']}`" not in rules_page]
    assert entries, "zanity.schema.json lists no rules; run `zig build schema`"
    assert len(missing) < len(entries), f"README.md's rules section describes none of the {len(entries)} rules; check its headings"
    if not missing:
        return []
    rows = []
    for entry in missing:
        when, _, advice = entry["description"].partition(". ")
        rows.append(f"| `{entry['const']}` | {when} | {advice} |")
    return ["", "# More rules", "", "What the schema says of the rules described above only by name, or not yet.", "", "| Rule | Severity | Fix |", "|---|---|---|", *rows]


def main() -> None:
    readme = (REPO / "README.md").read_text().splitlines()
    assert "# zanity" in readme, "README.md must start with its '# zanity' title"
    assert CONTENT.is_dir(), f"{CONTENT} is missing; the site's pages live there"
    written = {}
    for order, (name, (title, description, layout, start, end)) in enumerate(PAGES.items()):
        body = section(readme, start, end)
        if name == "index.smd":
            body = intro(readme) + body
        if name == "rules.smd":
            body += undescribed("\n".join(body)) + catalogue_questions()
        written[name] = page((title, description, layout), body, order)
    for name, text in written.items():
        (CONTENT / name).write_text(text)
        print(CONTENT / name)


if __name__ == "__main__":
    main()
