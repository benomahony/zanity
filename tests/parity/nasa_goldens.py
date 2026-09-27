import ast
import inspect
import sys
from pathlib import Path

import test_analyzer
from nasa_lsp import analyzer
from nasa_lsp.analyzer import DEFAULT_ENABLED_RULES, rule_severity

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
for stale in out.iterdir():
    stale.unlink()

cases: list[tuple[str, str, frozenset[str]]] = []
current = [""]


def recording(text, file_path=None, enabled_rules=None):
    rules = enabled_rules if enabled_rules is not None else DEFAULT_ENABLED_RULES
    cases.append((current[0], text, rules))
    return analyzer.analyze(text, file_path, rules)


test_analyzer.analyze = recording
for name, fn in inspect.getmembers(test_analyzer, inspect.isfunction):
    if not name.startswith("test_") or inspect.signature(fn).parameters:
        continue
    current[0] = name
    try:
        fn()
    except AssertionError:
        pass

seen: dict[str, int] = {}
for name, text, rules in cases:
    if not text.strip():
        continue
    seen[name] = seen.get(name, 0) + 1
    stem = name.removeprefix("test_") + (f"_{seen[name]}" if seen[name] > 1 else "")
    try:
        ast.parse(text)
    except (SyntaxError, ValueError):
        rules = frozenset({"parse-error"})
        found = [f"{stem}.py:1:1: warning [parse-error]"]
    else:
        diagnostics, _ = analyzer.analyze(text, None, rules)
        ordered = sorted(diagnostics, key=lambda d: (d.range.start.line, d.range.start.character, d.code))
        found = [
            f"{stem}.py:{d.range.start.line + 1}:{d.range.start.character + 1}: {rule_severity(d.code)} [{d.code}]"
            for d in ordered
        ]
    failing = any(line.split(": ", 2)[1].startswith("error") for line in found)
    lines = [f"rules: {','.join(sorted(rules))}", f"exit: {1 if failing else 0}", *found]
    (out / f"{stem}.py").write_text(text)
    (out / f"{stem}.expected").write_text("\n".join(lines) + "\n")
print(f"{len(list(out.glob('*.py')))} cases")
