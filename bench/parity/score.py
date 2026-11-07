"""Run zanity beside each old tool and score what both find."""

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from tools import BY_NAME, FIXTURES, HERE, REPO, SOURCES, TOOLS, Tool, expected_rule, fixture_units

CORPUS = HERE / ".corpus"
LANGUAGES = ["python", "javascript", "typescript", "go", "rust", "java"]
# Below this, missing dependency checkouts can make benchmark timings misleading.
MIN_CORPUS_PYTHON_FILES = 101
# Real code for recall and timing: two widely used libraries, and the old tools' own pytest
# suites, which are full of the doubles and fixtures the test rules look for.
CORPUS_SOURCES = {
    "rich": "nasa-lsp/.venv/lib/python3.13/site-packages/rich",
    "click": "dddlint/.venv/lib/python3.12/site-packages/click",
    "tests/nasa-lsp": "nasa-lsp/tests",
    "tests/nouls": "nouls/tests",
    "tests/dddlint": "dddlint/tests",
    "tests/testdesiderata": "testdesiderata/tests",
    "tests/mockbuster": "mockbuster/tests",
}


@dataclass
class Zanity:
    binary: Path
    store: Path

    def env(self, store: Path | None = None) -> dict[str, str]:
        """The environment with a private cache, and without the variables that switch on agent output."""
        assert self.binary.is_file(), f"{self.binary} is missing; run `zig build` first"
        assert self.store.parent.is_dir(), f"{self.store.parent} must exist to hold zanity's cache"
        env = {k: v for k, v in os.environ.items() if k not in {"CLAUDECODE", "ZANITY_AGENT"}}
        env["ZANITY_STORE"] = str(store or self.store)
        return env

    def check(self, cwd: Path, rules: list[str]) -> list[dict]:
        """zanity's findings for everything under cwd, from only these rules."""
        args = [str(self.binary), "check", "--json", "--quiet", "--rules", ",".join(sorted(set(rules))), "."]
        out = subprocess.run(args, cwd=cwd, env=self.env(), capture_output=True, text=True, check=False)
        assert out.returncode <= 1, f"zanity failed in {cwd}:\n{out.stderr}\nFix that error, then rerun parity.py"
        found = json.loads(out.stdout or "[]")
        for f in found:
            f["path"] = str((cwd / f["path"]).resolve())
        unplaced = [f for f in found if f["line"] < 1]
        assert not unplaced, f"zanity reports lines from 1, but gave {unplaced[:3]}; fix the reported locations in zanity"
        return found


@dataclass
class Server:
    """A System One server both tools ask, such as a local Kev, and the model to ask."""

    url: str
    model: str

    def env(self, base: dict[str, str]) -> dict[str, str]:
        """base with the variables both tools read to find the server; a local Kev needs no key,
        but the inference linter's client wants one set. Preserve the caller's real key; the
        placeholder only satisfies the optional-key client and cannot bypass server authentication."""
        assert self.url.startswith(("http://", "https://")), f"{self.url} is not a server's address"
        assert self.model, "name the model the server runs"
        return base | {"TYPESAFE_BASE_URL": self.url, "TYPESAFE_DEFAULT_MODEL": self.model, "TYPESAFE_API_KEY": base.get("TYPESAFE_API_KEY") or "local"}


def zanity_rules() -> dict[str, dict]:
    """Every zanity rule with its severity, its tier, and whether --infer asks it, from the schema
    the code writes and from rules.zig."""
    schema = json.loads((REPO / "zanity.schema.json").read_text())
    entries = [e for e in schema["definitions"]["rule"]["oneOf"] if not e["description"].startswith("The NASA code")]
    rules = {}
    for entry in entries:
        severity, _, rest = entry["description"].partition(", ")
        tier, _, advice = rest.partition(". ")
        rules[entry["const"]] = {"severity": severity, "tier": tier, "advice": advice, "question": False}
    for name in re.findall(r'\.name = "([a-z-]+)"[^\n]*\.question = "', (REPO / "src" / "rules.zig").read_text()):
        rules[name]["question"] = True
    assert rules, "zanity.schema.json lists no rules; run `zig build schema`"
    assert any(r["question"] for r in rules.values()), "found no --infer questions in src/rules.zig"
    return rules


def near(old: dict, new: dict) -> bool:
    """Whether new lies on old's lines, give or take one: tools disagree on whether a function's
    finding sits on its decorator, its def or its name."""
    assert old["line"] >= 0, f"lines count from 1, or 0 for a whole file, but {old} starts at {old['line']}"
    assert old.get("end", old["line"]) >= old["line"], f"{old} ends before it starts"
    return old["path"] == new["path"] and old["line"] - 1 <= new["line"] <= old.get("end", old["line"]) + 1


def matches(tool: Tool, rule: str, old: dict, new: dict) -> bool:
    """Whether zanity's finding answers the old one: on its lines, or for a rule in the tool's
    same_file, anywhere in its file."""
    assert rule in tool.rules, f"{rule} is not one of {tool.name}'s rules"
    assert tool.same_file <= set(tool.rules), f"{tool.name}'s same_file names {sorted(tool.same_file - set(tool.rules))}, which it doesn't map"
    return near(old, new) or (rule in tool.same_file and old["path"] == new["path"])


def inside(unit: Path, found: list[dict]) -> list[dict]:
    """The findings in a fixture file, or anywhere in a fixture project."""
    assert unit.is_absolute(), f"{unit} must be absolute to compare with absolute finding paths"
    paths = [Path(f["path"]) for f in found]
    relative = [path for path in paths if not path.is_absolute()]
    assert not relative, f"findings carry absolute paths, but these don't: {relative[:3]}"
    return [f for f, path in zip(found, paths) if path == unit or unit in path.parents]


@dataclass
class Runs:
    """What the old tool found in the fixtures, what zanity found with the mapped rules, and what
    it found with every rule."""

    old: list[dict]
    new: list[dict]
    everything: list[dict]


def having(found: list[dict], rules: set[str] | list[str]) -> list[dict]:
    """The findings of these rules."""
    assert isinstance(rules, (set, list)), f"pass rule names as a set or list, not {rules!r}, which would match by substring"
    assert all(r for r in rules), f"an empty rule name in {rules}"
    return [f for f in found if f["rule"] in rules]


def fixture_row(tool: Tool, unit: Path, runs: Runs) -> dict:
    """One rule's fixture: whether the old tool fired it, and whether zanity did, on which lines."""
    rule = expected_rule(tool, unit)
    targets = tool.rules[rule]
    fired, answered = having(inside(unit, runs.old), [rule]), having(inside(unit, runs.new), targets)
    # A vocabulary problem sits in each tool's own config file, so no line can match.
    same_line = None if rule.startswith("config:") else any(matches(tool, rule, o, n) for o in fired for n in answered)
    others = {f["rule"] for f in inside(unit, runs.everything)}
    assert targets, f"{tool.name} {rule} has a fixture but maps to no zanity rule; map it in tools.py"
    assert unit.is_relative_to(HERE), f"{unit} must sit under {HERE}"
    return {
        "tool": tool.name,
        "rule": rule,
        "zanity": sorted({f["rule"] for f in answered}) or targets,
        "old_fires": bool(fired),
        "zanity_fires": bool(answered),
        "same_line": same_line,
        "others": sorted(others - set(targets)),
        "note": tool.notes.get(rule, ""),
    }


def unfixtured_rows(tool: Tool) -> list[dict]:
    rows = [
        {
            "tool": tool.name,
            "rule": rule,
            "zanity": tool.rules[rule],
            "old_fires": None,
            "zanity_fires": None,
            "same_line": None,
            "others": [],
            "note": f"No fixture: {why}. {tool.notes.get(rule, '')}".strip(),
        }
        for rule, why in tool.unfixtured.items()
    ]
    assert len(rows) == len(tool.unfixtured), "one row per unfixtured rule; add or remove the mismatched unfixtured entry"
    assert all(r["rule"] in tool.rules for r in rows), f"{tool.name} lists an unfixtured rule it doesn't map; add its mapping in tools.py"
    return rows


def score_fixtures(tool: Tool, zanity: Zanity) -> list[dict]:
    """Each fixture scored: the old tool must fire its rule, then zanity runs the mapped rules, and
    again with every rule to show what else it says."""
    units = fixture_units(tool)
    roots = units if tool.projects else [FIXTURES / tool.name]
    runs = Runs(
        tool.run(roots),
        [f for root in roots for f in zanity.check(root, tool.targets)],
        [f for root in roots for f in zanity.check(root, ["all"])],
    )
    rows = [fixture_row(tool, unit, runs) for unit in units] + unfixtured_rows(tool)
    assert len(rows) == len(tool.rules), f"{tool.name} has {len(tool.rules)} rules and {len(rows)} rows; give each rule a fixture or an unfixtured reason"
    assert {r["rule"] for r in rows} == set(tool.rules), f"{tool.name}'s fixtures don't match its rules"
    return rows


def recall(tool: Tool, old: list[dict], new: list[dict]) -> dict[str, dict]:
    """Per old rule that fired: its findings, and how many zanity reports on the same lines."""
    out = {}
    for rule, targets in tool.rules.items():
        fired, answered = having(old, [rule]), having(new, targets)
        if fired:
            out[rule] = {"old": len(fired), "matched": sum(any(matches(tool, rule, o, n) for n in answered) for o in fired)}
    overcounted = {rule: s for rule, s in out.items() if s["matched"] > s["old"]}
    assert not overcounted, f"a finding matches at most once, but {overcounted} matched more than were found; fix recall's matching loop"
    assert set(out) <= set(tool.rules), f"recall scored {sorted(set(out) - set(tool.rules))}, which {tool.name} doesn't map; add or remove those mappings in tools.py"
    return out


def agreement(tool: Tool, old: list[dict], new: list[dict]) -> dict[str, dict]:
    """Per zanity rule that fired: its findings, and how many sit on a finding of an old rule
    mapped to it."""
    out = {}
    for target in tool.targets:
        sources = {rule for rule, targets in tool.rules.items() if target in targets}
        fired, answered = having(old, sources), having(new, [target])
        if answered:
            out[target] = {"zanity": len(answered), "matched": sum(any(near(o, n) for o in fired) for n in answered)}
    overcounted = {rule: s for rule, s in out.items() if s["matched"] > s["zanity"]}
    assert not overcounted, f"a finding matches at most once, but {overcounted} matched more than were found; fix agreement's matching loop"
    assert set(out) <= set(tool.targets), f"agreement scored {sorted(set(out) - set(tool.targets))}, which {tool.name} doesn't map to; correct its targets in tools.py"
    return out


def score_languages(zanity: Zanity) -> dict[str, dict]:
    """bonsai's own fixtures in six languages, in place, scored finding by finding."""
    tool = BY_NAME["bonsai"]
    out = {}
    for language in LANGUAGES:
        root = SOURCES / "bonsai" / "tests" / "fixtures" / language
        old, new = tool.run([root]), zanity.check(root, tool.targets)
        out[language] = {"recall": recall(tool, old, new), "agreement": agreement(tool, old, new)}
    assert set(out) == set(LANGUAGES), f"scored {sorted(out)}, not every one of {LANGUAGES}"
    assert any(scored["recall"] for scored in out.values()), f"bonsai found nothing in its own fixtures under {SOURCES / 'bonsai'}; check its checkout"
    return out


def populate_corpus(destination: Path, sources: dict[str, Path]) -> dict[str, int]:
    """Build an unpublished corpus from the fixed source manifest. Source checkouts are read
    only; every tree is copied once and the completed copy is counted in one content pass.
    The caller owns this staging directory and discards it on any copy/count failure."""
    assert destination.is_absolute(), f"{destination} must be an absolute staging path; create it beneath the harness first"
    assert sources, "the corpus source manifest is empty; restore CORPUS_SOURCES before benchmarking"
    for name, source in sources.items():
        shutil.copytree(source, destination / name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    # dddlint's generated config checks duplicates and drift without imposing a vocabulary.
    (destination / "dddlint.yaml").write_text("forbidden: []\n")
    files = list(destination.rglob("*.py"))
    return {"files": len(files), "lines": sum(len(path.read_text(errors="replace").splitlines()) for path in files)}


def publish_corpus() -> dict[str, int]:
    """Build a new corpus in a staging directory, check its size, then swap it in for CORPUS,
    putting the previous one back if the swap fails. The caller holds the build lock. The backup
    is deleted unless restoring it failed, in which case it stays beside CORPUS."""
    with tempfile.TemporaryDirectory(prefix=".corpus-build-", dir=HERE) as temporary:
        staged = Path(temporary) / "corpus"
        sources = {name: SOURCES / source for name, source in CORPUS_SOURCES.items()}
        stats = populate_corpus(staged, sources)
        assert stats["files"] >= MIN_CORPUS_PYTHON_FILES, f"only {stats['files']} corpus files; restore the dependency checkouts in CORPUS_SOURCES to reach at least {MIN_CORPUS_PYTHON_FILES}"
        assert stats["lines"] >= stats["files"], f"only {stats['lines']} lines in {stats['files']} corpus files; inspect missing or empty dependency copies before benchmarking"
        backup_directory = Path(tempfile.mkdtemp(prefix=".corpus-previous-", dir=HERE))
        previous = backup_directory / "corpus"
        published = False
        try:
            try:
                CORPUS.rename(previous)
            except FileNotFoundError:
                staged.rename(CORPUS)
                published = True
                return stats
            try:
                staged.rename(CORPUS)
                published = True
            finally:
                if not published:
                    previous.rename(CORPUS)
            return stats
        finally:
            if published or not previous.exists():
                shutil.rmtree(backup_directory)


def build_corpus() -> dict[str, int]:
    """Regenerate the CLI's private .corpus cache, never any source checkout. Immutable module
    constants define source locations and minimum size. A directory lock serializes builders;
    publication owns staging, validates the complete copy and restores the old cache on failure."""
    assert CORPUS == HERE / ".corpus", f"{CORPUS} is not the harness's generated cache; restore its fixed location beneath {HERE}"
    lock = HERE / ".corpus.lock"
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ValueError(f"corpus build lock {lock} exists; wait for the other benchmark, or remove a crashed build's lock only after confirming no builder is running") from error
    try:
        stats = publish_corpus()
        assert stats["files"] >= MIN_CORPUS_PYTHON_FILES, f"published only {stats['files']} files; fix corpus validation before benchmarking"
        return stats
    finally:
        lock.rmdir()


def score_corpus(zanity: Zanity) -> dict[str, dict]:
    out = {}
    for tool in TOOLS:
        old, new = tool.run([CORPUS]), zanity.check(CORPUS, tool.targets)
        out[tool.name] = {"recall": recall(tool, old, new), "agreement": agreement(tool, old, new)}
    assert set(out) == set(BY_NAME), "every tool scored on the corpus"
    assert out["nasa-lsp"]["recall"], "nasa-lsp found nothing in the corpus; check its checkout"
    return out

