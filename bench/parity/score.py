"""Run zanity beside each old tool and score what both find."""

import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
from collections import Counter
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

from tools import BY_NAME, FIXTURES, HERE, QUESTIONS, REPO, SOURCES, TOOLS, Tool, expected_rule, fixture_units

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


def settled_by() -> dict[str, list[str]]:
    """The deterministic rules whose finding already answers each zanity question, from rules.zig."""
    text = (REPO / "src" / "rules.zig").read_text()
    found = {m.group(1): re.findall(r'"([^"]+)"', m.group(2)) for m in re.finditer(r'\.name = "([a-z-]+)"[^\n]*?\.settled_by = &\.\{([^}]*)\}', text)}
    assert found, "found no settled_by in src/rules.zig; check the pattern"
    assert all(found.values()), f"an empty settled_by in {found}"
    return found


def decoded_records(output: str, producer: str, field_types: dict[str, tuple[type, ...]]) -> list[dict]:
    """Validate the JSON record protocol emitted by a benchmark child. Output/shape failures
    become actionable ValueError messages for the comparison CLI's operational-error boundary."""
    assert producer, "name the benchmark child whose JSON is being decoded"
    assert field_types, "specify the required fields of the child's record protocol"
    try:
        records = json.loads(output)
    except ValueError as error:
        raise ValueError(f"{producer} did not emit JSON records: {error}; fix its adapter or command, then rerun parity.py") from error
    if not isinstance(records, list):
        raise ValueError(f"{producer} returned {type(records).__name__}, not a JSON array; fix the adapter's record protocol")
    for position, record in enumerate(records):
        if not isinstance(record, dict):
            raise ValueError(f"{producer} record {position} is not an object; fix the adapter's record protocol")
        for field, accepted_types in field_types.items():
            value = record.get(field)
            if type(value) not in accepted_types or value == "":
                raise ValueError(f"{producer} record {position} has invalid {field}={value!r}; fix the adapter's record protocol")
        if "probability" in field_types and not 0 <= record["probability"] <= 1:
            raise ValueError(f"{producer} record {position} has probability {record['probability']}; return a value between 0 and 1")
    return records


def inference_observations(store: Path, rules: set[str]) -> list[dict]:
    """Read the public observations schema of one completed zanity child, read-only. This is
    the cross-language result adapter, not an application repository; both cursor and connection
    close before the caller deletes its private temporary store. Database failures become ValueError."""
    assert store.is_absolute(), f"{store} is relative; create the inference store in the comparison's temporary directory"
    assert rules, "pass the selected rules so unexpected cache observations can be diagnosed"
    fields = ("path", "rule", "probability", "threshold", "fired")
    try:
        with closing(sqlite3.connect(store.as_uri() + "?mode=ro", uri=True)) as connection:
            with closing(connection.execute("SELECT path, rule, probability, threshold, fired FROM observations")) as cursor:
                rows = [dict(zip(fields, row)) for row in cursor.fetchall()]
    except sqlite3.Error as error:
        raise ValueError(f"could not read inference observations from {store}: {error}; check that zanity completed --infer with this store") from error
    unexpected = sorted({row["rule"] for row in rows} - rules)
    if unexpected:
        raise ValueError(f"fresh inference store {store} contains unselected rules {unexpected}; fix the benchmark's rule selection")
    if not rows:
        raise ValueError(f"zanity kept no inference observations in {store}; fix the model/server failure or missing fixture units before comparing")
    return rows


def named_fixture_questions(fixture_files: set[str]) -> dict[str, str]:
    """Select fixture-backed inference questions from one directory snapshot. Slow tests are
    measured from JUnit reports, and are deliberately not model questions."""
    assert fixture_files, "no inference Python fixtures were found; restore fixtures/nouls before running the live comparison"
    named = {q: z for q, z in QUESTIONS.items() if q != "test_slow" and (f"{q}.py" in fixture_files or f"test_{q}.py" in fixture_files)}
    assert named, f"none of {len(fixture_files)} fixture files matches QUESTIONS; fix the fixture names or question mapping"
    return named


def score_inference_live(zanity: Zanity, server: Server) -> list[dict]:
    """Compare model answers for the CLI's fixed local fixtures, on the server the invoking
    user explicitly selected. This benchmark runs trusted local tools with that user's authority;
    it exposes no command or file capability to a remote caller. One directory scan selects
    fixtures, and one private, short-lived store plus one read-only query owns zanity's results."""
    root = FIXTURES / "nouls"
    with os.scandir(root) as entries:
        fixture_files = {entry.name for entry in entries if entry.is_file() and entry.name.endswith(".py")}
    named = named_fixture_questions(fixture_files)
    names = {q: f"{q}.py" if f"{q}.py" in fixture_files else f"test_{q}.py" for q in named}
    environment = SOURCES / "nouls" / ".venv"
    interpreter = environment / "Scripts" / "python.exe" if os.name == "nt" else environment / "bin" / "python"
    adapter = [str(interpreter), str(HERE / "adapters" / "run_nouls.py"), str(root)]
    output = subprocess.run(adapter, env=server.env(os.environ | {"NOULS_PARITY_RULES": ",".join(named)}), capture_output=True, text=True, check=False)
    if output.returncode != 0:
        raise ValueError(f"nouls adapter exited with {output.returncode}: {output.stderr}; sync its environment and fix the reported server/adapter failure before rerunning parity.py")
    theirs = decoded_records(output.stdout, "nouls", {"path": (str,), "rule": (str,), "probability": (int, float), "fired": (bool,)})
    settles = settled_by()
    rules = {z for z in named.values()} | {r for z in named.values() for r in settles.get(z, [])}
    with tempfile.TemporaryDirectory(prefix="parity-inference-") as temporary:
        store = Path(temporary) / "store.db"
        args = [str(zanity.binary), "check", "--infer", "--json", "--quiet", "--rules", ",".join(sorted(rules)), "."]
        out = subprocess.run(args, cwd=root, env=server.env(zanity.env(store)), capture_output=True, text=True, check=False)
        if out.returncode not in (0, 1):
            raise ValueError(f"zanity check --infer exited with {out.returncode} in {root}: {out.stderr}; fix the reported model/server or checker failure before rerunning parity.py")
        reported = decoded_records(out.stdout, "zanity", {"path": (str,), "rule": (str,)})
        ours = inference_observations(store, rules)
    answers = Answers(theirs, ours, reported, settles)
    rows = [live_row(question, rule, names[question], answers) for question, rule in named.items()]
    assert rows, f"no comparison rows were produced for {len(named)} questions in {root}; fix the adapter's fixture results"
    assert len(rows) == len(named), f"made {len(rows)} rows for {len(named)} questions; fix live_row to keep one result per fixture"
    return rows


@dataclass
class Answers:
    """What both tools said about the fixtures: the inference linter's answers, zanity's answers,
    zanity's findings, and which deterministic rules settle each zanity question."""

    theirs: list[dict]
    ours: list[dict]
    reported: list[dict]
    settles: dict[str, list[str]]


def live_row(question: str, rule: str, name: str, a: Answers) -> dict:
    """Both tools' answers to one question about its own fixture."""
    assert question and rule, f"a live row needs both questions, not {question!r} and {rule!r}"
    mine = [o for o in a.theirs if Path(o["path"]).name == name and o["rule"] == question]
    zans = [o for o in a.ours if Path(o["path"]).name == name and o["rule"] == rule]
    found = {f["rule"] for f in a.reported if Path(f["path"]).name == name}
    settled = sorted(found & set(a.settles.get(rule, [])))
    row = {
        "rule": question,
        "zanity": rule,
        "theirs": max((o["probability"] for o in mine), default=None),
        "theirs_fires": any(o["fired"] for o in mine),
        "ours": max((o["probability"] for o in zans), default=None),
        "ours_fires": rule in found or bool(settled),
        "settled": settled,
    }
    assert row["theirs"] is None or 0 <= row["theirs"] <= 1, f"{question} has probability {row['theirs']}"
    return row


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
    """Construct and validate a replacement for the fixed harness-owned CORPUS cache. All
    staging/backup paths are private directories created here beneath HERE, not caller input.
    The caller holds the build lock. Rollback runs in finally, including on interruption; if a
    filesystem failure prevents restoration, its rename error names the retained recovery backup."""
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


def score_inference(rules: dict[str, dict]) -> dict:
    """nouls' questions, listed through its own config loader, against zanity's --infer questions
    and the catalogue families zanity's deterministic rules detect."""
    adapter = [str(SOURCES / "nouls" / ".venv" / "bin" / "python"), str(HERE / "adapters" / "run_nouls.py"), str(HERE)]
    listed = json.loads(subprocess.run(adapter, capture_output=True, text=True, check=True).stdout)
    families = {e["id"]: e for e in json.loads((REPO / "catalogue" / "catalogue.json").read_text())["entries"]}
    named = [rule for rule in listed["rules"] if not rule.startswith(("cwe_", "ext_"))]
    catalogue = [families.get(rule.upper().replace("_", "-"), {}) for rule in listed["rules"] if rule not in named]
    unmapped = sorted(set(named) - set(QUESTIONS))
    assert not unmapped, f"nouls asks {unmapped}, which QUESTIONS in tools.py doesn't map"
    assert catalogue, "nouls listed no catalogue questions; check its config"
    # A measured slow-test rule covers this question without asking a model.
    questions = []
    for rule in named:
        code = QUESTIONS[rule]
        present = rules.get(code, {}).get("question", False) or (rule == "test_slow" and code in rules)
        questions.append({"rule": rule, "zanity": code, "present": present})
    detected = Counter(rule for family in catalogue for rule in family.get("rule_ids", []))
    asked = {q["id"] for q in json.loads((REPO / "catalogue" / "questions.json").read_text())}
    return {
        "asked": sum(family.get("id") in asked for family in catalogue),
        "key": listed["key"],
        "questions": questions,
        "catalogue": len(catalogue),
        "unknown": sum(not family for family in catalogue),
        "deterministic": sum(bool(family.get("rule_ids")) for family in catalogue),
        "detected_by": dict(detected.most_common()),
    }
