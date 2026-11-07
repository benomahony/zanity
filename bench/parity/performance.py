"""The performance page's sections: each tool's CLI timings against zanity's, cold and warm, and
the language server's response times."""

from dataclasses import dataclass
from tools import BY_NAME, TOOLS
from cells import Row, chart, duel, megabytes, raw, seconds, table


@dataclass(frozen=True)
class CliTiming:
    """One validated command measurement; times are seconds and memory is bytes."""

    mean: float
    stddev: float
    minimum: float
    memory: float


MAX_REPORT_SECONDS = 3600


MAX_REPORT_MEMORY_BYTES = 1 << 40


ALL_RULES_COLD = "zanity, all rules, cold"


ALL_RULES_WARM = "zanity, all rules, warm"


def benchmark_number(data: dict, path: tuple[str, ...]) -> int | float:
    """Read one required numeric report field, checking nesting, type and units before use.
    Invalid generated JSON raises ValueError with its field path and regeneration instructions."""
    assert path, "name the benchmark field to validate before formatting it"
    field = path[-1]
    assert field in {"mean", "stddev", "min", "memory", "runs", "lines"}, f"unknown numeric benchmark field {field}; add its validation policy before rendering it"
    value = data
    label = ".".join(path)
    for segment in path:
        if not isinstance(value, dict) or segment not in value:
            raise ValueError(f"results.json is missing {label}; run parity.py again without --skip-bench")
        value = value[segment]
    accepted_types = (int,) if field in {"memory", "runs", "lines"} else (int, float)
    if type(value) not in accepted_types:
        raise ValueError(f"results.json {label} has type {type(value).__name__}; rerun parity.py to produce numeric measurements")
    invalid = not value >= 0
    invalid |= field in {"mean", "runs", "memory"} and not value > 0
    invalid |= field in {"mean", "stddev", "min"} and not value < MAX_REPORT_SECONDS
    invalid |= field == "memory" and not value < MAX_REPORT_MEMORY_BYTES
    if invalid:
        raise ValueError(f"results.json {label}={value} has an invalid count or duration; check benchmark units and rerun parity.py")
    return value


def cli_timings(data: dict, required: tuple[str, ...]) -> dict[str, CliTiming]:
    """Each CLI command's timings from results.json, by command name. A malformed record or a
    missing required command raises ValueError naming what to rerun."""
    assert required, "name the baseline commands required by the CLI comparison"
    assert len(required) == len(set(required)), f"duplicate baseline commands {required}; list each required command once"
    if not isinstance(data, dict):
        raise ValueError("results.json must contain an object; regenerate the benchmark report with parity.py")
    cli = data.get("cli")
    if not isinstance(cli, dict) or not cli:
        raise ValueError("results.json needs a nonempty cli object; run parity.py without --skip-bench")
    timings = {}
    for name in cli:
        if not isinstance(name, str) or not name:
            raise ValueError("each CLI timing needs a nonempty command name; regenerate results.json with parity.py")
        timings[name] = CliTiming(
            mean=benchmark_number(data, ("cli", name, "mean")),
            stddev=benchmark_number(data, ("cli", name, "stddev")),
            minimum=benchmark_number(data, ("cli", name, "min")),
            memory=benchmark_number(data, ("cli", name, "memory")),
        )
    missing = set(required) - timings.keys()
    missing |= {f"zanity, {tool.name} rules, cold" for tool in TOOLS if tool.name in timings} - timings.keys()
    if missing:
        raise ValueError(f"results.json lacks CLI comparisons {sorted(missing)}; rerun parity.py without --skip-bench")
    return timings


def cli_headline(pairs: list[tuple[str, CliTiming, CliTiming]], base: float) -> list[str]:
    """Summarise validated command pairs without assuming every optional tool was measured."""
    assert pairs, "the CLI headline needs a measured tool pair; validate the report first"
    assert base > 0, f"headline baseline is {base}; validate a positive cold-cache mean first"
    name, fastest, _ = min(pairs, key=lambda pair: pair[1].mean)
    first = f'<div><strong>{fastest.mean / base:.1f}×</strong> faster on every rule, from an empty cache, than the fastest tool, {name}, on its own {len(BY_NAME[name].rules)}: {seconds(base)} against {seconds(fastest.mean)}.</div>'
    quick = [(label, theirs.mean / ours.mean) for label, theirs, ours in pairs if label != "bonsai"]
    summary = ""
    if quick:
        ratios = [ratio for _, ratio in quick]
        summary = f'<strong>{min(ratios):.1f}–{max(ratios):.1f}×</strong> faster than {", ".join(label for label, _ in quick)}, each on its own rules'
    bonsai = next(((theirs, ours) for label, theirs, ours in pairs if label == "bonsai"), None)
    if bonsai:
        separator = "; " if summary else ""
        summary += f'{separator}bonsai, which rebuilds its index on every run, is {bonsai[0].mean / bonsai[1].mean:.0f}× slower'
    return raw(['<div class="headline">', first, f'<div>{summary}.</div>', "</div>"])


def cli_command_rows(timings: dict[str, CliTiming], base: float) -> list[list[str]]:
    """Format the already validated command measurements as the comparison table's cells."""
    assert timings, "the CLI table needs command measurements; validate the report first"
    assert base > 0, f"table baseline is {base}; validate a positive cold-cache mean first"
    return [[name, seconds(result.mean), seconds(result.stddev), seconds(result.minimum), megabytes(result.memory), f"{result.mean / base:.1f}×"] for name, result in timings.items()]


def cli_speed(data: dict) -> list[str]:
    """Validate a persisted report before deriving ratios, headlines, charts and table cells.
    Named timing records keep JSON structure and error handling out of the presentation phase."""
    cli = cli_timings(data, (ALL_RULES_COLD, ALL_RULES_WARM))
    corpus_lines = benchmark_number(data, ("corpus_stats", "lines"))
    runs = benchmark_number(data, ("runs",))
    pairs = [(tool.name, cli[tool.name], cli[f"zanity, {tool.name} rules, cold"]) for tool in TOOLS if tool.name in cli]
    if not pairs:
        raise ValueError("results.json has no measured comparison tool pairs; rerun parity.py without --skip-bench")
    tool_count = len(pairs)
    base = cli[ALL_RULES_COLD].mean
    warm = cli[ALL_RULES_WARM].mean
    assert base > 0, f"validated cold baseline is {base}; fix CLI report validation before dividing"
    assert len({name for name, _, _ in pairs}) == tool_count, "TOOLS contains duplicate measured names; give each comparison tool a unique name"
    means = [(name, theirs.mean, ours.mean) for name, theirs, ours in pairs]
    together = sum(theirs.memory for _, theirs, _ in pairs)
    if together >= MAX_REPORT_MEMORY_BYTES:
        raise ValueError(f"combined CLI memory is {together} bytes; check result units and rerun parity.py before rendering")
    memory = cli[ALL_RULES_COLD].memory
    rows = cli_command_rows(cli, base)
    all_tools = "all five at once" if tool_count == 5 else f"all {tool_count} measured tools at once"
    tool_coverage = "all five tools" if tool_count == 5 else f"all {tool_count} measured tools"
    chart_caption = "Each tool on its own rules beside zanity on all of them, shorter is better"
    if any(name == "bonsai" for name, _, _ in pairs):
        chart_caption += "; bonsai, off this scale, is above"
    return [
        *cli_headline(pairs, base),
        "## Head to head",
        "",
        f"Each tool on the whole corpus, {corpus_lines:,} lines, beside zanity running only the rules that answer that tool's, from an empty cache. Each pair has its own scale. The mean of {runs} runs after a warm-up, with [hyperfine](https://github.com/sharkdp/hyperfine).",
        "",
        *duel(means, seconds, ("faster", "slower"), "Time to check the corpus, shorter is better"),
        *chart([*((name, theirs, seconds(theirs), False) for name, theirs, _ in means if name != "bonsai"), ("zanity, every rule, cold", base, seconds(base), True), ("zanity, every rule, warm", warm, seconds(warm), True)], chart_caption),
        "## Memory",
        "",
        f"The most memory each run held, from the kernel's accounting of the process. One zanity run covers every rule, where the same coverage takes {tool_coverage}: run side by side, as in a pre-commit hook, they hold {megabytes(together)} at once.",
        "",
        *chart([*((name, t.memory, megabytes(t.memory), False) for name, t, _ in pairs), (all_tools, together, megabytes(together), False), ("zanity, cold", memory, megabytes(memory), True)], "Peak memory checking the corpus, smaller is better"),
        "## Every command",
        "",
        "The tools ran through the same adapters as above. Cold zanity starts each run with an empty cache; warm reuses the last run's.",
        "",
        *table(["Command", "Mean", "±", "Fastest", "Peak memory", "Against zanity, all rules, cold"], rows, right=5),
    ]


def lsp_speed(data: dict) -> list[str]:
    servers = data["lsp"]
    timed = [(name, r) for name, r in servers.items() if "error" not in r]

    def rows(key: str, show) -> list[Row]:
        assert callable(show), f"show formats a {key} for the chart, not {show!r}"
        measured = [(name, r) for name, r in timed if key in r]
        assert measured, f"no timed server has a {key!r}; run parity.py again"
        return [(name, r[key], show(r[key]), name.startswith("zanity")) for name, r in measured]

    table_rows = []
    for name, r in servers.items():
        if "error" in r:
            table_rows.append([name, r["error"], "", "", ""])
            continue
        table_rows.append([name, seconds(r["first"]), seconds(r["save"]), megabytes(r["memory"]) if "memory" in r else "–", str(r["diagnostics"])])
    assert any(name == "zanity" for name, _ in timed), f"zanity's language server wasn't timed; results.json has {sorted(servers)}"
    assert timed, f"no language server was timed; each failed: {servers}"
    assert timed[-1][0].startswith("zanity"), f"zanity is timed last, so its bars end each chart, not {timed[-1][0]}"
    others = sum(r["memory"] for name, r in timed if not name.startswith("zanity"))
    held = rows("memory", megabytes)
    return [
        "## As language servers, and watching",
        "",
        f"rich's `console.py`, {data['lsp_lines']:,} lines, alone in a workspace; the median of {data['runs']}. First: from starting the server to diagnostics for the opened file. Save: from a change and save to fresh diagnostics. Memory: what the process held with the file open; an editor runs every language server at once, so the others' memory adds up. `zanity check --watch` listens to the system's file events outside any editor and keeps its workspace and parsed-file cache alive between checks. nouls' server needs `TYPESAFE_API_KEY` and did not run.",
        "",
        *chart(rows("first", seconds), "Start to first diagnostics, shorter is better"),
        *chart(rows("save", seconds), "Save to fresh diagnostics, shorter is better"),
        *chart([*held[:-1], ("all of them at once", others, megabytes(others), False), held[-1]], "Memory with the file open, smaller is better"),
        *table(["Server", "First", "Save", "Memory", "Diagnostics"], table_rows, right=4),
    ]
