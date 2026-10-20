"""Run the smell finder's own index and smells over each directory given."""

import sys
from pathlib import Path

from _common import emit, finding
from bonsai.db import connect
from bonsai.pruner import scan_directory

out = []
for arg in sys.argv[1:]:
    root = Path(arg).resolve()
    for f in scan_directory(root, connect(":memory:")):
        path = Path(f.file) if Path(f.file).is_absolute() else root / f.file
        out.append(finding(path, f.start_line, f.smell, f.end_line))
emit(out)
