"""Run the test-quality linter's own rules over every file given, test-named or not."""

import sys

from _common import emit, files, finding
from testdesiderata.linter import Linter

linter = Linter()
out = []
for path in files(sys.argv[1:], (".py",)):
    out.extend(finding(path, v.line, v.rule_id) for v in linter.lint_file(path))
emit(out)
