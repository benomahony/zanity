"""Run Lizard's own analysis and warning filter at its default limits, with its nesting depth,
nested structures and cognitive complexity extensions."""

import sys

import lizard
from _common import emit, files, finding

option = lizard.parse_args(["lizard", "-END", "-ENS", "-Ecognitive"])
METRICS = {
    "cyclomatic_complexity": lambda fun: fun.cyclomatic_complexity,
    "cognitive_complexity": lambda fun: fun.cognitive_complexity,
    "max_nesting_depth": lambda fun: fun.max_nesting_depth,
    "max_nested_structures": lambda fun: fun.max_nested_structures,
    "length": lambda fun: fun.length,
    "nloc": lambda fun: fun.nloc,
    "parameter_count": lambda fun: fun.parameter_count,
}
assert set(option.thresholds) == set(METRICS), f"Lizard checks {sorted(option.thresholds)}; map each in METRICS"
paths = [str(path) for path in files(sys.argv[1:], (".py",))]
out = []
for fun in lizard.get_warnings(lizard.analyze_files(paths, exts=option.extensions), option):
    forgiven = getattr(fun, "forgiven_metrics", set())
    out.extend(
        finding(fun.filename, fun.start_line, metric, fun.end_line)
        for metric, limit in option.thresholds.items()
        if METRICS[metric](fun) > limit and metric not in forgiven
    )
emit(out)
