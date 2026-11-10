//! `zanity check --watch`: runs the check, then reruns it in a fresh process each time a file it
//! reads changes, and renders each run.
const baseline = @import("baseline.zig");
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const zclig = @import("zclig");
const rules = @import("rules.zig");
const report = @import("report.zig");
const memory = @import("memory.zig");
const Live = @import("live.zig").Live;
const watch = @import("watch.zig");
const workspace_init = @import("workspace_init.zig");
const CheckOptions = triage.CheckOptions;
const triage = @import("triage.zig");
const Row = baseline.Row;
const cmd_check = @import("cmd_check.zig");
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const console = workspace.console;
const loadSettings = cmd_check.loadSettings;
const parseRules = cmd_check.parseRules;
const checkPaths = cmd_check.checkPaths;
const collect = cmd_check.collect;

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
fn initRerun(rerun: *Rerun, ctx: *zclig.Context, ws: *Workspace) !void {
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
fn spawnedWatchCheck(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions) ![]const Row {
    const paths = options.paths;
    if (paths.len == 0) assert.panic("watching no paths; zclig supplies '.' when none are given", .{});
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
pub fn watchCheck(ctx: *zclig.Context, ws: *Workspace, options: CheckOptions, asked_for_agent: bool) ![]const Row {
    const paths = options.paths;
    if (options.infer or options.fix) return spawnedWatchCheck(ctx, ws, options);
    if (paths.len == 0) assert.panic("watching no paths; zclig supplies '.' when none are given", .{});
    if (paths.len > ws.args.len) assert.panic("watching {d} paths from a command line of {d} arguments; each path is an argument", .{ paths.len, ws.args.len });
    var watcher: watch.Watcher = undefined;
    var filter: watch.ChangeFilter = undefined;
    var roots: [max_watch_args][]const u8 = undefined;
    var trees: [max_watch_args][]const u8 = undefined;
    try startWatching(ctx, ws, paths, .{ .watcher = &watcher, .filter = &filter, .roots = roots[0..paths.len], .trees = trees[0..paths.len] });
    const checks = try workspace_init.initWorkspace(Workspace, std.heap.page_allocator, ws.io, ws.limits);
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
        var selected = if (options.rules) |list| try parseRules(ctx, checks, list) else settings.selection(options.production);
        if (options.rules != null and options.production) selected.includeTier(.production);
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

fn renderWatched(ctx: *zclig.Context, ws: *Workspace, output: WatchOutput) !void {
    const options = output.options;
    const counts = output.counts;
    if (options.paths.len == 0) assert.panic("rendering a watched check with no paths; zclig supplies '.' when none are given", .{});
    if (!triage.special(options) and ws.rows.len != counts.errors + counts.warnings) assert.panic("rendering {d} watched rows for {d} errors and {d} warnings; checkPaths makes one row per finding", .{ ws.rows.len, counts.errors, counts.warnings });
    if (triage.special(options)) {
        try triage.renderOutput(ctx, ws, options, output.agent);
        return;
    }
    const out = ctx.runtime.out;
    const err = ctx.runtime.err;
    if (output.agent) {
        try report.renderAgent(out.writer, .{ .findings = ws.findings.items(), .counts = counts, .paths = options.paths, .limit = options.limit, .watching = true, .all = options.all });
        try triage.continuation(out.writer, ws.args, 0, 10000);
        if (ws.cache_hits > 0) try err.writer.print("zanity: reused cached deterministic analysis for {d} of {d} source files; query {s}'s source_analyses table for the cached facts and findings.\n", .{ ws.cache_hits, ws.checked, ws.source_cache.?.path });
        return;
    }
    if (ctx.format == .human) {
        try report.render(.{ .console = console(ctx, out), .scratch = &ws.table, .text = &ws.text }, ws.findings.items());
        try report.summarise(console(ctx, err), counts);
        return;
    }
    try watch.renderRows(Row, out.writer, ctx.format == .json, ws.rows.items());
    try out.writer.flush();
    try report.summarise(console(ctx, err), counts);
}

/// Where startWatching() puts the watcher and the absolute paths it watches.
const WatchSlots = struct { watcher: *watch.Watcher, filter: *watch.ChangeFilter, roots: [][]const u8, trees: [][]const u8 };

/// Walks `paths` once, to load the ignore files and find every directory, then starts the
/// operating system's watch on them.
fn startWatching(ctx: *zclig.Context, ws: *Workspace, paths: []const []const u8, slots: WatchSlots) !void {
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
