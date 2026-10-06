const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zcli = @import("zcli");
const zrich = @import("zrich");
const adapters = @import("adapters");
const language = @import("language.zig");
const check = @import("check.zig");
const strings = @import("strings.zig");
const batch = @import("batch.zig");
const rules = @import("rules.zig");
const report = @import("report.zig");
const naming = @import("naming.zig");
const graph = @import("graph.zig");
const structure = @import("structure.zig");
const vocabulary = @import("vocabulary.zig");
const project = @import("project.zig");
const memory = @import("memory.zig");
const Ignore = @import("ignore.zig").Ignore;
const infer = @import("infer.zig");
const store = @import("store.zig");
const Live = @import("live.zig").Live;
const config = @import("config.zig");
const starter = @import("init.zig");
const Facts = @import("facts.zig").Facts;
const Finding = @import("facts.zig").Finding;

const skipped_dirs = [_][]const u8{ "node_modules", "zig-out", "__pycache__", "target", "dist", "build", "venv" };

const CheckOptions = struct {
    paths: []const []const u8,
    rules: ?[]const u8 = null,
    fix: bool = false,
    infer: bool = false,
    strict: bool = false,
};

const InitOptions = struct {
    paths: []const []const u8,
    force: bool = false,
};

/// What `zanity init` wrote, as `--json` and `--plain` publish it.
const InitRow = struct {
    path: []const u8,
    rules: usize,
    excluded: usize,
};

/// One finding as `--json` and `--plain` publish it. Lines and columns count from 1.
const Row = struct {
    path: []const u8,
    line: u32,
    column: u32,
    severity: []const u8,
    rule: []const u8,
    message: []const u8,
    fix: []const u8,
};

const app: zcli.App = .{
    .name = "zanity",
    .version = @import("build_info").version,
    .description = "Fast, deterministic sanity checks for code written by people and agents.",
    .commands = &.{ zcli.command(CheckOptions, Row, .{
        .name = "check",
        .description = "Check files and directories. Exits 1 when an error-level rule fires, or with --strict when any rule does.",
        .examples = &.{ "zanity check .", "zanity check src tests --rules unbounded-loop,long-function", "zanity check . --json", "zanity check . --fix", "zanity check . --strict" },
        .result_title = "Findings",
        .positional = .{ .name = "paths", .metavar = "PATH", .help = "Files or directories to check.", .default = &.{"."} },
        .options = &.{
            .{ .name = "rules", .metavar = "RULES", .help = "Comma-separated rules to run instead of the defaults.", .example = "unbounded-loop,long-function" },
            .{ .name = "fix", .help = "Apply the fixes zanity can make, then report what is left." },
            .{ .name = "strict", .help = "Exit 1 on any finding, warnings included, as a pre-commit hook or CI should." },
            .{ .name = "infer", .help = "Also ask TypeSafe what no deterministic check can decide, such as whether an error message misleads. Needs TYPESAFE_API_KEY." },
        },
    }, .{ .run = runCheck, .human = renderHuman }), zcli.command(InitOptions, InitRow, .{
        .name = "init",
        .description = "Write a zanity.toml with every setting and rule explained, ready to trim.",
        .examples = &.{ "zanity init", "zanity init path/to/project", "zanity init --force" },
        .result_title = "Written",
        .positional = .{ .name = "paths", .metavar = "DIR", .help = "The project's root, where zanity.toml goes.", .default = &.{"."} },
        .options = &.{
            .{ .name = "force", .help = "Replace an existing zanity.toml." },
        },
    }, .{ .run = runInit, .human = renderInit }) },
};

/// Everything a run needs, allocated once at startup and reused for every file.
const Workspace = struct {
    live: ?*Live = null,
    /// What `zanity init` wrote; one run writes one file.
    init_row: [1]InitRow = undefined,
    /// The zanity.toml in effect, for its [paths] sections.
    settings: ?*const config.Config = null,
    limits: memory.Limits,
    text: memory.Text,
    facts: Facts,
    naming: naming.ConceptScratch,
    graph: graph.CycleScratch,
    findings: memory.Bounded(Finding),
    files: memory.Bounded([]const u8),
    /// Build, lint, type-check and CI configuration, checked as text.
    project_files: memory.Bounded([]const u8),
    /// The order checkFiles() hands files to its workers in.
    order: []batch.Sized,
    rows: memory.Bounded(Row),
    table: report.TableScratch,
    source: []u8,
    fixed: []u8,
    ignore: Ignore,
    environ: ?*const std.process.Environ.Map = null,
    inference: ?infer.Inference = null,
    checkers: [language.count]?check.Checker = @splat(null),
    checked: usize = 0,
    io: Io = undefined,

    fn initWorkspace(gpa: Allocator, limits: memory.Limits) Allocator.Error!*Workspace {
        if (limits.files == 0) assert.panic("memory.Limits.files is 0, so zanity could not check any file", .{});
        if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so zanity could not read any file", .{});
        const ws = try gpa.create(Workspace);
        ws.* = .{
            .limits = limits,
            .text = try .initText(gpa, limits.text_bytes),
            .facts = undefined,
            .naming = try .initNamingScratch(gpa, limits),
            .graph = try .initGraphScratch(gpa, limits),
            .findings = try .initBounded(gpa, limits.findings, "findings across all files"),
            .files = try .initBounded(gpa, limits.files, "files"),
            .project_files = try .initBounded(gpa, 1024, "project files"),
            .order = try memory.reserve(gpa, batch.Sized, limits.files),
            .rows = try .initBounded(gpa, limits.findings, "findings across all files"),
            .table = try .initTableScratch(gpa, limits.files),
            .source = try memory.reserve(gpa, u8, limits.file_bytes + 1),
            .fixed = try memory.reserve(gpa, u8, 2 * limits.file_bytes),
            .ignore = try .initIgnore(gpa, limits),
        };
        ws.facts = try .initFacts(gpa, limits, &ws.text);
        return ws;
    }

    /// Compiles the queries of each language the run will check, and only those.
    fn initCheckers(ws: *Workspace, gpa: Allocator, selected: rules.Set) !void {
        if (selected.len == 0) assert.panic("compiling checkers with no rules selected; runCheck always selects at least one", .{});
        for (ws.files.items()) |path| {
            const adapter = language.forPath(path) orelse continue;
            const slot = &ws.checkers[language.indexOf(adapter)];
            if (slot.* == null) slot.* = try check.Checker.initChecker(gpa, try language.load(adapter), selected);
        }
        if (ws.checkers.len != adapters.all.len) assert.panic("{d} checker slots for {d} languages; initCheckers() must make one slot per adapter in adapters.all", .{ ws.checkers.len, adapters.all.len });
    }
};

pub fn main(init: std.process.Init) !u8 {
    const minimal = init.minimal;
    const args = try minimal.args.toSlice(init.arena.allocator());
    if (args.len == 0) assert.panic("the process has no arguments, not even its own name; start zanity from a shell or exec, which always pass the program's name", .{});
    var out_buffer: [64 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buffer);
    var err_buffer: [4096]u8 = undefined;
    var err_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buffer);
    const ws = try Workspace.initWorkspace(std.heap.page_allocator, .{});
    ws.io = init.io;
    ws.environ = init.environ_map;
    var runtime = zcli.native.runtime(init, &out_writer.interface, &err_writer.interface);
    runtime.user_data = ws;
    const code = app.run(init.gpa, args[1..], runtime);
    if (@backingInt(code) > 130) assert.panic("zcli returned exit code {d}; codes above 130 collide with signals", .{@backingInt(code)});
    return @backingInt(code);
}

fn workspaceOf(ctx: *zcli.Context) *Workspace {
    const ws: *Workspace = @ptrCast(@alignCast(ctx.runtime.user_data orelse unreachable));
    if (ws.limits.files == 0) assert.panic("the workspace allows 0 files; it was not built by initWorkspace", .{});
    if (ws.files.capacity() != ws.limits.files) assert.panic("the workspace has room for {d} files but its limit is {d}; it was not built by initWorkspace", .{ ws.files.capacity(), ws.limits.files });
    return ws;
}

fn runCheck(ctx: *zcli.Context, options: CheckOptions) ![]const Row {
    if (options.paths.len == 0) assert.panic("check ran with no paths; zcli supplies '.' when none are given", .{});
    const ws = workspaceOf(ctx);
    const settings = config.initConfig(std.heap.page_allocator, ws.io) catch |e| switch (e) {
        error.InvalidConfig => return ctx.fail(.usage, config.problem[0..config.problem_len], "Fix that line of zanity.toml, or remove the setting to use zanity's default."),
        else => return e,
    };
    for (settings.excludes()) |glob| try ws.ignore.exclude(settings.dir, glob);
    ws.settings = &settings;
    defer ws.settings = null;
    var selected = if (options.rules) |list| try parseRules(ctx, ws, list) else settings.selection();
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
    if (counts.errors > 0 or (options.strict and counts.warnings > 0)) ctx.status = .failure;
    if (ctx.format != .human) try report.summarise(console(ctx, ctx.runtime.err), counts);
    if (ws.rows.len != counts.errors + counts.warnings) assert.panic("{d} output rows for {d} errors and {d} warnings; runCheck() must add one row per error or warning", .{ ws.rows.len, counts.errors, counts.warnings });
    return ws.rows.items();
}

/// The file-oriented terminal layout; `--plain` and `--json` stay zcli's record formats.
fn renderHuman(ctx: *zcli.Context, rows: []const Row) !void {
    const ws = workspaceOf(ctx);
    const findings = ws.findings.items();
    if (rows.len != findings.len) assert.panic("rendering {d} rows for {d} findings; rows are built one per finding", .{ rows.len, findings.len });
    try report.render(.{ .console = console(ctx, ctx.runtime.out), .scratch = &ws.table, .text = &ws.text }, findings);
    try report.summarise(console(ctx, ctx.runtime.err), report.count(findings, ws.checked + ws.project_files.len));
    if (ws.checked > ws.files.len) assert.panic("checked {d} files out of {d} collected; count a file as checked only once, in checkFiles()", .{ ws.checked, ws.files.len });
}

fn runInit(ctx: *zcli.Context, options: InitOptions) ![]const InitRow {
    const ws = workspaceOf(ctx);
    if (options.paths.len != 1) return ctx.fail(.usage, "zanity init takes one directory.", "Run it in the project's root, or pass that directory, such as zanity init path/to/project.");
    const dir = options.paths[0];
    const target = if (std.mem.eql(u8, dir, ".")) config.file_name else try ws.text.format("{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), config.file_name });
    const cwd = Io.Dir.cwd();
    try collect(ctx, ws, dir);
    var counts: [language.count]starter.Project.Count = undefined;
    for (adapters.all, &counts) |*adapter, *count| count.* = .{ .name = adapter.name, .files = 0 };
    for (ws.files.items()) |path| if (language.forPath(path)) |adapter| {
        counts[language.indexOf(adapter)].files += 1;
    };
    var present: [starter.usual_excludes.len][]const u8 = undefined;
    var found: usize = 0;
    for (starter.usual_excludes) |candidate| {
        const path = if (std.mem.eql(u8, dir, ".")) candidate else try ws.text.format("{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), candidate });
        cwd.access(ws.io, path, .{}) catch continue;
        present[found] = candidate;
        found += 1;
    }
    var buffer: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try starter.renderConfig(&w, .{ .languages = &counts, .present = present[0..found] });
    cwd.writeFile(ws.io, .{ .sub_path = target, .data = w.buffered(), .flags = .{ .exclusive = !options.force } }) catch |e| switch (e) {
        error.PathAlreadyExists => return ctx.fail(.usage, try ws.text.format("{s} already exists.", .{target}), "Edit it, or pass --force to replace it with a fresh one."),
        else => return ctx.fail(.io, try ws.text.format("Could not write {s}: {t}.", .{ target, e }), "Check that the directory exists and is writable."),
    };
    if (w.buffered().len == 0) assert.panic("zanity init wrote an empty {s}; renderConfig() in src/init.zig must write the whole file", .{target});
    if (found > starter.usual_excludes.len) assert.panic("found {d} of the {d} usual excludes; the loop in runInit() must add each at most once", .{ found, starter.usual_excludes.len });
    ws.init_row[0] = .{ .path = target, .rules = rules.all.len, .excluded = found };
    return &ws.init_row;
}

fn renderInit(ctx: *zcli.Context, rows: []const InitRow) !void {
    if (rows.len != 1) assert.panic("zanity init reported {d} files written; runInit() writes exactly one", .{rows.len});
    const row = rows[0];
    const out = console(ctx, ctx.runtime.out);
    try out.writer.print("Wrote {s}: every setting explained, and all {d} rules listed with how to fix what they find.\n", .{ row.path, row.rules });
    if (row.excluded > 0) try out.writer.print("It excludes the {d} fixture or vendored {s} it found; check that list.\n", .{ row.excluded, if (row.excluded == 1) "directory" else "directories" });
    try out.writer.writeAll("Next: run `zanity check .`, then delete or change what you don't need.\n");
    if (row.path.len == 0) assert.panic("zanity init reported writing a file with no path; runInit() must pass the path it wrote", .{});
}

fn console(ctx: *zcli.Context, stream: zcli.Stream) zrich.Console {
    if (stream.capabilities.width == 0) assert.panic("the output stream reports width 0; zcli must supply a terminal width", .{});
    if (stream.capabilities.width > 4096) assert.panic("the output stream reports width {d}; wider than 4096 columns is not a terminal", .{stream.capabilities.width});
    return .{ .writer = stream.writer, .allocator = ctx.allocator, .options = stream.capabilities };
}

fn parseRules(ctx: *zcli.Context, ws: *Workspace, list: []const u8) !rules.Set {
    var set: rules.Set = .{};
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |raw| {
        const code = std.mem.trim(u8, raw, " ");
        if (code.len == 0) continue;
        if (!set.includeNamed(code)) {
            const start = ws.text.used;
            _ = try ws.text.copy("The rules are: all (every rule, including those off by default)");
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

fn checkPaths(ctx: *zcli.Context, ws: *Workspace, options: CheckOptions, selected: rules.Set) !report.Counts {
    const paths = options.paths;
    if (paths.len == 0) assert.panic("check ran with no paths; zcli supplies '.' when none are given", .{});
    if (selected.len == 0) assert.panic("check ran with no rules selected; runCheck always selects at least one", .{});
    for (paths) |path| try collect(ctx, ws, path);
    std.mem.sort([]const u8, ws.files.items(), {}, strings.lessThan);
    try ws.initCheckers(std.heap.page_allocator, selected);
    try checkFiles(ctx, ws, selected);
    std.mem.sort([]const u8, ws.project_files.items(), {}, strings.lessThan);
    try project.checkProjectFiles(.{ .io = ws.io, .buffer = ws.source, .facts = &ws.facts, .enabled = selected, .findings = &ws.findings }, ws.project_files.items());
    if (ws.inference) |*inference| if (ws.live) |live| {
        inference.reporter = .{ .state = live, .report = reportInference };
    };
    const units = ws.facts.units;
    if (ws.inference) |*inference| inference.judge(units.items(), &ws.findings, selected) catch |e| switch (e) {
        error.AskFailed => return ctx.fail(.io, infer.failure, "Check TYPESAFE_API_KEY and TYPESAFE_BASE_URL, then run again; answers already received are cached."),
        error.StoreUnavailable => return ctx.fail(.io, try storeProblem(ws), "Check that the cache directory is writable and not full, then run again."),
        else => return e,
    };
    if (ws.inference) |inference| try describeInference(ctx, ws, inference.stats);
    try dropDisabled(ws);
    report.sortFindings(ws.findings.items());
    if (options.fix) try fixFiles(ctx, ws);
    const findings = ws.findings.items();
    ws.rows.clear();
    for (findings) |f| {
        const rule = rules.find(f.rule) orelse unreachable;
        try ws.rows.add(.{ .path = f.path, .line = f.line + 1, .column = f.column + 1, .severity = @tagName(rule.severity), .rule = rule.name, .message = f.message, .fix = f.advice() });
    }
    return report.count(findings, ws.checked + ws.project_files.len);
}

fn checkFiles(ctx: *zcli.Context, ws: *Workspace, selected: rules.Set) !void {
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
            .live = ws.live,
        };
        if (try run.run(try batch.initWorkers(std.heap.page_allocator, ws.limits, ws.files.len))) |failure| {
            const path = ws.files.items()[failure.index];
            if (failure.unreadable) return ctx.fail(.io, try ws.text.format("Could not read {s}: {t}.", .{ path, failure.err }), "Check the file exists and is readable.");
            memory.exceeded = failure.exceeded;
            return failure.err;
        }
        ws.checked = run.checked;
    }
    if (ws.live) |live| live.restart();
    const anchor = try anchorOf(ws);
    if (anchor) |a| {
        vocabulary.assignScopes(a, &ws.facts);
        if (a.config.directional_len > 0) ws.naming.directional = a.config.directional[0..a.config.directional_len];
    }
    try naming.crossCheck(&ws.naming, &ws.facts, selected, &ws.findings);
    if (anchor) |a| try vocabulary.checkVocabulary(a, &ws.facts, selected, &ws.findings);
    if (selected.enabled("recursion")) try graph.recursion(&ws.graph, &ws.facts, &ws.findings);
    try structure.checkStructure(&ws.facts, selected, &ws.findings);
    if (ws.checked > ws.files.len) assert.panic("checked {d} files out of {d} collected; count a file as checked only once per file collected", .{ ws.checked, ws.files.len });
}

fn reportInference(state: *anyopaque, done: usize, total: usize) void {
    const live: *Live = @ptrCast(@alignCast(state));
    if (done > total) assert.panic("--infer reported {d} of {d} functions done; Inference.watch() must report no more answered functions than it queued", .{ done, total });
    if (total == 0) assert.panic("--infer reported progress over no functions; askAll() must start the watcher only when functions are queued", .{});
    live.update("Asking TypeSafe", done, total);
}

/// Says how much of --infer came from the store and how long TypeSafe took, so a slow run explains itself.
fn describeInference(ctx: *zcli.Context, ws: *Workspace, stats: infer.Stats) !void {
    if (stats.asked > stats.functions) assert.panic("--infer asked about {d} of {d} functions; askAll() must count only queued functions as asked", .{ stats.asked, stats.functions });
    if (stats.seconds < 0) assert.panic("--infer took {d} seconds; measure the time with the .awake clock, which never runs backwards", .{stats.seconds});
    if (ctx.quiet or stats.functions == 0) return;
    const line = try ws.text.format("zanity: --infer had questions about {d} {s}: {d} answered from the store, {d} asked of TypeSafe in {d}m{d:0>2}s.", .{
        stats.functions,
        if (stats.functions == 1) "function" else "functions",
        stats.functions - stats.asked,
        stats.asked,
        @divTrunc(stats.seconds, 60),
        @as(u64, @intCast(@mod(stats.seconds, 60))),
    });
    try ctx.diagnostic(line);
}

/// Says why the answer store could not be used, in SQLite's words when it gave some.
fn storeProblem(ws: *Workspace) ![]const u8 {
    if (store.failure_len > store.failure.len) assert.panic("the store kept {d} bytes of failure message in room for {d}; the store must cut its message to fit its buffer", .{ store.failure_len, store.failure.len });
    const reason = store.failure[0..store.failure_len];
    const text = try ws.text.format("--infer could not use its answer store{s}{s}.", .{ if (reason.len > 0) ": " else "", reason });
    if (text.len == 0) assert.panic("describing a store failure produced no text; storeProblem() must write the store's message, so check its format call", .{});
    return text;
}

/// Connects to TypeSafe for `--infer`, collecting the functions it will ask about and, unless
/// `--rules` chose otherwise, turning on the rules only inference can decide.
fn connectInference(ctx: *zcli.Context, ws: *Workspace, selected: *rules.Set, add_inferred: bool) !void {
    if (ws.inference != null) assert.panic("connecting to TypeSafe a second time; runCheck connects once per run", .{});
    const environ = ws.environ orelse assert.panic("--infer needs the process environment, but main did not store it in the workspace; main() must store the environment in the workspace before running a command", .{});
    ws.inference = infer.Inference.initInference(std.heap.page_allocator, ws.io, environ, ws.limits) catch |e| switch (e) {
        error.MissingApiKey => return ctx.fail(.usage, "--infer asks TypeSafe to judge error messages, and needs an API key in TYPESAFE_API_KEY.", "Set TYPESAFE_API_KEY, or run without --infer to use only the deterministic checks."),
        error.StoreUnavailable => return ctx.fail(.io, try storeProblem(ws), "Check that the cache directory is writable, or set ZANITY_STORE to a file zanity can create."),
        else => return e,
    };
    ws.facts.collect_units = true;
    if (add_inferred) for (rules.all) |r| if (r.question.len > 0) selected.include(r.name);
    if (selected.len == 0) assert.panic("--infer left no rules selected; connectInference() must keep the requested rules selected", .{});
}

/// Applies each file's edits, then drops the findings they fixed and moves the rest to their new lines.
fn fixFiles(ctx: *zcli.Context, ws: *Workspace) !void {
    const findings = ws.findings.items();
    var fixed: usize = 0;
    var files: usize = 0;
    var start: usize = 0;
    while (start < findings.len) {
        var end = start + 1;
        while (end < findings.len and std.mem.eql(u8, findings[end].path, findings[start].path)) end += 1;
        const applied = try fixFile(ctx, ws, findings[start..end]);
        fixed += applied;
        files += @intFromBool(applied > 0);
        start = end;
    }
    if (files > fixed) assert.panic("expected every fixed file to have a fixed finding, got {d} files and {d} findings; fixFile() must mark a finding fixed for each edit it applies", .{ files, fixed });
    var kept: usize = 0;
    for (findings) |f| {
        if (f.fixed) continue;
        findings[kept] = f;
        kept += 1;
    }
    ws.findings.len = kept;
    if (kept + fixed != findings.len) assert.panic("--fix lost track of findings: {d} fixed and {d} kept out of {d}; a finding was marked fixed without its edit being applied, so fixFile() must set fixed only after it writes the edit", .{ fixed, kept, findings.len });
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

/// Applies the non-overlapping edits of one file's findings, which are in source order.
/// An edit that overlaps an earlier one waits for the next run.
fn fixFile(ctx: *zcli.Context, ws: *Workspace, findings: []Finding) !usize {
    const path = findings[0].path;
    if (!std.mem.eql(u8, path, findings[findings.len - 1].path)) assert.panic("expected the findings of one file, got {s} and {s}; fixFiles() must pass one file's findings at a time", .{ path, findings[findings.len - 1].path });
    var any = false;
    for (findings) |f| any = any or f.edit != null;
    if (!any) return 0;
    const source = Io.Dir.cwd().readFile(ws.io, path, ws.source) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not read {s} to fix it: {t}.", .{ path, e }), "Check the file is still there and readable.");
    };
    const spliced = try applyEdits(source, findings, ws.fixed);
    try replaceFile(ctx, ws, .{ .path = path, .read = source, .fixed = spliced.bytes });
    shiftLines(source, findings);
    const applied = spliced.applied;
    if (applied == 0) assert.panic("expected at least one edit to apply to {s}, got none; fixFiles() must call fixFile() only for a file with an edit", .{path});
    return applied;
}

/// Writes `source` into `out` with each edit that doesn't overlap an earlier one applied, marking
/// those findings fixed.
fn applyEdits(source: []const u8, findings: []Finding, out: []u8) error{LimitExceeded}!struct { bytes: []const u8, applied: usize } {
    var used: usize = 0;
    var cursor: usize = 0;
    var applied: usize = 0;
    for (findings) |*f| {
        const edit = f.edit orelse continue;
        if (edit.start < cursor or edit.end > source.len) continue;
        const kept = source[cursor..edit.start];
        if (used + kept.len + edit.replacement.len > out.len) break;
        @memcpy(out[used..][0..kept.len], kept);
        @memcpy(out[used + kept.len ..][0..edit.replacement.len], edit.replacement);
        used += kept.len + edit.replacement.len;
        cursor = edit.end;
        f.fixed = true;
        applied += 1;
    }
    const rest = source[cursor..];
    if (used + rest.len > out.len) {
        memory.exceeded = "bytes in one fixed file";
        return error.LimitExceeded;
    }
    @memcpy(out[used..][0..rest.len], rest);
    used += rest.len;
    if (cursor > source.len) assert.panic("applied edits up to byte {d} of a {d}-byte file; skip an edit that ends past the file", .{ cursor, source.len });
    if (applied > findings.len) assert.panic("applied {d} edits from {d} findings; each finding has at most one edit", .{ applied, findings.len });
    return .{ .bytes = out[0..used], .applied = applied };
}

/// A file to fix: its path, the bytes the fixes were made against, and the fixed bytes.
const Replacement = struct { path: []const u8, read: []const u8, fixed: []const u8 };

/// Writes the fixed file in place of the original, unless someone changed the original since it
/// was read: their change would be lost, so it is left for the next run instead.
fn replaceFile(ctx: *zcli.Context, ws: *Workspace, r: Replacement) !void {
    const path = r.path;
    const bytes = r.fixed;
    if (!(path.len > 0 and bytes.len <= ws.fixed.len)) assert.panic("expected a path and at most {d} bytes, got '{s}' and {d} bytes; fixFile() must write at most the fixed buffer's size", .{ ws.fixed.len, path, bytes.len });
    const cwd = Io.Dir.cwd();
    const permissions = (cwd.statFile(ws.io, path, .{}) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not stat {s} to fix it: {t}.", .{ path, e }), "Check the file is still there and readable.");
    }).permissions;
    var atomic = cwd.createFileAtomic(ws.io, path, .{ .permissions = permissions, .replace = true }) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not write the fixed {s}: {t}.", .{ path, e }), "Check the directory is writable.");
    };
    defer atomic.deinit(ws.io);
    try atomic.file.writeStreamingAll(ws.io, bytes);
    if (!try unchanged(ws.io, path, r.read)) {
        return ctx.fail(.io, try ws.text.format("{s} changed while zanity was fixing it, so it was left as it is.", .{path}), "Run zanity check --fix again once nothing else is editing it.");
    }
    try atomic.replace(ws.io);
    if (bytes.len == 0) assert.panic("expected a fixed file with content, got an empty {s}; fixFile() must write the kept source and each edit", .{path});
}

/// Whether the file at `path` still holds exactly `expected`.
fn unchanged(io: Io, path: []const u8, expected: []const u8) !bool {
    if (path.len == 0) assert.panic("asked whether a file with no path is unchanged; pass the path fixFile() read", .{});
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var chunk: [16 * 1024]u8 = undefined;
    var offset: usize = 0;
    for (0..expected.len / chunk.len + 2) |_| {
        const n = try file.readPositionalAll(io, &chunk, offset);
        if (n > expected.len - offset or !std.mem.eql(u8, chunk[0..n], expected[offset..][0..n])) return false;
        offset += n;
        if (offset > expected.len) assert.panic("compared {d} bytes of {s} against {d}; stop as soon as the file is longer than expected", .{ offset, path, expected.len });
        if (n < chunk.len) return offset == expected.len;
    }
    assert.panic("read {d} bytes of {s} in chunks without reaching its end; the loop must allow one chunk past {d} bytes", .{ offset, path, expected.len });
}

/// Moves the findings that stay in a fixed file past the lines its edits added or removed.
fn shiftLines(source: []const u8, findings: []Finding) void {
    if (!(findings.len > 0)) assert.panic("expected findings to shift, got none for {d} bytes; call shiftLines() only for a file with findings", .{source.len});
    var delta: i64 = 0;
    for (findings) |*f| {
        if (f.fixed) {
            const edit = f.edit orelse unreachable;
            const removed = std.mem.count(u8, source[edit.start..edit.end], "\n");
            delta += @as(i64, @intCast(std.mem.count(u8, edit.replacement, "\n"))) - @as(i64, @intCast(removed));
            continue;
        }
        f.line = @intCast(@as(i64, f.line) + delta);
    }
    if (delta < -@as(i64, @intCast(source.len))) assert.panic("expected edits to remove at most the file's {d} bytes of lines, got {d} lines; shiftLines() must count newlines only inside each edit's span", .{ source.len, delta });
}

/// Adds the checkable files under `path`, skipping what git ignores. A file named directly is always checked.
fn collect(ctx: *zcli.Context, ws: *Workspace, path: []const u8) !void {
    if (path.len == 0) assert.panic("asked to collect files from an empty path; zcli supplies '.' when none are given", .{});
    const before = ws.files.len;
    var dir = Io.Dir.cwd().openDir(ws.io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => {
            try ws.files.add(path);
            return;
        },
        error.FileNotFound => return ctx.fail(.usage, try ws.text.format("{s} does not exist.", .{path}), "Pass a file or directory to check."),
        else => return e,
    };
    defer dir.close(ws.io);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try dir.realPath(ws.io, &root_buffer)];
    try ws.ignore.loadAncestors(ws.io, root);
    try ws.ignore.loadFile(ws.io, root, ".gitignore");
    var walker = try dir.walkSelectively(ctx.allocator);
    defer walker.deinit();
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (0..ws.limits.files * 2) |_| {
        const entry = try walker.next(ws.io) orelse break;
        const absolute = std.fmt.bufPrint(&absolute_buffer, "{s}/{s}", .{ root, entry.path }) catch continue;
        switch (entry.kind) {
            .directory => if (!skipped(entry.basename) and !ws.ignore.ignored(absolute, .directory)) {
                try ws.ignore.loadFile(ws.io, absolute, ".gitignore");
                try walker.enter(ws.io, entry);
            },
            .file => if (!ws.ignore.ignored(absolute, .file)) try addFile(ws, path, entry),
            else => {},
        }
    } else {
        memory.exceeded = "directory entries";
        return error.LimitExceeded;
    }
    if (ws.files.len < before) assert.panic("collecting {s} dropped files: {d} before, {d} after; collect() must only add files", .{ path, before, ws.files.len });
}

/// Adds a file the walk found under `path` to the source files or the project files, or neither.
fn addFile(ws: *Workspace, path: []const u8, entry: Io.Dir.Walker.Entry) !void {
    if (entry.path.len == 0) assert.panic("the walk under {s} found a file with no path; Walker gives each entry its path", .{path});
    const source = language.forPath(entry.basename) != null;
    if (!source and !project.isProjectFile(entry.path)) return;
    const joined = if (std.mem.eql(u8, path, "."))
        try ws.text.copy(entry.path)
    else
        try ws.text.format("{s}{s}{s}", .{ path, if (std.mem.endsWith(u8, path, "/")) "" else "/", entry.path });
    if (joined.len < entry.path.len) assert.panic("joined '{s}' under '{s}' into the shorter '{s}'; addFile() must keep the whole path", .{ entry.path, path, joined });
    if (source) try ws.files.add(joined) else try ws.project_files.add(joined);
}

fn skipped(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether a directory with an empty name is skipped; skip empty names before calling skipped()", .{});
    if (std.mem.indexOfScalar(u8, name, '/') != null) assert.panic("'{s}' is a path, but skipped() takes one directory name; pass the directory's base name", .{name});
    if (name[0] == '.') return !strings.contains(&project.hidden_dirs, name);
    for (skipped_dirs) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

test "a fix is written only over the bytes it was made against" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "a.py" });
    const line = "x = 1\n";
    const long = try arena.alloc(u8, line.len * 5000);
    for (0..5000) |i| @memcpy(long[i * line.len ..][0..line.len], line);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = long });
    try std.testing.expect(try unchanged(io, path, long));
    try std.testing.expect(!try unchanged(io, path, long[1..]));
    try std.testing.expect(!try unchanged(io, path, try std.mem.concat(arena, u8, &.{ long, "y = 2\n" })));
    try std.testing.expect(!try unchanged(io, path, try std.mem.concat(arena, u8, &.{ "x = 2\n", long[line.len..] })));
}
