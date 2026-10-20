"""Run the Power of Ten linter's own analyzer, every rule switched on."""

import sys

from _common import emit, files, finding
from nasa_lsp.analyzer import RULE_SEVERITY, DEFAULT_ENABLED_RULES, analyze

ALL = frozenset(RULE_SEVERITY) | DEFAULT_ENABLED_RULES

out = []
for path in files(sys.argv[1:], (".py",)):
    diagnostics, _ = analyze(path.read_text(), path, enabled_rules=ALL)
    out.extend(finding(path, d.range.start.line + 1, d.code) for d in diagnostics)
emit(out)
