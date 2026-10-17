"""Run Lizard's own analysis and warning filter at its default limits, with its nesting depth,
nested structures and cognitive complexity extensions."""

import sys

import lizard
from _common import emit, files, finding

option = lizard.parse_args(["lizard", "-END", "-ENS", "-Ecognitive"])
paths = [str(path) for path in files(sys.argv[1:], (".py",))]
out = []
for fun in lizard.get_warnings(lizard.analyze_files(paths, exts=option.extensions), option):
    forgiven = getattr(fun, "forgiven_metrics", set())
    out.extend(
        finding(fun.filename, fun.start_line, metric, fun.end_line)
        for metric, limit in option.thresholds.items()
        if getattr(fun, metric) > limit and metric not in forgiven
    )
emit(out)
