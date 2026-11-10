//! `zanity check`: which rules and paths a run checks, the files it collects and checks in
//! parallel, the --infer and --fix steps, and its report for a person or an agent.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zclig = @import("zclig");
const language = @import("language.zig");
const strings = @import("strings.zig");
const batch = @import("batch.zig");
const rules = @import("rules.zig");
const report = @import("report.zig");
const naming = @import("naming.zig");
const graph = @import("graph.zig");
const parameters = @import("parameters.zig");
const structure = @import("structure.zig");
const vocabulary = @import("vocabulary.zig");
const project = @import("project.zig");
const memory = @import("memory.zig");
const infer = @import("infer.zig");
const store = @import("store.zig");
const sqlite = @import("sqlite.zig");
const Live = @import("live.zig").Live;
const config = @import("config.zig");
const fix_file = @import("fix_file.zig");
const watch = @import("watch.zig");
pub const collect = @import("collect.zig").collect;
const CheckOptions = triage.CheckOptions;
const triage = @import("triage.zig");
const baseline = @import("baseline.zig");
const Row = baseline.Row;
const cmd_watch = @import("cmd_watch.zig");
const main_root = @import("main.zig");
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const workspaceOf = workspace.workspaceOf;
const console = workspace.console;
const watchCheck = cmd_watch.watchCheck;
const app = main_root.app;

/// The check's options with what zanity.toml turns on: `[infer] enabled` runs it as `--infer`.
fn withSettings(requested: CheckOptions, settings: *const config.Config) CheckOptions {
    var options = requested;
    options.infer = requested.infer or settings.infer;
    if (settings.infer and !options.infer) assert.panic("{s} sets [infer] enabled, but the check runs without --infer; withSettings() must honour the setting", .{settings.dir});
    if (requested.infer and !options.infer) assert.panic("the check was asked for --infer but runs without it; withSettings() must only add to what was asked", .{});
    return options;
}

pub fn runCheck(ctx: *zclig.Context, requested: CheckOptions) ![]const Row {
    if (requested.paths.len == 0) assert.panic("check ran with no paths; zclig supplies '.' when none are given", .{});
    const ws = workspaceOf(ctx);
    try baseline.validateOptions(ctx, ws, requested);
    const agent = try speaksToAgent(ctx, ws, requested.agent or requested.all);
    const settings = try loadSettings(ctx, ws, std.heap.page_allocator);
    const options = withSettings(requested, &settings);
    if (options.watch) return watchCheck(ctx, ws, options, agent);
    startNotice(ctx, ws, options, agent);
    errdefer ws.notice.cancel(ws.io);
    ws.settings = &settings;
    defer ws.settings = null;
    rules.custom = settings.questionRules();
    defer rules.custom = &.{};
    var selected = if (options.rules) |list| try parseRules(ctx, ws, list) else settings.selection(options.production);
    if (options.rules != null and options.production) selected.includeTier(.production);
    if (options.infer) try connectInference(ctx, ws, &selected, options.rules == null);
    if (ws.inference) |*inference| {
        inference.concurrency = settings.concurrency orelse infer.default_concurrency;
        inference.threshold = settings.threshold orelse infer.default_threshold;
    }
    var live = Live.initLive(console(ctx, ctx.runtime.err), ws.io, !ctx.quiet);
    ws.live = &live;
    defer ws.live = null;
    const counts = checkPaths(ctx, ws, options, selected) catch |e| switch (e) {
        error.LimitExceeded => return ctx.fail(.usage, try ws.text.format("This run has more {s} than zanity is built to hold.", .{memory.exceeded}), "Check fewer files at once, or report it if the input is ordinary."),
        else => return e,
    };
    if (triage.failsReview(options, counts, ws.review)) ctx.status = .failure;
    if (!triage.special(options) and ws.rows.len != counts.errors + counts.warnings) assert.panic("{d} output rows for {d} errors and {d} warnings; runCheck() must add one row per error or warning", .{ ws.rows.len, counts.errors, counts.warnings });
    if (triage.special(options)) {
        try triage.renderOutput(ctx, ws, options, agent);
        ctx.format = .plain;
        return &.{};
    }
    if (agent) return reportToAgent(ctx, ws, options, counts);
    if (ctx.format != .human) try report.summarise(console(ctx, ctx.runtime.err), counts);
    return ws.rows.items();
}

/// Reads zanity.toml, opens the cache, and applies the file's excludes to the walk.
pub fn loadSettings(ctx: *zclig.Context, ws: *Workspace, gpa: Allocator) !config.Config {
    const settings = config.initConfig(gpa, ws.io) catch |e| switch (e) {
        error.InvalidConfig => return ctx.fail(.usage, config.problem[0..config.problem_len], "Fix that line of zanity.toml, or remove the setting to use zanity's default."),
        else => return e,
    };
    if (ws.environ) |environ| {
        if (ws.source_cache == null) ws.source_cache = store.Store.initStore(std.heap.page_allocator, ws.io, environ, ws.limits.store_bytes) catch null;
    }
    const before = ws.ignore.mark();
    for (settings.excludes()) |glob| try ws.ignore.exclude(settings.dir, glob);
    const after = ws.ignore.mark();
    if (after.patterns < before.patterns + settings.excludes().len) assert.panic("{d} excludes in zanity.toml added {d} ignore patterns; exclude() adds one per pattern", .{ settings.excludes().len, after.patterns - before.patterns });
    if (settings.rules) |chosen| if (chosen.len == 0) assert.panic("zanity.toml selected no rules; the reader must reject an empty select", .{});
    return settings;
}

/// Whether to write for a coding agent: when --agent asks, or when one is running zanity and the
/// command line chose no other format.
fn speaksToAgent(ctx: *zclig.Context, ws: *const Workspace, asked: bool) !bool {
    if (asked and ws.chose_format) return ctx.fail(.usage, "--agent and --all cannot be combined with --json or --plain.", "Choose one: --agent or --all to read, --json or --plain for a program to parse; --json and --plain always list every finding.");
    const agent = asked or (!ws.chose_format and agentRunning(ws));
    if (agent and ws.chose_format) assert.panic("writing for an agent although the command line chose --json or --plain; speaksToAgent() must refuse that", .{});
    if (asked and !agent) assert.panic("--agent was given but agent output is off; speaksToAgent() must honour --agent", .{});
    return agent;
}

/// Writes the findings for the agent in place of zclig's rows, which it then has none of to print.
fn reportToAgent(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, counts: report.Counts) ![]const Row {
    const paths = options.paths;
    if (paths.len == 0) assert.panic("reporting to an agent with no checked paths to name; zclig supplies '.' when none are given", .{});
    if (ws.findings.len != counts.errors + counts.warnings) assert.panic("{d} findings for {d} errors and {d} warnings; count the findings being reported", .{ ws.findings.len, counts.errors, counts.warnings });
    const out = ctx.runtime.out;
    try report.renderAgent(out.writer, .{ .findings = ws.findings.items(), .counts = counts, .paths = paths, .limit = options.limit, .watching = watching(ws), .all = options.all });
    try triage.continuation(out.writer, ws.args, 0, 10000);
    if (ws.cache_hits > 0) {
        const err = ctx.runtime.err;
        try err.writer.print("zanity: reused cached deterministic analysis for {d} of {d} source files; query {s}'s source_analyses table for the cached facts and findings.\n", .{ ws.cache_hits, ws.checked, ws.source_cache.?.path });
    }
    ctx.format = .plain;
    return &.{};
}

/// Whether a coding agent is running zanity, by the variable it sets in its commands' environment.
/// Whether this check is a rerun of `zanity check --watch`, which saving a file starts again.
fn watching(ws: *const Workspace) bool {
    const environ = ws.environ orelse return false;
    const value = environ.get(watch.env_var) orelse return false;
    if (ws.args.len == 0) assert.panic("a rerun of zanity check --watch with no arguments; the watcher passes check and its options", .{});
    const text = &ws.text;
    if (text.used > text.buffer.len) assert.panic("{d} of {d} text bytes used; write to ws.text only through its copy() and format()", .{ text.used, text.buffer.len });
    return std.mem.eql(u8, value, "1");
}

fn agentRunning(ws: *const Workspace) bool {
    if (ws.chose_format) assert.panic("asked whether an agent runs zanity after the command line chose a format; speaksToAgent() checks chose_format first", .{});
    const environ = ws.environ orelse return false;
    const value = environ.get("CLAUDECODE") orelse return false;
    const running = value.len > 0 and !std.mem.eql(u8, value, "0");
    if (running and value.len == 0) assert.panic("took an empty CLAUDECODE for a running agent; only a set value other than 0 means one", .{});
    return running;
}

/// The file-oriented terminal layout; `--plain` and `--json` stay zclig's record formats.
pub fn renderHuman(ctx: *zclig.Context, rows: []const Row) !void {
    const ws = workspaceOf(ctx);
    const findings = ws.findings.items();
    if (rows.len != findings.len) assert.panic("rendering {d} rows for {d} findings; rows are built one per finding", .{ rows.len, findings.len });
    try report.render(.{ .console = console(ctx, ctx.runtime.out), .scratch = &ws.table, .text = &ws.text }, findings);
    try report.summarise(console(ctx, ctx.runtime.err), report.count(findings, ws.checked + ws.project_files.len, ws.skipped));
    if (ws.checked > ws.files.len) assert.panic("checked {d} files out of {d} collected; count a file as checked only once, in checkFiles()", .{ ws.checked, ws.files.len });
    const err = ctx.runtime.err;
    try ws.notice.finish(ws.io, err.writer, app.version);
}

/// Starts the newer-release notice when a person reads the check at a terminal; agents, --json,
/// --plain, --quiet and pipes get none.
fn startNotice(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, agent: bool) void {
    if (agent and ws.chose_format) assert.panic("writing for an agent although the command line chose --json or --plain; speaksToAgent() must refuse that", .{});
    if (ws.chose_format and ctx.format == .human) assert.panic("the command line chose --json or --plain, but zclig formats for a person; zclig sets the format before running the command", .{});
    const environ = ws.environ orelse assert.panic("zanity check ran without the environment; main() passes it to the workspace", .{});
    const err = ctx.runtime.err;
    const person = !agent and !ws.chose_format and !triage.special(options) and ctx.format == .human and !ctx.quiet and err.capabilities.interactive;
    if (person) ws.notice.start(ws.io, environ, app.version);
}

pub fn parseRules(ctx: *zclig.Context, ws: *Workspace, list: []const u8) !rules.Set {
    var set: rules.Set = .{};
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |raw| {
        const code = std.mem.trim(u8, raw, " ");
        if (code.len == 0) continue;
        if (std.mem.eql(u8, code, "strict")) return ctx.fail(.usage, "'strict' is gone.", "Pass --production, or --rules all, to run every rule.");
        if (!set.includeNamed(code)) {
            const start = ws.text.used;
            _ = try ws.text.copy("The rules are: all (every rule, as --production runs)");
            for (rules.all) |r| _ = try ws.text.format(" {s}", .{r.name});
            const hint = ws.text.buffer[start..ws.text.used];
            return ctx.fail(.usage, try ws.text.format("Unknown rule '{s}'.", .{code}), hint);
        }
    }
    if (set.len == 0) return ctx.fail(.usage, "--rules needs at least one rule.", "Pass a comma-separated list, such as --rules unbounded-loop,long-function, or --rules all.");
    if (set.len > std.mem.count(u8, list, ",") + 1 and std.mem.indexOf(u8, list, "all") == null) assert.panic("--rules '{s}' enabled {d} rules from {d} names; each name other than 'all' enables one rule, so check includeNamed()", .{ list, set.len, std.mem.count(u8, list, ",") + 1 });
    if (rules.find(set.names()[0]) == null) assert.panic("--rules '{s}' enabled '{s}', which is not a rule; parseRules() must add only rules that includeNamed() found", .{ list, set.names()[0] });
    return set;
}

fn checkTimings(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, selected: rules.Set) !void {
    if (ws.source.len == 0) assert.panic("timing reports require the workspace source buffer", .{});
    if (selected.len == 0) assert.panic("timing checks require a rule selection", .{});
    const path = options.junit orelse return;
    const bytes = std.Io.Dir.cwd().readFile(ws.io, path, ws.source) catch |e|
        return ctx.fail(.io, try ws.text.format("Could not read JUnit report {s}: {t}.", .{ path, e }), "Generate a JUnit XML report with your test runner, then pass its path with --junit.");
    if (selected.enabled("slow-test")) @import("test_timings.zig").check(bytes, .{ .path = path, .threshold_ms = options.@"slow-test-ms" }, &ws.text, &ws.findings) catch |e|
        return ctx.fail(.usage, try ws.text.format("Could not parse JUnit report {s}: {t}.", .{ path, e }), "Use a JUnit XML report with finite, nonnegative testcase time attributes in seconds; DTDs are unsupported.");
}

pub fn checkPaths(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, selected: rules.Set) !report.Counts {
    const paths = options.paths;
    if (paths.len == 0) assert.panic("check ran with no paths; zclig supplies '.' when none are given", .{});
    if (selected.len == 0) assert.panic("check ran with no rules selected; runCheck always selects at least one", .{});
    for (paths) |path| try collect(ctx, ws, path);
    std.mem.sort([]const u8, ws.files.items(), {}, strings.lessThan);
    try ws.initCheckers(std.heap.page_allocator, selected);
    try checkFiles(ctx, ws, selected);
    std.mem.sort([]const u8, ws.project_files.items(), {}, strings.lessThan);
    try project.checkProjectFiles(.{ .io = ws.io, .buffer = ws.source, .facts = &ws.facts, .enabled = selected, .findings = &ws.findings }, ws.project_files.items());
    try checkTimings(ctx, ws, options, selected);
    if (ws.inference) |*inference| if (ws.live) |live| {
        inference.reporter = .{ .state = live, .report = reportInference };
    };
    const units = ws.facts.units;
    if (ws.inference) |*inference| inference.judge(units.items(), &ws.findings, selected) catch |e| switch (e) {
        error.AskFailed => return ctx.fail(.io, infer.failure, infer.advice),
        error.StoreUnavailable => return ctx.fail(.io, try storeProblem(ws), "Check that the cache directory is writable and not full, then run again."),
        else => return e,
    };
    if (ws.inference) |*inference| try inference.summarise(ctx);
    try dropDisabled(ws);
    report.sortFindings(ws.findings.items());
    if (options.fix) try fixFiles(ctx, ws);
    const findings = ws.findings.items();
    ws.rows.clear();
    for (findings) |f| {
        const rule = rules.find(f.rule) orelse unreachable;
        try ws.rows.add(.{
            .path = f.path,
            .line = f.line + 1,
            .column = f.column + 1,
            .severity = @tagName(rule.severity),
            .rule = rule.name,
            .message = f.message,
            .fix = f.advice(),
            .edit_start = if (f.edit) |e| e.start else null,
            .edit_end = if (f.edit) |e| e.end else null,
            .edit_text = if (f.edit) |e| e.replacement else null,
        });
    }
    try baseline.prepare(ctx, ws, options);
    return report.count(findings, ws.checked + ws.project_files.len, ws.skipped);
}

fn checkFiles(ctx: *zclig.Context, ws: *Workspace, selected: rules.Set) !void {
    if (selected.len == 0) assert.panic("checking files with no rules selected; runCheck always selects at least one", .{});
    if (ws.findings.len != 0) assert.panic("{d} findings are left from an earlier run; checkFiles expects a fresh workspace", .{ws.findings.len});
    if (ws.files.len > 0) {
        var run: batch.Batch = .{
            .io = ws.io,
            .files = ws.files.items(),
            .order = ws.order,
            .checkers = &ws.checkers,
            .file_bytes = ws.limits.file_bytes,
            .text = &ws.text,
            .facts = &ws.facts,
            .findings = &ws.findings,
            .cache = if (ws.source_cache) |*source_cache| source_cache else null,
            .cache_buffer = ws.analysis,
            .live = ws.live,
        };
        if (try run.run(try ws.checkWorkers(std.heap.page_allocator, ws.files.len))) |failure| {
            const path = ws.files.items()[failure.index];
            if (failure.unreadable) return ctx.fail(.io, try ws.text.format("Could not read {s}: {t}.", .{ path, failure.err }), "Check the file exists and is readable.");
            memory.exceeded = failure.exceeded;
            return failure.err;
        }
        ws.checked = run.checked;
        ws.cache_hits = run.cached;
    }
    if (ws.live) |live| live.restart();
    const anchor = try anchorOf(ws);
    if (anchor) |a| {
        vocabulary.assignScopes(a, &ws.facts);
        if (a.config.directional_len > 0) ws.naming.directional = a.config.directional[0..a.config.directional_len];
    }
    try naming.crossCheck(&ws.naming, &ws.facts, selected, &ws.findings);
    if (anchor) |a| try vocabulary.checkVocabulary(.{ .anchor = a, .text = ws.facts.text, .enabled = selected, .findings = &ws.findings, .reading = .{ .io = ws.io, .buffer = ws.source }, .renames = &ws.renames }, &ws.facts, ws.files.items());
    if (selected.enabled("recursion")) try graph.recursion(&ws.graph, &ws.facts, &ws.findings);
    if (selected.enabled("dead-parameter")) parameters.dropPassed(&ws.facts, &ws.findings);
    const sources: structure.Sources = .{ .io = ws.io, .mine = ws.source, .theirs = ws.fixed };
    try structure.checkStructure(&ws.facts, selected, &ws.findings, .{ .sources = sources, .live = &ws.liveness });
    if (ws.facts.collect_units and selected.enabled("repeated-mechanics")) try structure.clusterUnits(&ws.facts, sources);
    if (ws.checked > ws.files.len) assert.panic("checked {d} files out of {d} collected; count a file as checked only once per file collected", .{ ws.checked, ws.files.len });
}

fn reportInference(state: *anyopaque, done: usize, total: usize) void {
    const live: *Live = @ptrCast(@alignCast(state));
    if (done > total) assert.panic("--infer reported {d} of {d} functions done; Inference.watch() must report no more answered functions than it queued", .{ done, total });
    if (total == 0) assert.panic("--infer reported progress over no functions; askAll() must start the watcher only when functions are queued", .{});
    live.update("Asking the model", done, total);
}

/// Says why the answer store could not be used, in SQLite's words when it gave some.
fn storeProblem(ws: *Workspace) ![]const u8 {
    if (sqlite.failure_len > sqlite.failure.len) assert.panic("the store kept {d} bytes of failure message in room for {d}; the store must cut its message to fit its buffer", .{ sqlite.failure_len, sqlite.failure.len });
    const reason = sqlite.failure[0..sqlite.failure_len];
    const text = try ws.text.format("--infer could not use its answer store{s}{s}.", .{ if (reason.len > 0) ": " else "", reason });
    if (text.len == 0) assert.panic("describing a store failure produced no text; storeProblem() must write the store's message, so check its format call", .{});
    return text;
}

/// Connects to the decision model for `--infer`, collecting the functions it will ask about and, unless
/// `--rules` chose otherwise, turning on the rules only inference can decide.
fn connectInference(ctx: *zclig.Context, ws: *Workspace, selected: *rules.Set, add_inferred: bool) !void {
    if (ws.inference != null) assert.panic("connecting to the decision model a second time; runCheck connects once per run", .{});
    const environ = ws.environ orelse assert.panic("--infer needs the process environment, but main did not store it in the workspace; main() must store the environment in the workspace before running a command", .{});
    const settings = ws.settings orelse assert.panic("connecting --infer before zanity.toml was read; runCheck() reads it first", .{});
    const server: infer.Server = .{ .environ = environ, .url = settings.url, .model = settings.model, .api_key_env = settings.api_key_env };
    ws.inference = infer.Inference.initInference(std.heap.page_allocator, ws.io, ws.limits, server) catch |e| switch (e) {
        error.MissingApiKey => return ctx.fail(.usage, try ws.text.format("--infer asks TypeSafe's API, which needs an API key in {s}.", .{server.keyVariable()}), try ws.text.format("Set {s}; or point [infer] url in zanity.toml at another System One server, such as a local Kev; or run without --infer.", .{server.keyVariable()})),
        error.StoreUnavailable => return ctx.fail(.io, try storeProblem(ws), "Check that the cache directory is writable, or set ZANITY_STORE to a file zanity can create."),
        else => return e,
    };
    ws.facts.collect_units = true;
    if (add_inferred) for (rules.all) |r| if (r.question.len > 0) selected.include(r.name);
    if (selected.len == 0) assert.panic("--infer left no rules selected; connectInference() must keep the requested rules selected", .{});
}

/// Applies each file's edits, then drops the findings they fixed and moves the rest to their new lines.
fn fixFiles(ctx: *zclig.Context, ws: *Workspace) !void {
    try fix_file.mergeRenames(ws);
    const findings = ws.findings.items();
    var edited: usize = 0;
    var files: usize = 0;
    var start: usize = 0;
    while (start < findings.len) {
        var end = start + 1;
        while (end < findings.len and std.mem.eql(u8, findings[end].path, findings[start].path)) end += 1;
        const applied = try fix_file.fixFile(ctx, ws, findings[start..end]);
        edited += applied;
        files += @intFromBool(applied > 0);
        start = end;
    }
    if (files > edited) assert.panic("expected every fixed file to have an applied edit, got {d} files and {d} edits; fixFile() must mark a finding fixed for each edit it applies", .{ files, edited });
    fix_file.settleRenames(findings);
    var kept: usize = 0;
    var fixed: usize = 0;
    var uses: usize = 0;
    for (findings) |f| {
        uses += @intFromBool(f.companion);
        fixed += @intFromBool(f.fixed and !f.companion);
        if (f.fixed or f.companion) continue;
        findings[kept] = f;
        kept += 1;
    }
    ws.findings.len = kept;
    if (kept + fixed + uses != findings.len) assert.panic("--fix lost track of findings: {d} fixed, {d} kept and {d} rename edits out of {d}; a finding was marked fixed without its edit being applied, so fixFile() must set fixed only after it writes the edit", .{ fixed, kept, uses, findings.len });
    if (fixed > 0) {
        const line = try ws.text.format("zanity: fixed {d} {s} in {d} {s}", .{ fixed, if (fixed == 1) "finding" else "findings", files, if (files == 1) "file" else "files" });
        const err = console(ctx, ctx.runtime.err);
        try err.styled(line, .{ .fg = .{ .named = .green } });
        try err.writer.writeByte('\n');
    }
}

/// Where the working directory sits under the zanity.toml in use; null when there is none.
fn anchorOf(ws: *Workspace) !?config.Anchor {
    const settings = ws.settings orelse return null;
    if (settings.dir.len == 0) return null;
    if (!std.fs.path.isAbsolute(settings.dir)) assert.panic("zanity.toml's folder '{s}' is relative; initConfig() records the real path", .{settings.dir});
    const cwd = try Io.Dir.cwd().realPathFileAlloc(ws.io, ".", std.heap.page_allocator);
    defer std.heap.page_allocator.free(cwd);
    if (!std.mem.startsWith(u8, cwd, settings.dir)) assert.panic("zanity.toml was found in {s}, which is not at or above the working directory {s}; initConfig() must search only the working directory and the folders above it", .{ settings.dir, cwd });
    return .{ .config = settings, .below = try ws.text.copy(std.mem.trimStart(u8, cwd[settings.dir.len..], "/")) };
}

/// Drops the findings of rules that a [paths] section of zanity.toml turns off for their file,
/// before they are reported or fixed.
fn dropDisabled(ws: *Workspace) !void {
    const settings = ws.settings orelse return;
    if (settings.pathRules().len == 0) return;
    const anchor = (try anchorOf(ws)) orelse return;
    if (anchor.config != settings) assert.panic("the anchor holds the config from {s}, not the one in use from {s}; anchorOf() must anchor ws.settings", .{ anchor.config.dir, settings.dir });
    const findings = ws.findings.items();
    var kept: usize = 0;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (findings) |f| {
        const relative = anchor.relative(f.path, &buffer);
        if (relative.len > 0 and settings.disabledAt(relative, f.rule)) continue;
        findings[kept] = f;
        kept += 1;
    }
    if (kept > findings.len) assert.panic("kept {d} of {d} findings; dropping findings in place can only shrink the list, so the loop wrote past what it read", .{ kept, findings.len });
    ws.findings.len = kept;
}
