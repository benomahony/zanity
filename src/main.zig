const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zcli = @import("zcli");
const zrich = @import("zrich");
const adapters = @import("adapters");
const language = @import("language.zig");
const check = @import("check.zig");
const rules = @import("rules.zig");
const report = @import("report.zig");
const naming = @import("naming.zig");
const graph = @import("graph.zig");
const memory = @import("memory.zig");
const Facts = @import("facts.zig").Facts;
const Finding = @import("facts.zig").Finding;

const skipped_dirs = [_][]const u8{ "node_modules", "zig-out", "__pycache__", "target", "dist", "build", "venv" };

const CheckOptions = struct {
    paths: []const []const u8,
    rules: ?[]const u8 = null,
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
    .version = "0.0.0",
    .description = "Fast, deterministic sanity checks for code written by people and agents.",
    .commands = &.{zcli.command(CheckOptions, Row, .{
        .name = "check",
        .description = "Check files and directories. Exits 1 when an error-level rule fires.",
        .examples = &.{ "zanity check .", "zanity check src tests --rules unbounded-loop,long-function", "zanity check . --json" },
        .result_title = "Findings",
        .positional = .{ .name = "paths", .metavar = "PATH", .help = "Files or directories to check.", .default = &.{"."} },
        .options = &.{.{ .name = "rules", .metavar = "RULES", .help = "Comma-separated rules to run instead of the defaults.", .example = "unbounded-loop,long-function" }},
    }, .{ .run = runCheck, .human = renderHuman })},
};

/// Everything a run needs, allocated once at startup and reused for every file.
const Workspace = struct {
    limits: memory.Limits,
    text: memory.Text,
    facts: Facts,
    check: check.FileScratch,
    naming: naming.ConceptScratch,
    graph: graph.CycleScratch,
    findings: memory.Bounded(Finding),
    files: memory.Bounded([]const u8),
    rows: memory.Bounded(Row),
    table: report.TableScratch,
    source: []u8,
    checkers: [adapters.all.len]?check.Checker = @splat(null),
    checked: usize = 0,
    io: Io = undefined,

    fn initWorkspace(gpa: Allocator, limits: memory.Limits) Allocator.Error!*Workspace {
        assert(limits.files > 0);
        assert(limits.file_bytes > 0);
        const ws = try gpa.create(Workspace);
        ws.* = .{
            .limits = limits,
            .text = try .initText(gpa, limits.text_bytes),
            .facts = undefined,
            .check = try .initCheckScratch(gpa, limits),
            .naming = try .initNamingScratch(gpa, limits),
            .graph = try .initGraphScratch(gpa, limits),
            .findings = try .initBounded(gpa, limits.findings, "findings across all files"),
            .files = try .initBounded(gpa, limits.files, "files"),
            .rows = try .initBounded(gpa, limits.findings, "findings across all files"),
            .table = try .initTableScratch(gpa, limits.files),
            .source = try gpa.alloc(u8, limits.file_bytes + 1),
        };
        ws.facts = try .initFacts(gpa, limits, &ws.text);
        return ws;
    }

    /// Compiles the queries of each language the run will check, and only those.
    fn initCheckers(ws: *Workspace, gpa: Allocator, selected: rules.Set) !void {
        assert(selected.len > 0);
        for (ws.files.items()) |path| {
            const adapter = language.forPath(path) orelse continue;
            const slot = &ws.checkers[adapterIndex(adapter)];
            if (slot.* == null) slot.* = try check.Checker.initChecker(gpa, try language.load(adapter), selected);
        }
        assert(ws.checkers.len == adapters.all.len);
    }
};

fn adapterIndex(adapter: *const language.Adapter) usize {
    const index = (@intFromPtr(adapter) - @intFromPtr(adapters.all.ptr)) / @sizeOf(language.Adapter);
    assert(index < adapters.all.len);
    assert(&adapters.all[index] == adapter);
    return index;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len >= 1);
    var out_buffer: [64 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buffer);
    var err_buffer: [4096]u8 = undefined;
    var err_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buffer);
    const ws = try Workspace.initWorkspace(std.heap.page_allocator, .{});
    ws.io = init.io;
    var runtime = zcli.native.runtime(init, &out_writer.interface, &err_writer.interface);
    runtime.user_data = ws;
    const code = app.run(init.gpa, args[1..], runtime);
    assert(@intFromEnum(code) <= 130);
    return @intFromEnum(code);
}

fn workspaceOf(ctx: *zcli.Context) *Workspace {
    const ws: *Workspace = @ptrCast(@alignCast(ctx.runtime.user_data orelse unreachable));
    assert(ws.limits.files > 0);
    assert(ws.files.buffer.len == ws.limits.files);
    return ws;
}

fn runCheck(ctx: *zcli.Context, options: CheckOptions) ![]const Row {
    assert(options.paths.len > 0);
    const ws = workspaceOf(ctx);
    const selected = if (options.rules) |list| try parseRules(ctx, ws, list) else rules.Set.defaults();
    const counts = checkPaths(ctx, ws, options.paths, selected) catch |e| switch (e) {
        error.LimitExceeded => return ctx.fail(.usage, try ws.text.format("This run has more {s} than zanity is built to hold.", .{memory.exceeded}), "Check fewer files at once, or report it if the input is ordinary."),
        else => return e,
    };
    if (counts.errors > 0) ctx.status = .failure;
    if (ctx.format != .human) try report.summarise(console(ctx, ctx.runtime.err), counts);
    assert(ws.rows.len == counts.errors + counts.warnings);
    return ws.rows.items();
}

/// The file-oriented terminal layout; `--plain` and `--json` stay zcli's record formats.
fn renderHuman(ctx: *zcli.Context, rows: []const Row) !void {
    const ws = workspaceOf(ctx);
    const findings = ws.findings.items();
    assert(rows.len == findings.len);
    try report.render(.{ .console = console(ctx, ctx.runtime.out), .scratch = &ws.table, .text = &ws.text }, findings);
    try report.summarise(console(ctx, ctx.runtime.err), report.count(findings, ws.checked));
    assert(ws.checked <= ws.files.len);
}

fn console(ctx: *zcli.Context, stream: zcli.Stream) zrich.Console {
    assert(stream.capabilities.width > 0);
    assert(stream.capabilities.width <= 4096);
    return .{ .writer = stream.writer, .allocator = ctx.allocator, .options = stream.capabilities };
}

fn parseRules(ctx: *zcli.Context, ws: *Workspace, list: []const u8) !rules.Set {
    var set: rules.Set = .{};
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |raw| {
        const code = std.mem.trim(u8, raw, " ");
        const rule = rules.find(code) orelse {
            const start = ws.text.used;
            _ = try ws.text.copy("The rules are:");
            for (rules.all) |r| _ = try ws.text.format(" {s}", .{r.name});
            const hint = ws.text.buffer[start..ws.text.used];
            return ctx.fail(.usage, try ws.text.format("Unknown rule '{s}'.", .{code}), hint);
        };
        set.include(rule.name);
    }
    if (set.len == 0) return ctx.fail(.usage, "--rules needs at least one rule.", "Pass a comma-separated list, such as --rules unbounded-loop,long-function.");
    assert(set.len <= std.mem.count(u8, list, ",") + 1);
    assert(rules.find(set.names()[0]) != null);
    return set;
}

fn checkPaths(ctx: *zcli.Context, ws: *Workspace, paths: []const []const u8, selected: rules.Set) !report.Counts {
    assert(paths.len > 0);
    assert(selected.len > 0);
    for (paths) |path| try collect(ctx, ws, path);
    std.mem.sort([]const u8, ws.files.items(), {}, pathOrder);
    try ws.initCheckers(std.heap.page_allocator, selected);
    try checkFiles(ctx, ws, selected);
    const findings = ws.findings.items();
    report.sortFindings(findings);
    ws.rows.clear();
    for (findings) |f| {
        const rule = rules.find(f.rule) orelse unreachable;
        try ws.rows.add(.{ .path = f.path, .line = f.line + 1, .column = f.column + 1, .severity = @tagName(rule.severity), .rule = rule.name, .message = f.message, .fix = f.advice() });
    }
    return report.count(findings, ws.checked);
}

fn checkFiles(ctx: *zcli.Context, ws: *Workspace, selected: rules.Set) !void {
    assert(selected.len > 0);
    assert(ws.findings.len == 0);
    const work: check.Work = .{ .scratch = &ws.check, .text = &ws.text, .facts = &ws.facts };
    for (ws.files.items()) |path| {
        const adapter = language.forPath(path) orelse continue;
        const checker = &(ws.checkers[adapterIndex(adapter)] orelse unreachable);
        ws.checked += 1;
        const source = Io.Dir.cwd().readFile(ws.io, path, ws.source) catch |e| {
            return ctx.fail(.io, try ws.text.format("Could not read {s}: {t}.", .{ path, e }), "Check the file exists and is readable.");
        };
        if (source.len > ws.limits.file_bytes) {
            memory.exceeded = "bytes in one file";
            return error.LimitExceeded;
        }
        ws.facts.path = path;
        ws.facts.language = adapter.name;
        const result = try checker.check(work, source);
        for (result.diagnostics) |d| {
            try ws.findings.add(.{ .path = path, .line = d.line, .column = d.column, .rule = d.rule, .message = d.message, .fix = d.fix });
        }
    }
    try naming.crossCheck(&ws.naming, &ws.facts, selected, &ws.findings);
    if (selected.enabled("recursion")) try graph.recursion(&ws.graph, &ws.facts, &ws.findings);
    assert(ws.checked <= ws.files.len);
}

fn collect(ctx: *zcli.Context, ws: *Workspace, path: []const u8) !void {
    assert(path.len > 0);
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
    var walker = try dir.walkSelectively(ctx.allocator);
    defer walker.deinit();
    for (0..ws.limits.files * 2) |_| {
        const entry = try walker.next(ws.io) orelse break;
        switch (entry.kind) {
            .directory => if (!skipped(entry.basename)) try walker.enter(ws.io, entry),
            .file => if (language.forPath(entry.basename) != null) {
                const joined = if (std.mem.eql(u8, path, "."))
                    try ws.text.copy(entry.path)
                else
                    try ws.text.format("{s}{s}{s}", .{ path, if (std.mem.endsWith(u8, path, "/")) "" else "/", entry.path });
                try ws.files.add(joined);
            },
            else => {},
        }
    } else {
        memory.exceeded = "directory entries";
        return error.LimitExceeded;
    }
    assert(ws.files.len >= before);
}

fn pathOrder(_: void, a: []const u8, b: []const u8) bool {
    assert(a.len > 0);
    assert(b.len > 0);
    return std.mem.order(u8, a, b) == .lt;
}

fn skipped(name: []const u8) bool {
    assert(name.len > 0);
    assert(std.mem.indexOfScalar(u8, name, '/') == null);
    if (name[0] == '.') return true;
    for (skipped_dirs) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}
