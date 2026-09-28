const std = @import("std");
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
const Ignore = @import("ignore.zig").Ignore;
const infer = @import("infer.zig");
const store = @import("store.zig");
const Facts = @import("facts.zig").Facts;
const Finding = @import("facts.zig").Finding;

const skipped_dirs = [_][]const u8{ "node_modules", "zig-out", "__pycache__", "target", "dist", "build", "venv" };

const CheckOptions = struct {
    paths: []const []const u8,
    rules: ?[]const u8 = null,
    fix: bool = false,
    infer: bool = false,
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
        .examples = &.{ "zanity check .", "zanity check src tests --rules unbounded-loop,long-function", "zanity check . --json", "zanity check . --fix" },
        .result_title = "Findings",
        .positional = .{ .name = "paths", .metavar = "PATH", .help = "Files or directories to check.", .default = &.{"."} },
        .options = &.{
            .{ .name = "rules", .metavar = "RULES", .help = "Comma-separated rules to run instead of the defaults.", .example = "unbounded-loop,long-function" },
            .{ .name = "fix", .help = "Apply the fixes zanity can make, then report what is left." },
            .{ .name = "infer", .help = "Also ask TypeSafe what no deterministic check can decide, such as whether an error message misleads. Needs TYPESAFE_API_KEY." },
        },
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
    fixed: []u8,
    ignore: Ignore,
    environ: ?*const std.process.Environ.Map = null,
    inference: ?infer.Inference = null,
    checkers: [adapters.all.len]?check.Checker = @splat(null),
    checked: usize = 0,
    io: Io = undefined,

    fn initWorkspace(gpa: Allocator, limits: memory.Limits) Allocator.Error!*Workspace {
        if (limits.files == 0) std.debug.panic("memory.Limits.files is 0, so zanity could not check any file", .{});
        if (limits.file_bytes == 0) std.debug.panic("memory.Limits.file_bytes is 0, so zanity could not read any file", .{});
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
            .fixed = try gpa.alloc(u8, 2 * limits.file_bytes),
            .ignore = try .initIgnore(gpa, limits),
        };
        ws.facts = try .initFacts(gpa, limits, &ws.text);
        return ws;
    }

    /// Compiles the queries of each language the run will check, and only those.
    fn initCheckers(ws: *Workspace, gpa: Allocator, selected: rules.Set) !void {
        if (selected.len == 0) std.debug.panic("compiling checkers with no rules selected; runCheck always selects at least one", .{});
        for (ws.files.items()) |path| {
            const adapter = language.forPath(path) orelse continue;
            const slot = &ws.checkers[adapterIndex(adapter)];
            if (slot.* == null) slot.* = try check.Checker.initChecker(gpa, try language.load(adapter), selected);
        }
        if (ws.checkers.len != adapters.all.len) std.debug.panic("{d} checker slots for {d} languages", .{ ws.checkers.len, adapters.all.len });
    }
};

fn adapterIndex(adapter: *const language.Adapter) usize {
    const index = (@intFromPtr(adapter) - @intFromPtr(adapters.all.ptr)) / @sizeOf(language.Adapter);
    if (index >= adapters.all.len) std.debug.panic("adapter {s} is at index {d}, past the {d} languages; it is not from adapters.all", .{ adapter.name, index, adapters.all.len });
    if (&adapters.all[index] != adapter) std.debug.panic("adapter {s} is not adapters.all[{d}] ({s}); pass a pointer into adapters.all", .{ adapter.name, index, adapters.all[index].name });
    return index;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 0) std.debug.panic("the process has no arguments, not even its own name", .{});
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
    if (@intFromEnum(code) > 130) std.debug.panic("zcli returned exit code {d}; codes above 130 collide with signals", .{@intFromEnum(code)});
    return @intFromEnum(code);
}

fn workspaceOf(ctx: *zcli.Context) *Workspace {
    const ws: *Workspace = @ptrCast(@alignCast(ctx.runtime.user_data orelse unreachable));
    if (ws.limits.files == 0) std.debug.panic("the workspace allows 0 files; it was not built by initWorkspace", .{});
    if (ws.files.buffer.len != ws.limits.files) std.debug.panic("the workspace has room for {d} files but its limit is {d}; it was not built by initWorkspace", .{ ws.files.buffer.len, ws.limits.files });
    return ws;
}

fn runCheck(ctx: *zcli.Context, options: CheckOptions) ![]const Row {
    if (options.paths.len == 0) std.debug.panic("check ran with no paths; zcli supplies '.' when none are given", .{});
    const ws = workspaceOf(ctx);
    var selected = if (options.rules) |list| try parseRules(ctx, ws, list) else rules.Set.defaults();
    if (options.infer) try connectInference(ctx, ws, &selected, options.rules == null);
    const counts = checkPaths(ctx, ws, options, selected) catch |e| switch (e) {
        error.LimitExceeded => return ctx.fail(.usage, try ws.text.format("This run has more {s} than zanity is built to hold.", .{memory.exceeded}), "Check fewer files at once, or report it if the input is ordinary."),
        else => return e,
    };
    if (counts.errors > 0) ctx.status = .failure;
    if (ctx.format != .human) try report.summarise(console(ctx, ctx.runtime.err), counts);
    if (ws.rows.len != counts.errors + counts.warnings) std.debug.panic("{d} output rows for {d} errors and {d} warnings", .{ ws.rows.len, counts.errors, counts.warnings });
    return ws.rows.items();
}

/// The file-oriented terminal layout; `--plain` and `--json` stay zcli's record formats.
fn renderHuman(ctx: *zcli.Context, rows: []const Row) !void {
    const ws = workspaceOf(ctx);
    const findings = ws.findings.items();
    if (rows.len != findings.len) std.debug.panic("rendering {d} rows for {d} findings; rows are built one per finding", .{ rows.len, findings.len });
    try report.render(.{ .console = console(ctx, ctx.runtime.out), .scratch = &ws.table, .text = &ws.text }, findings);
    try report.summarise(console(ctx, ctx.runtime.err), report.count(findings, ws.checked));
    if (ws.checked > ws.files.len) std.debug.panic("checked {d} files out of {d} collected", .{ ws.checked, ws.files.len });
}

fn console(ctx: *zcli.Context, stream: zcli.Stream) zrich.Console {
    if (stream.capabilities.width == 0) std.debug.panic("the output stream reports width 0; zcli must supply a terminal width", .{});
    if (stream.capabilities.width > 4096) std.debug.panic("the output stream reports width {d}; wider than 4096 columns is not a terminal", .{stream.capabilities.width});
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
    if (set.len > std.mem.count(u8, list, ",") + 1) std.debug.panic("--rules '{s}' enabled {d} rules from {d} names", .{ list, set.len, std.mem.count(u8, list, ",") + 1 });
    if (rules.find(set.names()[0]) == null) std.debug.panic("--rules '{s}' enabled '{s}', which is not a rule", .{ list, set.names()[0] });
    return set;
}

fn checkPaths(ctx: *zcli.Context, ws: *Workspace, options: CheckOptions, selected: rules.Set) !report.Counts {
    const paths = options.paths;
    if (paths.len == 0) std.debug.panic("check ran with no paths; zcli supplies '.' when none are given", .{});
    if (selected.len == 0) std.debug.panic("check ran with no rules selected; runCheck always selects at least one", .{});
    for (paths) |path| try collect(ctx, ws, path);
    std.mem.sort([]const u8, ws.files.items(), {}, pathOrder);
    try ws.initCheckers(std.heap.page_allocator, selected);
    try checkFiles(ctx, ws, selected);
    if (ws.inference) |*inference| inference.judge(ws.facts.units.items(), &ws.findings, selected) catch |e| switch (e) {
        error.AskFailed => return ctx.fail(.io, infer.failure, "Check TYPESAFE_API_KEY and TYPESAFE_BASE_URL, then run again; answers already received are cached."),
        error.StoreUnavailable => return ctx.fail(.io, try storeProblem(ws), "Check that the cache directory is writable and not full, then run again."),
        else => return e,
    };
    report.sortFindings(ws.findings.items());
    if (options.fix) try fixFiles(ctx, ws);
    const findings = ws.findings.items();
    ws.rows.clear();
    for (findings) |f| {
        const rule = rules.find(f.rule) orelse unreachable;
        try ws.rows.add(.{ .path = f.path, .line = f.line + 1, .column = f.column + 1, .severity = @tagName(rule.severity), .rule = rule.name, .message = f.message, .fix = f.advice() });
    }
    return report.count(findings, ws.checked);
}

fn checkFiles(ctx: *zcli.Context, ws: *Workspace, selected: rules.Set) !void {
    if (selected.len == 0) std.debug.panic("checking files with no rules selected; runCheck always selects at least one", .{});
    if (ws.findings.len != 0) std.debug.panic("{d} findings are left from an earlier run; checkFiles expects a fresh workspace", .{ws.findings.len});
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
            try ws.findings.add(.{ .path = path, .line = d.line, .column = d.column, .rule = d.rule, .message = d.message, .fix = d.fix, .edit = d.edit });
        }
    }
    try naming.crossCheck(&ws.naming, &ws.facts, selected, &ws.findings);
    if (selected.enabled("recursion")) try graph.recursion(&ws.graph, &ws.facts, &ws.findings);
    if (ws.checked > ws.files.len) std.debug.panic("checked {d} files out of {d} collected", .{ ws.checked, ws.files.len });
}

/// Says why the answer store could not be used, in SQLite's words when it gave some.
fn storeProblem(ws: *Workspace) ![]const u8 {
    if (store.failure_len > store.failure.len) std.debug.panic("the store kept {d} bytes of failure message in room for {d}", .{ store.failure_len, store.failure.len });
    const reason = store.failure[0..store.failure_len];
    const text = try ws.text.format("--infer could not use its answer store{s}{s}.", .{ if (reason.len > 0) ": " else "", reason });
    if (text.len == 0) std.debug.panic("describing a store failure produced no text", .{});
    return text;
}

/// Connects to TypeSafe for `--infer`, collecting the functions it will ask about and, unless
/// `--rules` chose otherwise, turning on the rules only inference can decide.
fn connectInference(ctx: *zcli.Context, ws: *Workspace, selected: *rules.Set, add_inferred: bool) !void {
    if (ws.inference != null) std.debug.panic("connecting to TypeSafe a second time; runCheck connects once per run", .{});
    const environ = ws.environ orelse std.debug.panic("--infer needs the process environment, but main did not store it in the workspace", .{});
    ws.inference = infer.Inference.initInference(std.heap.page_allocator, ws.io, environ, ws.limits) catch |e| switch (e) {
        error.MissingApiKey => return ctx.fail(.usage, "--infer asks TypeSafe to judge error messages, and needs an API key in TYPESAFE_API_KEY.", "Set TYPESAFE_API_KEY, or run without --infer to use only the deterministic checks."),
        error.StoreUnavailable => return ctx.fail(.io, try storeProblem(ws), "Check that the cache directory is writable, or set ZANITY_STORE to a file zanity can create."),
        else => return e,
    };
    ws.facts.collect_units = true;
    if (add_inferred) for (rules.all) |r| if (r.question.len > 0) selected.include(r.name);
    if (selected.len == 0) std.debug.panic("--infer left no rules selected", .{});
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
    if (files > fixed) std.debug.panic("expected every fixed file to have a fixed finding, got {d} files and {d} findings", .{ files, fixed });
    var kept: usize = 0;
    for (findings) |f| {
        if (f.fixed) continue;
        findings[kept] = f;
        kept += 1;
    }
    ws.findings.len = kept;
    if (kept + fixed != findings.len) std.debug.panic("--fix lost track of findings: {d} fixed and {d} kept out of {d}; a finding was marked fixed without its edit being applied", .{ fixed, kept, findings.len });
    if (fixed > 0) {
        const line = try ws.text.format("zanity: fixed {d} {s} in {d} {s}", .{ fixed, if (fixed == 1) "finding" else "findings", files, if (files == 1) "file" else "files" });
        const err = console(ctx, ctx.runtime.err);
        try err.styled(line, .{ .fg = .{ .named = .green } });
        try err.writer.writeByte('\n');
    }
}

/// Applies the non-overlapping edits of one file's findings, which are in source order.
/// An edit that overlaps an earlier one waits for the next run.
fn fixFile(ctx: *zcli.Context, ws: *Workspace, findings: []Finding) !usize {
    const path = findings[0].path;
    if (!std.mem.eql(u8, path, findings[findings.len - 1].path)) std.debug.panic("expected the findings of one file, got {s} and {s}", .{ path, findings[findings.len - 1].path });
    var any = false;
    for (findings) |f| any = any or f.edit != null;
    if (!any) return 0;
    const source = Io.Dir.cwd().readFile(ws.io, path, ws.source) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not read {s} to fix it: {t}.", .{ path, e }), "Check the file is still there and readable.");
    };
    var out: usize = 0;
    var cursor: usize = 0;
    var applied: usize = 0;
    for (findings) |*f| {
        const edit = f.edit orelse continue;
        if (edit.start < cursor or edit.end > source.len) continue;
        const kept = source[cursor..edit.start];
        if (out + kept.len + edit.replacement.len > ws.fixed.len) break;
        @memcpy(ws.fixed[out..][0..kept.len], kept);
        @memcpy(ws.fixed[out + kept.len ..][0..edit.replacement.len], edit.replacement);
        out += kept.len + edit.replacement.len;
        cursor = edit.end;
        f.fixed = true;
        applied += 1;
    }
    const rest = source[cursor..];
    if (out + rest.len > ws.fixed.len) {
        memory.exceeded = "bytes in one fixed file";
        return error.LimitExceeded;
    }
    @memcpy(ws.fixed[out..][0..rest.len], rest);
    out += rest.len;
    try replaceFile(ctx, ws, path, ws.fixed[0..out]);
    shiftLines(source, findings);
    if (applied == 0) std.debug.panic("expected at least one edit to apply to {s}, got none", .{path});
    return applied;
}

fn replaceFile(ctx: *zcli.Context, ws: *Workspace, path: []const u8, bytes: []const u8) !void {
    if (!(path.len > 0 and bytes.len <= ws.fixed.len)) std.debug.panic("expected a path and at most {d} bytes, got '{s}' and {d} bytes", .{ ws.fixed.len, path, bytes.len });
    const cwd = Io.Dir.cwd();
    const permissions = (cwd.statFile(ws.io, path, .{}) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not stat {s} to fix it: {t}.", .{ path, e }), "Check the file is still there and readable.");
    }).permissions;
    var atomic = cwd.createFileAtomic(ws.io, path, .{ .permissions = permissions, .replace = true }) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not write the fixed {s}: {t}.", .{ path, e }), "Check the directory is writable.");
    };
    defer atomic.deinit(ws.io);
    try atomic.file.writeStreamingAll(ws.io, bytes);
    try atomic.replace(ws.io);
    if (bytes.len == 0) std.debug.panic("expected a fixed file with content, got an empty {s}", .{path});
}

/// Moves the findings that stay in a fixed file past the lines its edits added or removed.
fn shiftLines(source: []const u8, findings: []Finding) void {
    if (!(findings.len > 0)) std.debug.panic("expected findings to shift, got none for {d} bytes", .{source.len});
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
    if (delta < -@as(i64, @intCast(source.len))) std.debug.panic("expected edits to remove at most the file's {d} bytes of lines, got {d} lines", .{ source.len, delta });
}

/// Adds the checkable files under `path`, skipping what git ignores. A file named directly is always checked.
fn collect(ctx: *zcli.Context, ws: *Workspace, path: []const u8) !void {
    if (path.len == 0) std.debug.panic("asked to collect files from an empty path; zcli supplies '.' when none are given", .{});
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
            .file => if (language.forPath(entry.basename) != null and !ws.ignore.ignored(absolute, .file)) {
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
    if (ws.files.len < before) std.debug.panic("collecting {s} dropped files: {d} before, {d} after", .{ path, before, ws.files.len });
}

fn pathOrder(_: void, a: []const u8, b: []const u8) bool {
    if (a.len == 0) std.debug.panic("sorting an empty path against '{s}'", .{b});
    if (b.len == 0) std.debug.panic("sorting '{s}' against an empty path", .{a});
    return std.mem.order(u8, a, b) == .lt;
}

fn skipped(name: []const u8) bool {
    if (name.len == 0) std.debug.panic("asked whether a directory with an empty name is skipped", .{});
    if (std.mem.indexOfScalar(u8, name, '/') != null) std.debug.panic("'{s}' is a path, but skipped() takes one directory name", .{name});
    if (name[0] == '.') return true;
    for (skipped_dirs) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}
