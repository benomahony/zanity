//! `zanity check`: which rules and paths a run checks, the files it collects and checks in
//! parallel, the --infer and --fix steps, and its report for a person or an agent.
const std = @import("std");
const check_paths = @import("check_paths.zig");
const loadSettings = check_paths.loadSettings;
const parseRules = check_paths.parseRules;
const checkPaths = check_paths.checkPaths;
const storeProblem = check_paths.storeProblem;
const assert = @import("assert.zig");
const zclig = @import("zclig");
const rules = @import("rules.zig");
const report = @import("report.zig");
const report_agent = @import("report_agent.zig");
const memory = @import("memory.zig");
const infer = @import("infer.zig");
const Live = @import("live.zig").Live;
const config = @import("config.zig");
const watch = @import("watch.zig");
pub const collect = @import("collect.zig").collect;
const CheckOptions = triage.CheckOptions;
const triage = @import("triage.zig");
const baseline = @import("baseline.zig");
const Row = baseline.Row;
const cmd_watch = @import("cmd_watch.zig");
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const workspaceOf = workspace.workspaceOf;
const console = workspace.console;
const watchCheck = cmd_watch.watchCheck;
/// This build's version, as `zanity --version` prints it.
const build_version = @import("build_info").version;

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
    try report_agent.renderAgent(out.writer, .{ .findings = ws.findings.items(), .counts = counts, .paths = paths, .limit = options.limit, .watching = watching(ws), .all = options.all });
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
    try ws.notice.finish(ws.io, err.writer, build_version);
}

/// Starts the newer-release notice when a person reads the check at a terminal; agents, --json,
/// --plain, --quiet and pipes get none.
fn startNotice(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, agent: bool) void {
    if (agent and ws.chose_format) assert.panic("writing for an agent although the command line chose --json or --plain; speaksToAgent() must refuse that", .{});
    if (ws.chose_format and ctx.format == .human) assert.panic("the command line chose --json or --plain, but zclig formats for a person; zclig sets the format before running the command", .{});
    const environ = ws.environ orelse assert.panic("zanity check ran without the environment; main() passes it to the workspace", .{});
    const err = ctx.runtime.err;
    const person = !agent and !ws.chose_format and !triage.special(options) and ctx.format == .human and !ctx.quiet and err.capabilities.interactive;
    if (person) ws.notice.start(ws.io, environ, build_version);
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
