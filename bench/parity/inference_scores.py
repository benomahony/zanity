"""Scoring zanity's --infer questions: against a live model on the fixtures, and how much of the
engineering error catalogue the questions cover."""

import json
import os
import re
import sqlite3
import subprocess
import tempfile
from collections import Counter
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
from tools import FIXTURES, HERE, QUESTIONS, REPO, SOURCES
from score import Server, Zanity


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
    assert question and rule, f"a live row needs both questions, not {question!r} and {rule!r}; map this rule in QUESTIONS in tools.py"
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
    assert row["theirs"] is None or 0 <= row["theirs"] <= 1, f"{question} has probability {row['theirs']}; fix the adapter so it reports a value from 0 to 1"
    return row


def listed_inference_rules() -> tuple[tuple[str, ...], bool]:
    """List the trusted local nouls checkout's rules without making model requests. Explicitly
    clear its live-analysis trigger even if the invoking shell has benchmark inference settings.
    Malformed output or child failure becomes ValueError for the comparison CLI to report."""
    environment = SOURCES / "nouls" / ".venv"
    interpreter = environment / "Scripts" / "python.exe" if os.name == "nt" else environment / "bin" / "python"
    adapter = HERE / "adapters" / "run_nouls.py"
    assert interpreter.is_absolute(), f"{interpreter} is relative; resolve ZANITY_PARITY_SOURCES before finding the adapter environment"
    assert adapter.parent == HERE / "adapters", f"{adapter} is not a parity adapter; use the harness-owned listing script"
    command = [str(interpreter), str(adapter), str(HERE)]
    result = subprocess.run(command, env=os.environ | {"NOULS_PARITY_RULES": ""}, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise ValueError(f"nouls rule listing exited with {result.returncode}: {result.stderr}; sync its environment and fix the adapter before rerunning parity.py")
    try:
        listed = json.loads(result.stdout)
    except ValueError as error:
        raise ValueError(f"nouls rule listing was not JSON: {error}; fix run_nouls.py's listing output and rerun parity.py") from error
    if not isinstance(listed, dict):
        raise ValueError("nouls rule listing must be an object with rules and key fields; fix run_nouls.py's listing output")
    names = listed.get("rules")
    if not isinstance(names, list) or not names or not all(isinstance(name, str) and name for name in names):
        raise ValueError("nouls rule listing needs a nonempty string array in rules; restore its config or fix the listing adapter")
    if len(names) != len(set(names)) or type(listed.get("key")) is not bool:
        raise ValueError("nouls rule listing needs unique rule names and a boolean key flag; fix the listing adapter's output")
    return tuple(names), listed["key"]


def validated_reference_records(text: str, source: str, prefixes: tuple[str, ...], container: str | None = None) -> list[dict]:
    """Validate catalogue IDs and optional deterministic-rule lists before indexing local JSON.
    Source labels and namespace policy are supplied by this module; malformed records fail with
    ValueError rather than leaking KeyError, TypeError or a partially interpreted catalogue."""
    assert source, "label the reference JSON so malformed records can be diagnosed"
    assert prefixes, "name the supported catalogue ID namespaces before validating reference records"
    try:
        records = json.loads(text)
    except ValueError as error:
        raise ValueError(f"{source} is not valid JSON: {error}; restore or regenerate the reference file") from error
    if container:
        if not isinstance(records, dict):
            raise ValueError(f"{source} needs an object containing {container}; regenerate the reference JSON")
        records = records.get(container)
    if not isinstance(records, list):
        raise ValueError(f"{source} needs an array of catalogue records; regenerate the reference JSON")
    seen = set()
    for position, record in enumerate(records):
        if not isinstance(record, dict):
            raise ValueError(f"{source} record {position} is not an object; regenerate the reference JSON")
        identity = record.get("id")
        if not isinstance(identity, str) or not identity.startswith(prefixes):
            raise ValueError(f"{source} record {position} has invalid id {identity!r}; restore its catalogue ID")
        if identity in seen:
            raise ValueError(f"{source} repeats {identity}; regenerate unique catalogue records")
        seen.add(identity)
        detected_by = record.get("rule_ids", [])
        if not isinstance(detected_by, list) or not all(isinstance(rule, str) and rule for rule in detected_by):
            raise ValueError(f"{source} {identity} has invalid rule_ids; list the deterministic rule names as strings")
    return records


def catalogue_coverage(catalogue: list[dict], asked: set[str]) -> dict:
    """Count validated reference families. Empty records deliberately represent unknown IDs;
    they cannot count as deterministic coverage, and optional rule_ids defaults to an empty list."""
    assert catalogue, "compare at least one listed catalogue question; validate the adapter listing before counting coverage"
    detected = Counter(rule for family in catalogue for rule in family.get("rule_ids", []))
    counts = {
        "asked": sum(family.get("id") in asked for family in catalogue),
        "catalogue": len(catalogue),
        "unknown": sum(not family for family in catalogue),
        "deterministic": sum(bool(family.get("rule_ids")) for family in catalogue),
        "detected_by": dict(detected.most_common()),
    }
    assert counts["deterministic"] + counts["unknown"] <= counts["catalogue"], f"counted {counts['deterministic']} deterministic and {counts['unknown']} unknown families out of {counts['catalogue']}; fix coverage classification"
    return counts


def score_inference(rules: dict[str, dict]) -> dict:
    """Compare a validated local rule listing against source-controlled catalogue snapshots.
    The caller supplies zanity_rules()'s generated metadata; QUESTIONS is copied once as a
    reference mapping. All comparison state is local and no module registry is modified."""
    assert rules, "pass the nonempty rule registry produced by zanity_rules before comparing inference coverage"
    flagless = sorted(name for name, entry in rules.items() if not isinstance(entry, dict) or type(entry.get("question")) is not bool)
    assert not flagless, f"zanity rule metadata for {flagless} needs boolean question flags; regenerate it with zanity_rules"
    listed, key_available = listed_inference_rules()
    catalogue_path = REPO / "catalogue" / "catalogue.json"
    entries = validated_reference_records(catalogue_path.read_text(), str(catalogue_path), ("CWE-", "EXT-"), "entries")
    families = {entry["id"]: entry for entry in entries}
    question_path = REPO / "catalogue" / "questions.json"
    question_records = validated_reference_records(question_path.read_text(), str(question_path), ("CWE-", "EXT-"))
    asked = {question["id"] for question in question_records}
    mapping = dict(QUESTIONS)
    named = [rule for rule in listed if not rule.startswith(("cwe_", "ext_"))]
    catalogue = [families.get(rule.upper().replace("_", "-"), {}) for rule in listed if rule not in named]
    unmapped = sorted(set(named) - mapping.keys())
    if unmapped:
        raise ValueError(f"nouls asks unmapped questions {unmapped}; add their zanity rule mappings in tools.py before comparing")
    if not catalogue:
        raise ValueError("nouls listed no catalogue questions; restore its catalogue config and rerun parity.py")
    # A measured slow-test rule covers this question without asking a model.
    questions = []
    for rule in named:
        code = mapping[rule]
        present = rules.get(code, {}).get("question", False) or (rule == "test_slow" and code in rules)
        questions.append({"rule": rule, "zanity": code, "present": present})
    return {"key": key_available, "questions": questions, **catalogue_coverage(catalogue, asked)}
