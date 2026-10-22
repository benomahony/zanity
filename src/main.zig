const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zcli = @import("zcli");
const zrich = zcli.zrich;
const adapters = @import("adapters");
const language = @import("language.zig");
const check = @import("check.zig");
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
const Ignore = @import("ignore.zig").Ignore;
const infer = @import("infer.zig");
const store = @import("store.zig");
const Live = @import("live.zig").Live;
const config = @import("config.zig");
const starter = @import("init.zig");
const upgrade = @import("upgrade.zig");
const edits = @import("edits.zig");
const calibrate = @import("calibrate.zig");
const lsp = @import("lsp.zig");
const watch = @import("watch.zig");
const Telemetry = @import("telemetry.zig").Telemetry;
const Facts = @import("facts.zig").Facts;
const Finding = @import("facts.zig").Finding;

const CheckOptions = triage.CheckOptions;
const triage = @import("triage.zig");

const InitOptions = struct {
    paths: []const []const u8,
    force: bool = false,
    minimal: bool = false,
};

/// What `zanity init` wrote, as `--json` and `--plain` publish it.
const InitRow = struct {
    path: []const u8,
    rules: usize,
    excluded: usize,
    /// Whether it wrote only the settings, with --minimal.
    minimal: bool,
};

const UpgradeOptions = struct {
    to: ?[]const u8 = null,
};

/// What `zanity upgrade` did or, with --dry-run, would do, as `--json` and `--plain` publish it.
const UpgradeRow = struct {
    path: []const u8,
    from: []const u8,
    to: []const u8,
    /// `upgraded`, `current` when there is nothing newer, or `available` for a --dry-run.
    status: []const u8,
};

const LspOptions = struct { infer: bool = false };

/// `zanity lsp` writes the protocol to stdout itself, so it has no rows.
const LspRow = struct { messages: usize };

/// One finding as `--json` and `--plain` publish it. Lines and columns count from 1. When zanity
/// can fix it, the edit replaces bytes `edit_start` to `edit_end` of the file with `edit_text`.
const baseline = @import("baseline.zig");
const Row = baseline.Row;

const app: zcli.App = .{
    .name = "zanity",
    .version = @import("build_info").version,
    .description = "Fast, deterministic sanity checks for code written by people and agents.",
    .commands = &.{ zcli.command(CheckOptions, Row, .{
        .name = "check",
        .description = "Check files and directories. Exits 1 when an error-level rule fires, or with --fail-on warning when any rule does.",
        .examples = &.{ "zanity check .", "zanity check src tests --rules unbounded-loop,long-function", "zanity check . --json", "zanity check . --fix", "zanity check . --fail-on warning", "zanity check . --strict", "zanity check . --watch" },
        .result_title = "Findings",
        .positional = .{ .name = "paths", .metavar = "PATH", .help = "Files or directories to check.", .default = &.{"."} },
        .options = triage.check_options,
    }, .{ .run = runCheck, .human = renderHuman }), zcli.command(InitOptions, InitRow, .{
        .name = "init",
        .description = "Write a zanity.toml with every setting and rule explained, ready to trim.",
        .examples = &.{ "zanity init", "zanity init --minimal", "zanity init path/to/project", "zanity init --force" },
        .result_title = "Written",
        .positional = .{ .name = "paths", .metavar = "DIR", .help = "The project's root, where zanity.toml goes.", .default = &.{"."} },
        .options = &.{
            .{ .name = "force", .help = "Replace an existing zanity.toml." },
            .{ .name = "minimal", .help = "Write only the settings, without the notes and the list of every rule." },
        },
    }, .{ .run = runInit, .human = renderInit }), zcli.command(UpgradeOptions, UpgradeRow, .{
        .name = "upgrade",
        .description = "Replace this zanity with the latest release, or the one --to names, after checking its SHA-256.",
        .examples = &.{ "zanity upgrade", "zanity upgrade --dry-run", "zanity upgrade --to 0.1.4" },
        .result_title = "Upgrade",
        .options = &.{
            .{ .name = "to", .metavar = "VERSION", .help = "Install this release instead of the latest, even if it is older.", .example = "0.1.4" },
        },
    }, .{ .run = runUpgrade, .dry_run = previewUpgrade, .human = renderUpgrade }), zcli.command(LspOptions, LspRow, .{
        .name = "lsp",
        .description = "Serve the language server protocol on stdin and stdout: findings as diagnostics, refreshed on save, and zanity's fixes as code actions.",
        .examples = &.{ "zanity lsp", "zanity lsp --infer" },
        .result_title = "Language server",
        .options = &.{
            .{ .name = "infer", .help = "Also ask the model on every check, as zanity check --infer does; answers are cached, so only edited code is asked again." },
        },
    }, .{ .run = runLsp }), zcli.command(calibrate.LabelOptions, calibrate.LabelRow, .{
        .name = "mark",
        .description = "Say whether a --infer finding is real: --confirm it, or mark it --not-a-problem, which stops it being reported for that function.",
        .examples = &.{ "zanity mark app.py:12 cwe-15 --not-a-problem", "zanity mark app.py:12 vague-error --confirm" },
        .result_title = "Marked",
        .positional = .{ .name = "finding", .metavar = "PATH:LINE RULE", .help = "Where the finding is, as check reports it, and its rule." },
        .options = &.{
            .{ .name = "confirm", .help = "The finding is real." },
            .{ .name = "not-a-problem", .help = "The finding is wrong for this function; don't report it there again." },
        },
    }, .{ .run = calibrate.runMark }), zcli.command(calibrate.ReviewOptions, calibrate.ReviewRow, .{
        .name = "review",
        .description = "List unlabelled answers to one --infer question to label, spread evenly from unsure to sure, so labels cover what the model missed as well as what it found.",
        .examples = &.{ "zanity review cwe-15", "zanity review vague-error --limit 50" },
        .result_title = "To label",
        .positional = .{ .name = "rules", .metavar = "RULE", .help = "The question to review." },
        .options = &.{
            .{ .name = "limit", .metavar = "N", .help = "List at most N answers.", .example = "50" },
        },
    }, .{ .run = calibrate.runReview }), zcli.command(calibrate.StatsOptions, calibrate.StatsRow, .{
        .name = "stats",
        .description = "Show how often each --infer question fires and how many of its answers are unsure; with --thresholds, its precision and recall at each threshold against your labels.",
        .examples = &.{ "zanity stats", "zanity stats --rule cwe-15", "zanity stats --thresholds" },
        .result_title = "Questions",
        .options = &.{
            .{ .name = "rule", .metavar = "RULE", .help = "Show only this question.", .example = "cwe-15" },
            .{ .name = "thresholds", .help = "Measure each labelled question's precision and recall at a range of thresholds." },
        },
    }, .{ .run = calibrate.runStats }) },
};

/// Everything a run needs, allocated once at startup and reused for every file.
const Workspace = struct {
    live: ?*Live = null,
    /// What `zanity init` wrote; one run writes one file.
    init_row: [1]InitRow = undefined,
    /// What `zanity upgrade` did; one run replaces one executable.
    upgrade_row: [1]UpgradeRow = undefined,
    /// The zanity.toml in effect, for its [paths] sections.
    settings: ?*const config.Config = null,
    limits: memory.Limits,
    text: memory.Text,
    facts: Facts,
    naming: naming.ConceptScratch,
    liveness: structure.LiveScratch,
    graph: graph.CycleScratch,
    findings: memory.Bounded(Finding),
    files: memory.Bounded([]const u8),
    /// Build, lint, type-check and CI configuration, checked as text.
    project_files: memory.Bounded([]const u8),
    /// The absolute path of each directory the walk entered, which --watch watches on Linux.
    dirs: memory.Bounded([]const u8),
    /// The order checkFiles() hands files to its workers in.
    order: []batch.Sized,
    rows: memory.Bounded(Row),
    table: report.TableScratch,
    source: []u8,
    fixed: []u8,
    analysis: []u8,
    ignore: Ignore,
    environ: ?*std.process.Environ.Map = null,
    /// The command line after the program's name, which --watch reruns.
    args: []const []const u8 = &.{},
    /// Whether the command line chose --json or --plain, which turns off agent output.
    chose_format: bool = false,
    inference: ?infer.Inference = null,
    source_cache: ?store.Store = null,
    cache_hits: usize = 0,
    checkers: [language.count]?check.Checker = @splat(null),
    checker_rules: rules.Set = .{},
    workers: [batch.max_workers]?*batch.Worker = @splat(null),
    worker_view: [batch.max_workers]*batch.Worker = undefined,
    checked: usize = 0,
    io: Io = undefined,
    review: baseline.Review = .{},
    baseline_buffer: []u8,
    history: @import("history.zig").History,

    fn initWorkspace(gpa: Allocator, limits: memory.Limits) Allocator.Error!*Workspace {
        if (limits.files == 0) assert.panic("memory.Limits.files is 0, so zanity could not check any file", .{});
        if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so zanity could not read any file", .{});
        const ws = try gpa.create(Workspace);
        ws.* = .{
            .limits = limits,
            .text = try .initText(gpa, limits.text_bytes),
            .facts = undefined,
            .naming = try .initNamingScratch(gpa, limits),
            .liveness = try .initLiveScratch(gpa, limits),
            .graph = try .initGraphScratch(gpa, limits),
            .findings = try .initBounded(gpa, limits.findings, "findings across all files"),
            .files = try .initBounded(gpa, limits.files, "files"),
            .project_files = try .initBounded(gpa, 1024, "project files"),
            .dirs = try .initBounded(gpa, limits.files, "directories"),
            .order = try memory.reserve(gpa, batch.Sized, limits.files),
            .rows = try .initBounded(gpa, 2 * limits.findings, "findings and resolved baseline entries"),
            .table = try .initTableScratch(gpa, limits.files),
            .history = try .initHistory(gpa, limits.findings),
            .baseline_buffer = try memory.reserve(gpa, u8, 1 << 28),
            .source = try memory.reserve(gpa, u8, limits.file_bytes + 1),
            .fixed = try memory.reserve(gpa, u8, 2 * limits.file_bytes),
            .analysis = try memory.reserve(gpa, u8, limits.analysis_bytes),
            .ignore = try .initIgnore(gpa, limits),
        };
        ws.facts = try .initFacts(gpa, limits, &ws.text);
        return ws;
    }

    /// Compiles the queries of each language the run will check, and only those.
    fn initCheckers(ws: *Workspace, gpa: Allocator, selected: rules.Set) !void {
        if (selected.len == 0) assert.panic("compiling checkers with no rules selected; runCheck always selects at least one", .{});
        if (!ws.checker_rules.same(selected)) {
            ws.checkers = @splat(null);
            ws.checker_rules = selected;
        }
        for (ws.files.items()) |path| {
            const adapter = language.forPath(path) orelse continue;
            const slot = &ws.checkers[language.indexOf(adapter)];
            if (slot.* == null) slot.* = try check.Checker.initChecker(gpa, try language.load(adapter), selected);
        }
        if (ws.checkers.len != adapters.all.len) assert.panic("{d} checker slots for {d} languages; initCheckers() must make one slot per adapter in adapters.all", .{ ws.checkers.len, adapters.all.len });
    }

    /// Workers are expensive, so watched checks keep one per core and reuse their buffers.
    fn checkWorkers(ws: *Workspace, gpa: Allocator, files: usize) ![]const *batch.Worker {
        if (files == 0) assert.panic("making workers to check no files; checkFiles() returns early when there are none", .{});
        const cores = std.Thread.getCpuCount() catch 1;
        const count = @max(1, @min(cores, files, batch.max_workers));
        if (count > files) assert.panic("using {d} workers for {d} files; no worker should be idle", .{ count, files });
        for (0..count) |i| {
            if (ws.workers[i] == null) ws.workers[i] = try .initWorker(gpa, ws.limits);
            ws.worker_view[i] = ws.workers[i].?;
        }
        return ws.worker_view[0..count];
    }

    /// Starts another check without reallocating its large, fixed-capacity buffers.
    fn resetCheck(ws: *Workspace) void {
        ws.text.used = 0;
        ws.facts.reset();
        ws.naming.reset();
        inline for (.{ "findings", "files", "project_files", "dirs", "rows" }) |field| @field(ws, field).clear();
        ws.ignore.reset();
        ws.settings = null;
        ws.live = null;
        ws.checked = 0;
        ws.cache_hits = 0;
        if (ws.files.len != 0 or ws.findings.len != 0 or ws.text.used != 0) assert.panic("reset workspace kept {d} files, {d} findings and {d} bytes; resetCheck() must empty the run", .{ ws.files.len, ws.findings.len, ws.text.used });
        if (ws.settings != null or ws.live != null) assert.panic("reset workspace kept settings={d} or progress={d}; both must be 0 between checks", .{ @intFromBool(ws.settings != null), @intFromBool(ws.live != null) });
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
    const rest = args[1..];
    ws.args = rest;
    for (rest) |arg| ws.chose_format = ws.chose_format or std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--plain");
    var runtime = zcli.native.runtime(init, &out_writer.interface, &err_writer.interface);
    runtime.user_data = ws;
    const code = app.run(init.gpa, rest, runtime);
    if (@backingInt(code) > 130) assert.panic("zcli returned exit code {d}; codes above 130 collide with signals", .{@backingInt(code)});
    return @backingInt(code);
}

pub fn workspaceOf(ctx: *zcli.Context) *Workspace {
    const ws: *Workspace = @ptrCast(@alignCast(ctx.runtime.user_data orelse unreachable));
    if (ws.limits.files == 0) assert.panic("the workspace allows 0 files; it was not built by initWorkspace", .{});
    if (ws.files.capacity() != ws.limits.files) assert.panic("the workspace has room for {d} files but its limit is {d}; it was not built by initWorkspace", .{ ws.files.capacity(), ws.limits.files });
    return ws;
}

fn runCheck(ctx: *zcli.Context, options: CheckOptions) ![]const Row {
    if (options.paths.len == 0) assert.panic("check ran with no paths; zcli supplies '.' when none are given", .{});
    const ws = workspaceOf(ctx);
    try baseline.validateOptions(ctx, ws, options);
    const agent = try speaksToAgent(ctx, ws, options.agent);
    const settings = try loadSettings(ctx, ws, std.heap.page_allocator);
    if (options.watch) return watchCheck(ctx, ws, options, agent);
    ws.settings = &settings;
    defer ws.settings = null;
    rules.custom = settings.questionRules();
    defer rules.custom = &.{};
    var selected = if (options.rules) |list| try parseRules(ctx, ws, list) else settings.selection(options.strict);
    if (options.rules != null and options.strict) selected.includeTier(.strict);
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

/// Whether to write for a coding agent: when --agent asks, or when one is running zanity and the
/// command line chose no other format.
/// Each change starts one check, so this many is far more than any session makes.
const max_watch_runs = 1 << 40;
/// The most arguments a watched command line may have, which the rerun copies.
const max_watch_args = 256;

/// The command line, and the environment, each rerun of a watched check is started with.
const Rerun = struct {
    exe: [std.fs.max_path_bytes]u8,
    exe_len: usize,
    argv_buffer: [max_watch_args][]const u8,
    argv: []const []const u8,
    environ: *std.process.Environ.Map,
};

/// Finds this zanity, and gives its reruns the command line without --watch and an environment
/// that says they are watched, so their --agent output says saving checks again.
fn initRerun(rerun: *Rerun, ctx: *zcli.Context, ws: *Workspace) !void {
    if (ws.args.len + 2 > max_watch_args) return ctx.fail(.usage, try ws.text.format("--watch takes at most {d} arguments; this command line has {d}.", .{ max_watch_args - 2, ws.args.len }), "Name a directory instead of each file in it.");
    rerun.exe_len = std.process.executablePath(ws.io, &rerun.exe) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not find where this zanity is installed, to rerun its checks: {t}.", .{e}), "Reinstall it with install.sh, as the README describes.");
    };
    if (rerun.exe_len == 0 or rerun.exe_len > rerun.exe.len) assert.panic("found this zanity at a path of {d} bytes in room for {d}; executablePath() returns a real path that fits", .{ rerun.exe_len, rerun.exe.len });
    rerun.argv = watch.rerunArgs(&rerun.argv_buffer, rerun.exe[0..rerun.exe_len], ws.args);
    if (rerun.argv.len > ws.args.len + 2) assert.panic("the rerun has {d} arguments from {d}; rerunArgs() drops --watch and adds at most --agent", .{ rerun.argv.len, ws.args.len });
    rerun.environ = ws.environ orelse assert.panic("zanity check --watch ran without the environment; main() passes it to the workspace", .{});
    try rerun.environ.put(watch.env_var, "1");
}

/// Runs `zanity check` without --watch, then again each time the operating system reports that a
/// file it checks under `paths`, or zanity.toml, changed. Stops only when Ctrl-C ends the process.
fn spawnedWatchCheck(ctx: *zcli.Context, ws: *Workspace, options: CheckOptions) ![]const Row {
    const paths = options.paths;
    if (paths.len == 0) assert.panic("watching no paths; zcli supplies '.' when none are given", .{});
    if (paths.len > ws.args.len) assert.panic("watching {d} paths from a command line of {d} arguments; each path is an argument", .{ paths.len, ws.args.len });
    var rerun: Rerun = undefined;
    try initRerun(&rerun, ctx, ws);
    var watcher: watch.Watcher = undefined;
    var filter: watch.ChangeFilter = undefined;
    var roots: [max_watch_args][]const u8 = undefined;
    var trees: [max_watch_args][]const u8 = undefined;
    try startWatching(ctx, ws, paths, .{ .watcher = &watcher, .filter = &filter, .roots = roots[0..paths.len], .trees = trees[0..paths.len] });
    const terminal = Io.File.stdout().isTty(ws.io) catch false;
    const out = ctx.runtime.out;
    const err = ctx.runtime.err;
    for (0..max_watch_runs) |_| {
        if (terminal) try out.writer.writeAll(watch.clear_screen);
        try out.writer.flush();
        if (options.baseline != null) {
            try @import("watch_review.zig").isolatedCheck(ctx, ws, &rerun, options);
            try out.writer.flush();
        } else {
            var child = std.process.spawn(ws.io, .{ .argv = rerun.argv, .environ_map = rerun.environ }) catch |e| {
                return ctx.fail(.io, try ws.text.format("Could not rerun {s}: {t}.", .{ rerun.argv[0], e }), "Reinstall it with install.sh, as the README describes.");
            };
            _ = try child.wait(ws.io);
        }
        if (!ctx.quiet) try err.writer.writeAll("zanity: watching for changes; save a file to check again, Ctrl-C to stop.\n");
        try err.writer.flush();
        watcher.wait() catch |e| return ctx.fail(.io, try ws.text.format("Lost track of changes to the files: {t}.", .{e}), "Run zanity check --watch again.");
    }
    assert.panic("ran {d} checks without being stopped; no session saves that often", .{max_watch_runs});
}

/// Keeps the expensive checker, workers and cache resident. Whole-workspace facts are rebuilt so
/// cross-file rules remain correct; unchanged source analysis comes from the cache.
fn watchCheck(ctx: *zcli.Context, ws: *Workspace, options: CheckOptions, asked_for_agent: bool) ![]const Row {
    const paths = options.paths;
    if (options.infer or options.fix) return spawnedWatchCheck(ctx, ws, options);
    if (paths.len == 0) assert.panic("watching no paths; zcli supplies '.' when none are given", .{});
    if (paths.len > ws.args.len) assert.panic("watching {d} paths from a command line of {d} arguments; each path is an argument", .{ paths.len, ws.args.len });
    var watcher: watch.Watcher = undefined;
    var filter: watch.ChangeFilter = undefined;
    var roots: [max_watch_args][]const u8 = undefined;
    var trees: [max_watch_args][]const u8 = undefined;
    try startWatching(ctx, ws, paths, .{ .watcher = &watcher, .filter = &filter, .roots = roots[0..paths.len], .trees = trees[0..paths.len] });
    const checks = try Workspace.initWorkspace(std.heap.page_allocator, ws.limits);
    checks.io = ws.io;
    checks.environ = ws.environ;
    checks.args = ws.args;
    checks.chose_format = ws.chose_format;
    if (checks.environ == null) assert.panic("zanity check --watch ran without the environment; main() passes it to the workspace", .{});
    var settings_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer settings_arena.deinit();
    const terminal = Io.File.stdout().isTty(ws.io) catch false;
    const out = ctx.runtime.out;
    const err = ctx.runtime.err;
    const agent = watch.agentOutput(ws.args, ws.chose_format, asked_for_agent);
    for (0..max_watch_runs) |_| {
        _ = settings_arena.reset(.retain_capacity);
        checks.resetCheck();
        ctx.status = .success;
        ctx.failure = null;
        if (terminal) try out.writer.writeAll(watch.clear_screen);
        const settings = try loadSettings(ctx, checks, settings_arena.allocator());
        checks.settings = &settings;
        rules.custom = settings.questionRules();
        var selected = if (options.rules) |list| try parseRules(ctx, checks, list) else settings.selection(options.strict);
        if (options.rules != null and options.strict) selected.includeTier(.strict);
        var live = Live.initLive(console(ctx, err), checks.io, !ctx.quiet);
        checks.live = &live;
        const counts = checkPaths(ctx, checks, options, selected) catch |e| switch (e) {
            error.LimitExceeded => return ctx.fail(.usage, try checks.text.format("This run has more {s} than zanity is built to hold.", .{memory.exceeded}), "Check fewer files at once, or report it if the input is ordinary."),
            else => return e,
        };
        if (triage.failsReview(options, counts, checks.review)) ctx.status = .failure;
        try renderWatched(ctx, checks, .{ .options = options, .counts = counts, .agent = agent });
        try out.writer.flush();
        if (!ctx.quiet) try err.writer.writeAll("zanity: watching for changes; save a file to check again, Ctrl-C to stop.\n");
        try err.writer.flush();
        watcher.wait() catch |e| return ctx.fail(.io, try checks.text.format("Lost track of changes to the files: {t}.", .{e}), "Run zanity check --watch again.");
    }
    assert.panic("ran {d} checks without being stopped; no session saves that often", .{max_watch_runs});
}

const WatchOutput = struct { options: CheckOptions, counts: report.Counts, agent: bool };

fn renderWatched(ctx: *zcli.Context, ws: *Workspace, output: WatchOutput) !void {
    const options = output.options;
    const counts = output.counts;
    if (options.paths.len == 0) assert.panic("rendering a watched check with no paths; zcli supplies '.' when none are given", .{});
    if (!triage.special(options) and ws.rows.len != counts.errors + counts.warnings) assert.panic("rendering {d} watched rows for {d} errors and {d} warnings; checkPaths makes one row per finding", .{ ws.rows.len, counts.errors, counts.warnings });
    if (triage.special(options)) {
        try triage.renderOutput(ctx, ws, options, output.agent);
        return;
    }
    const out = ctx.runtime.out;
    const err = ctx.runtime.err;
    if (output.agent) {
        try report.renderAgent(out.writer, .{ .findings = ws.findings.items(), .counts = counts, .paths = options.paths, .limit = options.limit, .watching = true });
        try triage.continuation(out.writer, ws.args, 0, 10000);
        if (ws.cache_hits > 0) try err.writer.print("zanity: reused cached deterministic analysis for {d} of {d} source files; query {s}'s source_analyses table for the cached facts and findings.\n", .{ ws.cache_hits, ws.checked, ws.source_cache.?.path });
        return;
    }
    if (ctx.format == .human) {
        try report.render(.{ .console = console(ctx, out), .scratch = &ws.table, .text = &ws.text }, ws.findings.items());
        try report.summarise(console(ctx, err), counts);
        return;
    }
    try report.summarise(console(ctx, err), counts);
    try watch.renderRows(Row, out.writer, ctx.format == .json, ws.rows.items());
}

/// Where startWatching() puts the watcher and the absolute paths it watches.
const WatchSlots = struct { watcher: *watch.Watcher, filter: *watch.ChangeFilter, roots: [][]const u8, trees: [][]const u8 };

/// Walks `paths` once, to load the ignore files and find every directory, then starts the
/// operating system's watch on them.
fn startWatching(ctx: *zcli.Context, ws: *Workspace, paths: []const []const u8, slots: WatchSlots) !void {
    if (slots.roots.len != paths.len or slots.trees.len != paths.len) assert.panic("room for {d} roots and {d} trees for {d} paths; give each path one of each", .{ slots.roots.len, slots.trees.len, paths.len });
    for (paths) |path| try collect(ctx, ws, path);
    for (paths, slots.roots, slots.trees) |path, *root, *tree| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        root.* = try ws.text.copy(buffer[0..try Io.Dir.cwd().realPathFile(ws.io, path, &buffer)]);
        const stat = try Io.Dir.cwd().statFile(ws.io, path, .{});
        tree.* = if (stat.kind == .directory) root.* else std.fs.path.dirname(root.*) orelse root.*;
        if (stat.kind != .directory) try ws.dirs.add(tree.*);
    }
    if (ws.dirs.len < paths.len) assert.panic("the walk found {d} directories for {d} paths; collect() records each directory it starts from", .{ ws.dirs.len, paths.len });
    slots.filter.* = .{ .roots = slots.roots, .ignore = &ws.ignore };
    slots.watcher.initWatcher(std.heap.page_allocator, ws.io, .{ .scope = slots.filter, .trees = slots.trees, .directories = ws.dirs.items() }) catch |e| switch (e) {
        error.TooManyWatches => return ctx.fail(.io, try ws.text.format("The system ran out of watches for the {d} directories here.", .{ws.dirs.len}), "Raise fs.inotify.max_user_watches, or watch fewer paths."),
        else => return ctx.fail(.io, try ws.text.format("This system can't report file changes to zanity: {t}.", .{e}), "Run zanity check without --watch, or report it with your operating system's name."),
    };
}

/// Reads zanity.toml, opens the cache, and applies the file's excludes to the walk.
fn loadSettings(ctx: *zcli.Context, ws: *Workspace, gpa: Allocator) !config.Config {
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

fn speaksToAgent(ctx: *zcli.Context, ws: *const Workspace, asked: bool) !bool {
    if (asked and ws.chose_format) return ctx.fail(.usage, "--agent cannot be combined with --json or --plain.", "Choose one: --agent for a coding agent to read, --json or --plain for a program to parse.");
    const agent = asked or (!ws.chose_format and agentRunning(ws));
    if (agent and ws.chose_format) assert.panic("writing for an agent although the command line chose --json or --plain; speaksToAgent() must refuse that", .{});
    if (asked and !agent) assert.panic("--agent was given but agent output is off; speaksToAgent() must honour --agent", .{});
    return agent;
}

/// Writes the findings for the agent in place of zcli's rows, which it then has none of to print.
fn reportToAgent(ctx: *zcli.Context, ws: *Workspace, options: CheckOptions, counts: report.Counts) ![]const Row {
    const paths = options.paths;
    if (paths.len == 0) assert.panic("reporting to an agent with no checked paths to name; zcli supplies '.' when none are given", .{});
    if (ws.findings.len != counts.errors + counts.warnings) assert.panic("{d} findings for {d} errors and {d} warnings; count the findings being reported", .{ ws.findings.len, counts.errors, counts.warnings });
    const out = ctx.runtime.out;
    try report.renderAgent(out.writer, .{ .findings = ws.findings.items(), .counts = counts, .paths = paths, .limit = options.limit, .watching = watching(ws) });
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
    if (value.len > 1) assert.panic("{s} is '{s}'; zanity check --watch sets it to 1, so it was set by hand", .{ watch.env_var, value });
    if (ws.args.len == 0) assert.panic("a rerun of zanity check --watch with no arguments; the watcher passes check and its options", .{});
    return std.mem.eql(u8, value, "1");
}

fn agentRunning(ws: *const Workspace) bool {
    if (ws.chose_format) assert.panic("asked whether an agent runs zanity after the command line chose a format; speaksToAgent() checks chose_format first", .{});
    const environ = ws.environ orelse return false;
    const value = environ.get("CLAUDECODE") orelse return false;
    if (value.len > 64) assert.panic("CLAUDECODE is {d} bytes long; Claude Code sets it to 1, so check what set it", .{value.len});
    return value.len > 0 and !std.mem.eql(u8, value, "0");
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

fn runLsp(ctx: *zcli.Context, options: LspOptions) ![]const LspRow {
    const ws = workspaceOf(ctx);
    const environ = ws.environ orelse assert.panic("zanity lsp ran without the environment; main() passes it to the workspace", .{});
    const exe = std.process.executablePathAlloc(ws.io, ctx.allocator) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not find where this zanity is installed, to run its checks: {t}.", .{e}), "Reinstall it with install.sh, as the README describes.");
    };
    ws.source_cache = store.Store.initStore(std.heap.page_allocator, ws.io, environ, ws.limits.store_bytes) catch null;
    var telemetry = Telemetry.initTelemetry(std.heap.page_allocator, ws.io, environ, app.version) catch null;
    const services: lsp.Services = .{
        .exe = exe,
        .version = app.version,
        .infer = options.infer,
        .store = if (ws.source_cache) |*s| s else null,
        .telemetry = if (telemetry) |*t| t else null,
    };
    const out = ctx.runtime.out;
    var server = try lsp.LanguageServer.initLanguageServer(std.heap.page_allocator, ws.io, out.writer, services);
    var in_buffer: [64 * 1024]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(ws.io, &in_buffer);
    if (!try server.serve(&in.interface)) ctx.status = .failure;
    ctx.format = .plain;
    if (exe.len == 0) assert.panic("found this zanity at an empty path; executablePathAlloc() returns a path or fails", .{});
    if (ctx.format != .plain) assert.panic("zanity lsp left the {t} format on, which would print an empty result after the protocol", .{ctx.format});
    return &.{};
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
    try starter.renderConfig(&w, .{ .languages = &counts, .present = present[0..found], .minimal = options.minimal });
    cwd.writeFile(ws.io, .{ .sub_path = target, .data = w.buffered(), .flags = .{ .exclusive = !options.force } }) catch |e| switch (e) {
        error.PathAlreadyExists => return ctx.fail(.usage, try ws.text.format("{s} already exists.", .{target}), "Edit it, or pass --force to replace it with a fresh one."),
        else => return ctx.fail(.io, try ws.text.format("Could not write {s}: {t}.", .{ target, e }), "Check that the directory exists and is writable."),
    };
    if (w.buffered().len == 0) assert.panic("zanity init wrote an empty {s}; renderConfig() in src/init.zig must write the whole file", .{target});
    if (found > starter.usual_excludes.len) assert.panic("found {d} of the {d} usual excludes; the loop in runInit() must add each at most once", .{ found, starter.usual_excludes.len });
    ws.init_row[0] = .{ .path = target, .rules = rules.all.len, .excluded = found, .minimal = options.minimal };
    return &ws.init_row;
}

fn renderInit(ctx: *zcli.Context, rows: []const InitRow) !void {
    if (rows.len != 1) assert.panic("zanity init reported {d} files written; runInit() writes exactly one", .{rows.len});
    const row = rows[0];
    const out = console(ctx, ctx.runtime.out);
    if (row.minimal) {
        try out.writer.print("Wrote {s}: every rule on, with nothing explained; `zanity init --force` writes the full file with notes and the list of all {d} rules.\n", .{ row.path, row.rules });
    } else try out.writer.print("Wrote {s}: every setting explained, and all {d} rules listed with how to fix what they find.\n", .{ row.path, row.rules });
    if (row.excluded > 0) try out.writer.print("It excludes the {d} fixture or vendored {s} it found; check that list.\n", .{ row.excluded, if (row.excluded == 1) "directory" else "directories" });
    try out.writer.writeAll("Next: run `zanity check .`, then delete or change what you don't need.\n");
    if (row.path.len == 0) assert.panic("zanity init reported writing a file with no path; runInit() must pass the path it wrote", .{});
}

fn runUpgrade(ctx: *zcli.Context, options: UpgradeOptions) ![]const UpgradeRow {
    const rows = try upgradeTo(ctx, options, true);
    if (std.mem.eql(u8, rows[0].status, "available")) assert.panic("zanity upgrade left release {s} available instead of installing it; call upgradeTo() with install enabled", .{rows[0].to});
    if (rows.len != 1) assert.panic("zanity upgrade reported {d} executables; upgradeTo() replaces exactly one", .{rows.len});
    return rows;
}

fn previewUpgrade(ctx: *zcli.Context, options: UpgradeOptions) ![]const UpgradeRow {
    const rows = try upgradeTo(ctx, options, false);
    if (std.mem.eql(u8, rows[0].status, "upgraded")) assert.panic("zanity upgrade --dry-run installed release {s}; call upgradeTo() with install disabled", .{rows[0].to});
    if (rows.len != 1) assert.panic("zanity upgrade --dry-run reported {d} executables; upgradeTo() previews exactly one", .{rows.len});
    return rows;
}

/// The release a run of `zanity upgrade` fetches and installs, and what it reports failures through.
const Upgrader = struct {
    ctx: *zcli.Context,
    ws: *Workspace,
    client: std.http.Client,
};

/// Finds the release to install and, when `install` is set and it differs from this build, puts it
/// in place of the running executable.
fn upgradeTo(ctx: *zcli.Context, options: UpgradeOptions, install: bool) ![]const UpgradeRow {
    const ws = workspaceOf(ctx);
    const current = app.version;
    if (current.len == 0) assert.panic("this build reports an empty version; build.zig sets it to dev or the release's", .{});
    const path = std.process.executablePathAlloc(ws.io, ctx.allocator) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not find where this zanity is installed: {t}.", .{e}), "Reinstall it with install.sh, as the README describes.");
    };
    if (upgrade.manager(path)) |m| return ctx.fail(.usage, try ws.text.format("{s} was installed by {s}, which would undo an upgrade made behind its back.", .{ path, m.name }), try ws.text.format("Run `{s}` instead.", .{m.command}));
    if (options.to) |to| if (upgrade.versionOrder(to, to) == null) {
        return ctx.fail(.usage, try ws.text.format("--to '{s}' is not a release version.", .{to}), "Pass one such as --to 0.1.4; the releases are listed at " ++ upgrade.releases_url ++ ".");
    };
    if (options.to == null and upgrade.versionOrder(current, "0.0.0") == null) {
        return ctx.fail(.usage, try ws.text.format("This zanity is a {s} build from source, so no release is newer or older than it.", .{current}), "Rebuild it with `zig build`, or pass --to 0.1.4 to replace it with that release.");
    }
    var up: Upgrader = .{ .ctx = ctx, .ws = ws, .client = .{ .allocator = ctx.allocator, .io = ws.io } };
    defer up.client.deinit();
    const release = try fetchRelease(&up, options.to);
    const asset = release.assetFor(upgrade.asset_name) orelse {
        return ctx.fail(.usage, try ws.text.format("Release {s} has no {s}, the build for this machine.", .{ release.tag_name, upgrade.asset_name }), "Pick another release from " ++ upgrade.releases_url ++ ", or build from source as the README describes.");
    };
    const order = upgrade.versionOrder(current, release.tag_name);
    const wanted = if (options.to != null) order != .eq else order == .lt;
    ws.upgrade_row[0] = .{ .path = path, .from = current, .to = release.tag_name, .status = if (!wanted) "current" else if (install) "upgraded" else "available" };
    if (wanted and install) try replaceExecutable(&up, path, asset);
    if (wanted == std.mem.eql(u8, ws.upgrade_row[0].status, "current")) assert.panic("zanity upgrade reports {s} for release {s}, which it {s}", .{ ws.upgrade_row[0].status, release.tag_name, if (wanted) "wanted" else "did not want" });
    return &ws.upgrade_row;
}

/// Asks GitHub's API about the latest release, or `version`'s.
fn fetchRelease(up: *Upgrader, version: ?[]const u8) !upgrade.Release {
    const ctx = up.ctx;
    const ws = up.ws;
    if (version) |v| if (v.len == 0) assert.panic("zanity upgrade --to was given an empty version; upgradeTo() refuses one that is not a version", .{});
    const environ = ws.environ orelse assert.panic("zanity upgrade ran without the environment; main() passes it to the workspace", .{});
    const token = environ.get("GITHUB_TOKEN") orelse environ.get("GH_TOKEN");
    var url_buffer: [256]u8 = undefined;
    var url: std.Io.Writer = .fixed(&url_buffer);
    var body: std.Io.Writer.Allocating = .init(ctx.allocator);
    const status = upgrade.get(&up.client, try upgrade.releaseUrl(&url, version), &body, if (token) |t| (if (t.len == 0 or std.mem.indexOfAny(u8, t, "\r\n") != null) null else t) else null) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not reach GitHub to find the release: {t}.", .{e}), "Check the network connection, then run zanity upgrade again.");
    };
    switch (status) {
        .ok => {},
        .not_found => return ctx.fail(.usage, try ws.text.format("There is no release v{s}.", .{upgrade.trimV(version orelse "latest")}), "Pick a version from " ++ upgrade.releases_url ++ "."),
        .forbidden, .too_many_requests => return ctx.fail(.io, "GitHub refused the request, most likely by its rate limit for unauthenticated clients.", "Set GITHUB_TOKEN to a GitHub token, or wait an hour and run zanity upgrade again."),
        else => return ctx.fail(.io, try ws.text.format("GitHub answered {d} when asked for the release.", .{@backingInt(status)}), "Run zanity upgrade again; if it persists, check https://www.githubstatus.com."),
    }
    const release = upgrade.parseRelease(ctx.allocator, body.written()) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not read GitHub's description of the release: {t}.", .{e}), "Run zanity upgrade again, and report it if it happens twice.");
    };
    if (version) |v| if (upgrade.versionOrder(v, release.tag_name)) |order| if (order != .eq) {
        return ctx.fail(.io, try ws.text.format("GitHub answered the request for v{s} with release {s}.", .{ upgrade.trimV(v), release.tag_name }), "Run zanity upgrade again, and report it if it happens twice.");
    };
    if (release.tag_name.len == 0) assert.panic("GitHub's release has an empty tag; parseRelease() must refuse it", .{});
    return release;
}

/// Downloads `asset`, checks it against the SHA-256 GitHub records, and puts it at `path`.
fn replaceExecutable(up: *Upgrader, path: []const u8, asset: upgrade.Release.Asset) !void {
    const ctx = up.ctx;
    const ws = up.ws;
    if (path.len == 0) assert.panic("replacing an executable with no path by {s}; upgradeTo() passes the running one's", .{asset.name});
    const digest = asset.digest orelse {
        return ctx.fail(.usage, try ws.text.format("The release lists no SHA-256 for {s}, so its download cannot be checked.", .{asset.name}), "Download it from " ++ upgrade.releases_url ++ " and check it yourself, or install with install.sh.");
    };
    var body: std.Io.Writer.Allocating = .init(ctx.allocator);
    const status = upgrade.get(&up.client, asset.browser_download_url, &body, null) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not download {s}: {t}.", .{ asset.browser_download_url, e }), "Check the network connection, then run zanity upgrade again.");
    };
    if (status != .ok) return ctx.fail(.io, try ws.text.format("GitHub answered {d} to the download of {s}.", .{ @backingInt(status), asset.browser_download_url }), "Run zanity upgrade again; this zanity is unchanged.");
    const bytes = body.written();
    if (!upgrade.matches(bytes, digest)) {
        return ctx.fail(.io, try ws.text.format("The {d}-byte download of {s} does not hash to the release's {s}.", .{ bytes.len, asset.name, digest }), "Run zanity upgrade again; this zanity is unchanged. Report it if it happens twice.");
    }
    upgrade.replace(ws.io, path, bytes) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not replace {s}: {t}.", .{ path, e }), "Check that you can write to its directory; if it was installed as root, run the upgrade as root too.");
    };
    if (bytes.len == 0) assert.panic("installed an empty {s}; upgrade.matches() must refuse a download that does not hash to {s}", .{ asset.name, digest });
}

fn renderUpgrade(ctx: *zcli.Context, rows: []const UpgradeRow) !void {
    if (rows.len != 1) assert.panic("zanity upgrade reported {d} executables; upgradeTo() replaces exactly one", .{rows.len});
    const row = rows[0];
    const out = console(ctx, ctx.runtime.out);
    if (std.mem.eql(u8, row.status, "current")) {
        try out.writer.print("zanity {s} at {s} is already release {s}; there is nothing to upgrade.\n", .{ row.from, row.path, row.to });
    } else if (std.mem.eql(u8, row.status, "available")) {
        try out.writer.print("zanity {s} at {s} would become {s}. Run `zanity upgrade` to install it.\n", .{ row.from, row.path, row.to });
    } else {
        try out.writer.print("Upgraded zanity {s} to {s} at {s}.\n", .{ row.from, row.to, row.path });
    }
    if (row.path.len == 0) assert.panic("zanity upgrade reported no executable path; upgradeTo() must pass the path it found", .{});
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
            _ = try ws.text.copy("The rules are: all (every rule, including those off by default), strict (the defaults and the strict rules)");
            for (rules.all) |r| _ = try ws.text.format(" {s}", .{r.name});
            const hint = ws.text.buffer[start..ws.text.used];
            return ctx.fail(.usage, try ws.text.format("Unknown rule '{s}'.", .{code}), hint);
        }
    }
    if (set.len == 0) return ctx.fail(.usage, "--rules needs at least one rule.", "Pass a comma-separated list, such as --rules unbounded-loop,long-function, or --rules all.");
    if (set.len > std.mem.count(u8, list, ",") + 1 and std.mem.indexOf(u8, list, "all") == null and std.mem.indexOf(u8, list, "strict") == null) assert.panic("--rules '{s}' enabled {d} rules from {d} names; each name other than 'all' and 'strict' enables one rule, so check includeNamed()", .{ list, set.len, std.mem.count(u8, list, ",") + 1 });
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
    if (anchor) |a| try vocabulary.checkVocabulary(.{ .anchor = a, .text = ws.facts.text, .enabled = selected, .findings = &ws.findings }, &ws.facts, ws.files.items());
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

/// Says how much of --infer came from the store and how long the model took, so a slow run explains itself.
fn describeInference(ctx: *zcli.Context, ws: *Workspace, stats: infer.Stats) !void {
    if (stats.asked > stats.functions) assert.panic("--infer asked about {d} of {d} functions; askAll() must count only queued functions as asked", .{ stats.asked, stats.functions });
    if (stats.seconds < 0) assert.panic("--infer took {d} seconds; measure the time with the .awake clock, which never runs backwards", .{stats.seconds});
    if (ctx.quiet or stats.functions == 0) return;
    const line = try ws.text.format("zanity: --infer had questions about {d} {s}: {d} answered from the store, {d} asked of {s} in {d}m{d:0>2}s.", .{
        stats.functions,
        if (stats.functions == 1) "function" else "functions",
        stats.functions - stats.asked,
        stats.asked,
        (ws.inference orelse assert.panic("describing --infer with no model connected; connectInference() runs first", .{})).client.model,
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

/// Connects to the decision model for `--infer`, collecting the functions it will ask about and, unless
/// `--rules` chose otherwise, turning on the rules only inference can decide.
fn connectInference(ctx: *zcli.Context, ws: *Workspace, selected: *rules.Set, add_inferred: bool) !void {
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
    const spliced = try edits.applyEdits(source, findings, ws.fixed);
    try replaceFile(ctx, ws, .{ .path = path, .read = source, .fixed = spliced.bytes });
    edits.shiftLines(source, findings);
    const applied = spliced.applied;
    if (applied == 0) assert.panic("expected at least one edit to apply to {s}, got none; fixFiles() must call fixFile() only for a file with an edit", .{path});
    return applied;
}

/// A file to fix: its path, the bytes the fixes were made against, and the fixed bytes.
const Replacement = struct { path: []const u8, read: []const u8, fixed: []const u8 };

/// Writes the fixed file by atomic rename after one last content check. A non-cooperating writer
/// can still race that final rename; ordinary filesystems offer no compare-and-swap replacement.
fn replaceFile(ctx: *zcli.Context, ws: *Workspace, r: Replacement) !void { // zanity: ignore[check-then-act]
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
    try ws.dirs.add(try ws.text.copy(root));
    var walker = try dir.walkSelectively(std.heap.page_allocator);
    defer walker.deinit();
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (0..ws.limits.files * 2) |_| {
        const entry = try walker.next(ws.io) orelse break;
        const absolute = std.fmt.bufPrint(&absolute_buffer, "{s}/{s}", .{ root, entry.path }) catch continue;
        switch (entry.kind) {
            .directory => if (!project.skippedDir(entry.basename) and !ws.ignore.ignored(absolute, .directory)) {
                try ws.ignore.loadFile(ws.io, absolute, ".gitignore");
                try ws.dirs.add(try ws.text.copy(absolute));
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
