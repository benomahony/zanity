"""Run the mock detector; it has no rule codes, so name each finding by what its message reports."""

import re
import sys

from _common import emit, files, finding
from mockbuster.core import detect_mocks

KINDS = [
    (r"'mocker' fixture", "mocker-fixture"),
    (r"'monkeypatch' fixture", "monkeypatch-fixture"),
    (r"^@\S+ decorator", "patch-decorator"),
    (r"\(\) instantiation", "mock-instantiation"),
    (r"\(\) context manager", "patch-context"),
    (r"\(\) call detected", "patch-call"),
]


def kind(message: str) -> str:
    """The kind of double a message reports; an unknown one surfaces as a rule the mapping lacks."""
    assert message, "mockbuster reported a finding with no message"
    assert len(KINDS) == len({name for _, name in KINDS}), f"KINDS names a kind twice: {KINDS}"
    return next((name for pattern, name in KINDS if re.search(pattern, message)), "unknown:" + message[:40])


out = []
for path in files(sys.argv[1:], (".py",)):
    out.extend(finding(path, v["line"], kind(v["message"])) for v in detect_mocks(path.read_text()))
emit(out)
