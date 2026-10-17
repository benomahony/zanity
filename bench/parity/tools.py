"""The tools zanity replaces, how to run each through its own library, and which zanity rules
answer each of their rules."""

import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).parent.resolve()
REPO = HERE.parent.parent
# Checkouts of the old tools sit beside zanity's, each with its virtualenv synced.
SOURCES = Path(os.environ.get("ZANITY_PARITY_SOURCES", REPO.parent)).resolve()
FIXTURES = HERE / "fixtures"


@dataclass
class Tool:
    name: str
    adapter: str
    rules: dict[str, list[str]]
    # Old rules with no fixture, and why.
    unfixtured: dict[str, str] = field(default_factory=dict)
    # Where zanity differs on purpose, so a reader can tell a choice from a gap.
    notes: dict[str, str] = field(default_factory=dict)
    # Whether the adapter takes project directories rather than files.
    projects: bool = False

    @property
    def python(self) -> Path:
        assert self.name, "a tool needs a name to find its checkout"
        assert SOURCES.is_dir(), f"{SOURCES} holds the old tools' checkouts; set ZANITY_PARITY_SOURCES to where they are"
        return SOURCES / self.name / ".venv" / "bin" / "python"

    @property
    def targets(self) -> list[str]:
        """Every zanity rule mapped to one of this tool's rules."""
        found = sorted({target for targets in self.rules.values() for target in targets})
        assert self.rules, f"{self.name} maps no rules; list its rules in TOOLS"
        assert len(found) <= len(self.rules) * 2, f"{self.name} maps {len(found)} zanity rules; check TOOLS for a typo"
        return found

    def command(self, paths: list[Path]) -> list[str]:
        assert paths, f"running {self.name} on nothing; pass the fixtures or the corpus"
        assert (HERE / "adapters" / self.adapter).is_file(), f"adapters/{self.adapter} is missing; restore it from git"
        return [str(self.python), str(HERE / "adapters" / self.adapter), *map(str, paths)]

    def run(self, paths: list[Path]) -> list[dict]:
        """The tool's findings on paths, as path, line, end and rule."""
        out = subprocess.run(self.command(paths), capture_output=True, text=True, check=False)
        assert out.returncode == 0, f"{self.name} failed; run `uv sync` in {SOURCES / self.name} and retry:\n{out.stderr}"
        found = json.loads(out.stdout)
        stray = sorted({f["rule"] for f in found} - set(self.rules))
        assert not stray, f"{self.name} reported {stray}, which TOOLS doesn't map; add them to its rules"
        return found


DOUBLE = ["test-double"]
NONDETERMINISM = ["nondeterministic-test"]
CALLS = ["call-verification"]
VOCABULARY = ["vocabulary-conflict"]

TOOLS = [
    Tool(
        "nasa-lsp",
        "run_nasa.py",
        {
            "NASA01-A": ["forbidden-call"],
            "NASA01-B": ["recursion"],
            "NASA02": ["unbounded-loop"],
            "NASA04": ["long-function"],
            "NASA05": ["assertion-density"],
            "NASA05-A": ["assertion-message"],
            "NASA05-M1": ["restated-type"],
            "NASA05-M2": ["constant-assertion"],
            "NASA05-M3": ["redundant-null-check"],
            "NASA05-M4": ["conversion-assertion"],
            "NASA05-M5": ["guaranteed-length"],
        },
        notes={
            "NASA01-A": "zanity reports getattr and setattr only when the attribute name is not a literal",
            "NASA05": "zanity doesn't count assertions that restate a type or can never fail",
        },
    ),
    Tool(
        "testdesiderata",
        "run_testdesiderata.py",
        {
            "AUT001": ["stdin-in-test", "debug-leftover"],
            "AUT002": ["debug-leftover"],
            "BHV001": DOUBLE,
            "BHV002": DOUBLE,
            "BHV003": DOUBLE,
            "BHV004": DOUBLE,
            "CMP001": ["eager-test"],
            "CMP002": ["long-test"],
            "DET001": NONDETERMINISM,
            "DET002": NONDETERMINISM,
            "DET003": NONDETERMINISM,
            "DET004": NONDETERMINISM,
            "DET005": NONDETERMINISM,
            "DET006": NONDETERMINISM,
            "FST001": ["sleep-in-test"],
            "FST002": ["polling-loop"],
            "FST003": ["slow-test"],
            "ISO001": ["shared-state-in-test"],
            "ISO002": ["shared-state-in-test"],
            "ISO003": ["filesystem-in-test"],
            "ISO004": ["network-in-test"],
            "ISO005": ["database-in-test"],
            "ISO006": ["unmanaged-temp-in-test"],
            "ISO007": ["filesystem-in-test"],
            "ISO008": ["process-in-test"],
            "PRD001": ["skipped-test"],
            "PRD002": ["skipped-test"],
            "PRD003": ["skipped-test"],
            "RDL001": ["vague-test-name"],
            "RDL002": ["undocumented-test"],
            "SPC001": ["generic-catch", "swallowed-error"],
            "SPC002": ["opaque-check", "assertion-message"],
            "SPC003": ["broad-expected-error"],
            "STR001": CALLS,
            "STR002": CALLS,
            "STR003": CALLS,
            "STR004": CALLS,
            "STR005": CALLS,
            "STR006": CALLS,
        },
        unfixtured={"FST003": "it reads test durations from a JUnit report, not the source"},
        notes={
            "FST003": "zanity asks slow-test with --infer, and reads no JUnit timings",
            "ISO003": "zanity reports reads and writes of real paths, not of the test's own temporary directory",
        },
    ),
    Tool(
        "mockbuster",
        "run_mockbuster.py",
        {
            "mocker-fixture": DOUBLE,
            "monkeypatch-fixture": DOUBLE,
            "patch-decorator": DOUBLE,
            "mock-instantiation": DOUBLE,
            "patch-context": DOUBLE,
            "patch-call": DOUBLE,
        },
        notes={
            "mocker-fixture": "zanity reports the double where it is made, such as mocker.patch, not the parameter",
            "monkeypatch-fixture": "zanity reports monkeypatch.setattr, which replaces behaviour, not setenv or the parameter",
        },
    ),
    Tool(
        "dddlint",
        "run_dddlint.py",
        {
            "forbidden": ["forbidden-term"],
            "forbidden:module": ["forbidden-term"],
            "alias": ["non-canonical-term"],
            "alias:module": ["non-canonical-term"],
            "duplicate": ["duplicate-name"],
            "drift": ["name-drift"],
            "test-domain-drift": ["misplaced-test"],
            "config:alias-conflict": VOCABULARY,
            "config:duplicate-name": VOCABULARY,
            "config:forbidden-canonical-clash": VOCABULARY,
            "near-synonym": [],
            "context-outlier": [],
        },
        unfixtured={
            "near-synonym": "it comes from an embedding model in `dddlint map`, not from lint",
            "context-outlier": "it comes from an embedding model in `dddlint map`, not from lint",
        },
        notes={
            "near-synonym": "zanity has no embedding features yet",
            "context-outlier": "zanity has no embedding features yet",
            "duplicate": "zanity reports only names another file can use, and not methods of different classes",
        },
        projects=True,
    ),
    Tool(
        "bonsai",
        "run_bonsai.py",
        {
            "dead-parameter": ["dead-parameter"],
            "dead-symbol": ["dead-symbol"],
            "duplicated-expression": ["duplicated-expression"],
            "empty-handler": ["swallowed-error", "empty-block"],
            "extractable-chunk": ["extractable-block"],
            "long-function": ["long-function"],
            "long-parameter-list": ["long-parameter-list"],
            "message-chains": ["message-chain"],
            "passthrough-wrapper": ["passthrough-wrapper"],
            "single-impl-abstraction": ["single-impl-abstraction"],
            "structural-twins": ["structural-twins"],
        },
        notes={"long-function": "bonsai flags 30 lines; zanity flags 60, as Power of Ten says"},
        projects=True,
    ),
]
BY_NAME = {tool.name: tool for tool in TOOLS}

# The inference linter's named questions, and the zanity --infer question that asks the same.
QUESTIONS = {
    "name_behaviour_mismatch": "name-behaviour-mismatch",
    "docstring_drift": "comment-drift",
    "query_with_side_effect": "query-with-side-effect",
    "partial_failure": "partial-failure",
    "check_then_act": "check-then-act",
    "non_idempotent_retry": "non-idempotent-retry",
    "unit_mismatch": "unit-mismatch",
    "boundary_error": "boundary-error",
    "missing_authorisation": "missing-authorisation",
    "misleading_error": "misleading-error",
    "cryptic_error": "cryptic-error",
    "vague_error": "vague-error",
    "unconstructive_error": "unconstructive-error",
    "mixed_abstraction": "mixed-abstraction",
    "relaxed_warnings": "weakened-check",
    "unscheduled_static_analysis": "unscheduled-analysis",
    "test_not_isolated": "order-dependent-test",
    "test_not_composable": "combinatorial-test",
    "test_nondeterministic": "flaky-test",
    "test_slow": "slow-test",
    "test_hard_to_write": "heavy-setup-test",
    "test_unreadable": "unreadable-test",
    "test_not_behavioural": "hollow-test",
    "test_structure_sensitive": "implementation-coupled-test",
    "test_not_automated": "manual-test",
    "test_not_specific": "unfocused-test",
    "test_not_predictive": "self-mocking-test",
    "test_not_inspiring": "trivial-test",
    "fixture_leaks_state": "",
    "fixture_hides_behaviour": "",
}


def expected_rule(tool: Tool, unit: Path) -> str:
    """The old rule a fixture exists to trigger, from its file or directory name."""
    assert unit.exists(), f"fixture {unit} is missing"
    assert tool.name in BY_NAME, f"{tool.name} has fixtures but no entry in TOOLS; add it there with its rules"
    stem = unit.stem.removeprefix("test_")
    names = {
        "nasa-lsp": unit.stem,
        "testdesiderata": stem.upper(),
        "mockbuster": stem.replace("_", "-"),
        "dddlint": unit.name.replace("config-", "config:", 1).replace("-module", ":module"),
    }
    return names[tool.name]


def fixture_units(tool: Tool) -> list[Path]:
    """The tool's fixtures: one file, or one project directory, per rule."""
    root = FIXTURES / tool.name
    assert root.is_dir(), f"{root} is missing; each tool but bonsai needs fixtures"
    units = sorted(p for p in root.iterdir() if p.is_dir()) if tool.projects else sorted(root.glob("*.py"))
    assert units, f"{root} has no fixtures"
    return units
