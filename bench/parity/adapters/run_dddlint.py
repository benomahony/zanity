"""Run the naming linter's own lint over each project given; each needs a dddlint.yaml at its root."""

import sys
from pathlib import Path

from _common import emit, finding
from dddlint.check import check
from dddlint.cli import _collect
from dddlint.config import load_config
from dddlint.config_check import check_config

out = []
for arg in sys.argv[1:]:
    root = Path(arg).resolve()
    config = root / "dddlint.yaml"
    settings = load_config(config)
    found = check_config(settings, config) + check(_collect(root, settings.exclude, root, paths=True), settings)
    out.extend(finding(f.path if Path(f.path).is_absolute() else root / f.path, f.line + 1, f.rule) for f in found)
emit(out)
