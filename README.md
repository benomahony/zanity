# zanity

Fast, deterministic sanity checks for code written by people and agents.

zanity parses each file once with [tree-sitter](https://tree-sitter.github.io), walks the tree once, and runs every rule on that single walk. It replaces a family of Python linters (nasa-lsp, mockbuster, testdesiderata, bonsai, dddlint, and the errlint and sagalint specs) that each parsed every file separately. It is one static binary, it allocates all of its memory at startup, and it passes its own checks.

```console
$ zanity check src
src/billing.py  2 errors, 1 warning
  12:5  error    'charge' has 0 assertions that can catch a bug; it needs at least 2.  assertion-density
                 fix: Assert what 'charge' needs from 'amount' and what it guarantees before it returns.
  ...
zanity: 2 errors and 1 warning in 1 of 14 files
```

## Build

zanity needs Zig `0.17.0-dev.947` or later. Everything else, including every grammar, is vendored.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zanity check .
```

## Usage

```sh
zanity check                                  # check the current directory
zanity check src tests                        # check some paths
zanity check . --rules recursion,long-function   # run only these rules
zanity check . --json                         # a JSON array, one object per finding
zanity check . --plain                        # stable key=value lines for scripts
zanity check . --fix                          # apply the fixes zanity can make, then report the rest
zanity check . --infer                        # also ask TypeSafe what no deterministic check can decide
zanity help check                             # every option
```

`check` walks directories recursively, respects `.gitignore` and `.git/info/exclude`, and skips dot directories and build output. It exits 0 when nothing fired, 1 when an error-level rule fired, and 2 on a usage error. Findings go to stdout and the one-line summary to stderr, so output can be piped cleanly. On a terminal the report is grouped by file, each finding shows how to fix it, and two tables close the run: files with the most errors, and rules that fired most. `--no-color` or `NO_COLOR` turns colour off.

`--infer` needs `TYPESAFE_API_KEY`. It only asks about functions that report errors, and only the questions no deterministic check answered. Every answer is kept in a SQLite store in WAL mode, shared with nouls at `~/.cache/nouls/nouls.db` (or `$XDG_CACHE_HOME/nouls/nouls.db`), with the same schema and digests, so neither tool asks about unchanged code twice and answers nouls already paid for are reused. `ZANITY_STORE` points it at a different file.

## Suppressing a finding

A comment on the line of the finding silences it, in any language:

```python
value = eval(text)  # nasa: ignore[forbidden-call]
```

`nasa: ignore` with no list silences every rule on that line. Rules can be named by their zanity name or by the code of the tool they came from (`NASA01-A`, `FST001`, `drift`, ...), so existing suppressions keep working.

## Languages

| Language | Extensions |
|---|---|
| Python | `.py` `.pyi` |
| Zig | `.zig` |
| Go | `.go` |
| TypeScript | `.ts` `.mts` `.cts` |
| Rust | `.rs` |
| Java | `.java` |

Every rule runs on every language where it means something. A rule that does not apply to a language, such as `dynamic-allocation` in a garbage-collected language, is declared not applicable in `languages/manifest.zon`; anything else a rule needs must be supplied by the language's queries, or the build fails.

## Rules

Rules marked *off* only run when named with `--rules`.

**NASA's Power of Ten**

| Rule | Severity | Flags |
|---|---|---|
| `recursion` | warning | a function that calls itself, directly or through a cycle of calls across files |
| `unbounded-loop` | warning | a loop with no bound, such as `while True` or `for {}` |
| `dynamic-allocation` | error | allocation after initialization, in Zig and Rust |
| `long-function` | warning | a function with 60 or more lines of code, not counting blank and comment lines |
| `assertion-density` | error | a function with fewer than two assertions that can catch a bug |
| `assertion-message` | warning | an assertion with no message |
| `assertion-side-effect` | error | an assertion that assigns or calls something that changes state |
| `forbidden-call` | warning | `eval`, `exec` and other calls that run code no one can review |
| `restated-type`, `constant-assertion`, `redundant-null-check`, `conversion-assertion`, `guaranteed-length` | *off* | assertions that cannot fail, which do not count towards density |

**Structure** (the first three from bonsai; the rest from the engineering error catalogue)

| Rule | Severity | Flags |
|---|---|---|
| `long-parameter-list` | warning | more than four parameters |
| `passthrough-wrapper` | warning | a function whose whole body forwards to another call |
| `swallowed-error` | warning | an error handler that does nothing |
| `empty-block` | warning | an empty block where code was expected |
| `deep-nesting` | warning | code nested too deep to follow |
| `complex-function` | warning | a function with too many paths through it |
| `long-file` | warning | a file too long to hold in mind |

**Tests** (from testdesiderata and mockbuster)

| Rule | Severity | Flags |
|---|---|---|
| `sleep-in-test` | warning | a test that waits on the clock |
| `polling-loop` | warning | a loop in a test that polls with a sleep |
| `nondeterministic-test` | warning | randomness or the current time in a test |
| `test-double` | warning | a mock or stub that replaces real behaviour |

**Names** (from dddlint)

| Rule | Severity | Flags |
|---|---|---|
| `name-drift` | warning | one concept spelled several ways, such as `order_total` and `total_order` |
| `duplicate-name` | warning | the same name defined more than once in one language |

**Error messages** (from errlint)

| Rule | Severity | Flags |
|---|---|---|
| `vague-error` | warning | a message too vague to find the problem |
| `cryptic-error` | warning | a message that is only a code or an internal name |
| `unconstructive-error` | warning | a message that does not say how to fix the problem |
| `misleading-error` | *off* | a message that describes a different failure; needs `--infer` |

**Hazards** (from the engineering error catalogue in `catalogue/`)

`constant-condition`, `float-equality`, `discarded-comparison`, `unreachable-code`, `generic-catch`, `generic-throw`, `debug-leftover`, `hardcoded-secret`, `return-in-finally`, `identity-comparison`, `precedence-trap`, `switch-fallthrough`, `missing-default`, `no-effect-statement`, `tls-verification-disabled`, `weak-hash`, `unsafe-deserialization`, `shell-command`, `sql-built-from-strings`, `secret-in-log`, `wall-clock-duration` and `unawaited-call`. Each rule links to the catalogue entries it detects, and a test keeps the two in step.

`parse-error` reports a file tree-sitter could not fully parse; the other rules still run on the recovered tree.

## How it works

```
file ──► tree-sitter parse ──► one query per language ──► capture index ──► single walk ──► findings
                                (tags, locals, textobjects,                   │
                                 zanity.scm)                                 └─► facts ──► cross-file checks
                                                                                         (call graph, names)
```

- **Languages are data.** Each language in `languages/<name>/` is a vendored grammar, the upstream `tags.scm`, nvim-treesitter's `locals.scm` and `textobjects.scm`, and a `zanity.scm` that adds the captures they lack. Library knowledge, such as which calls sleep, mock or allocate, lives in `languages/tables.zon`, one entry per ecosystem. `src/architecture_test.zig` fails the build if any Zig source names a language or a grammar node kind.
- **Rules are written against captures**, a fixed vocabulary such as `@function.name`, `@call.receiver`, `@loop.condition` and `@assertion.message`. The walk keeps a stack of open functions, calls, loops and assertions; roles attach to the construct that encloses them and each construct's checks run when it closes.
- **Cross-file checks run once after all files**, over facts the walk collects: definitions for the naming rules, and functions and calls for the call graph.
- **Memory is fixed.** Every buffer is allocated at startup from the limits in `src/memory.zig`; tree-sitter itself allocates from bump pools, one reset after each file. Exceeding a limit is a clear error naming the limit, not a crash.

## Adding a language

No Zig code changes. Add:

1. the grammar's `parser.c` (and `scanner.c`) under `languages/<name>/grammar/`, with its licence and revision;
2. its query files under `languages/<name>/queries/`, starting from upstream `tags.scm`, `locals.scm` and `textobjects.scm`, then a `zanity.scm` for the rest;
3. an entry in `languages/manifest.zon` and, for a new ecosystem, in `languages/tables.zon`;
4. golden cases under `tests/golden/`.

`zig build test` then lists every capture the language still needs for each rule. Supply it, or declare the rule not applicable to the language.

## Testing

```sh
zig build test              # unit, golden, architecture, catalogue and self-check tests
zig build test --fuzz=100K  # fuzz the checker with arbitrary bytes in every language
```

Golden cases in `tests/golden/` run through the real binary and compare where each finding lands, its rule, its severity and the exit code, not the wording. The `nasa` and `dddlint` suites are generated from those tools by `tests/parity/`, so they prove zanity finds the same problems. The self-check runs zanity over its own source and fails on any finding.

## Licence

Grammars and nvim-treesitter queries keep their own licences, alongside them in `languages/`. The CWE data in `catalogue/` is © The MITRE Corporation.
