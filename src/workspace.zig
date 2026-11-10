//! The state one zanity run works in, allocated once at startup and reused for every check,
//! and the console a command writes its report to.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zclig = @import("zclig");
const zrich = zclig.zrich;
const adapters = @import("adapters");
const language = @import("language.zig");
const check = @import("check.zig");
const batch = @import("batch.zig");
const rules = @import("rules.zig");
const report = @import("report.zig");
const naming = @import("naming.zig");
const graph = @import("graph.zig");
const structure = @import("structure.zig");
const memory = @import("memory.zig");
const Ignore = @import("ignore.zig").Ignore;
const infer = @import("infer.zig");
const store = @import("store.zig");
const Live = @import("live.zig").Live;
const config = @import("config.zig");
const Notice = @import("notice.zig").Notice;
const Facts = @import("facts.zig").Facts;
const Finding = @import("facts.zig").Finding;
const baseline = @import("baseline.zig");
const Row = baseline.Row;
const cmd_init = @import("cmd_init.zig");
const cmd_upgrade = @import("cmd_upgrade.zig");
const InitRow = cmd_init.InitRow;
const UpgradeRow = cmd_upgrade.UpgradeRow;

/// The widest terminal believed.
const max_console_width = 4096;

/// Everything a run needs, allocated once at startup and reused for every file.
pub const Workspace = struct {
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
    /// The edit of each use of a name `--fix` renames, kept apart from the findings it reports.
    renames: memory.Bounded(Finding),
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
    /// The notice after a check a person reads, when a newer release is out.
    notice: Notice = .{},
    cache_hits: usize = 0,
    checkers: [language.count]?check.Checker = @splat(null),
    checker_rules: rules.Set = .{},
    workers: [batch.max_workers]?*batch.Worker = @splat(null),
    worker_view: [batch.max_workers]*batch.Worker = undefined,
    checked: usize = 0,
    /// Checkable files under the walk that zanity.toml's `exclude` left out.
    skipped: usize = 0,
    io: Io,
    review: baseline.Review = .{},
    baseline_buffer: []u8,
    history: @import("history.zig").History,

    /// Compiles the queries of each language the run will check, and only those.
    pub fn initCheckers(ws: *Workspace, gpa: Allocator, selected: rules.Set) !void {
        if (selected.len == 0) assert.panic("compiling checkers with no rules selected; runCheck always selects at least one", .{});
        if (!ws.checker_rules.same(selected)) {
            for (&ws.checkers) |*slot| {
                if (slot.*) |*checker| checker.selectRules(selected);
            }
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
    pub fn checkWorkers(ws: *Workspace, gpa: Allocator, files: usize) ![]const *batch.Worker {
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
    pub fn resetCheck(ws: *Workspace) void {
        ws.text.used = 0;
        ws.facts.reset();
        ws.naming.reset();
        inline for (.{ "findings", "renames", "files", "project_files", "dirs", "rows" }) |field| @field(ws, field).clear();
        ws.ignore.reset();
        ws.settings = null;
        ws.live = null;
        ws.checked = 0;
        ws.skipped = 0;
        ws.cache_hits = 0;
        if (ws.files.len != 0 or ws.findings.len != 0 or ws.text.used != 0) assert.panic("reset workspace kept {d} files, {d} findings and {d} bytes; resetCheck() must empty the run", .{ ws.files.len, ws.findings.len, ws.text.used });
        if (ws.settings != null or ws.live != null) assert.panic("reset workspace kept settings={d} or progress={d}; both must be 0 between checks", .{ @intFromBool(ws.settings != null), @intFromBool(ws.live != null) });
    }
};

pub fn workspaceOf(ctx: *zclig.Context) *Workspace {
    const ws: *Workspace = @ptrCast(@alignCast(ctx.runtime.user_data orelse unreachable));
    if (ws.limits.files == 0) assert.panic("the workspace allows 0 files; it was not built by initWorkspace", .{});
    if (ws.files.capacity() != ws.limits.files) assert.panic("the workspace has room for {d} files but its limit is {d}; it was not built by initWorkspace", .{ ws.files.capacity(), ws.limits.files });
    return ws;
}

pub fn console(ctx: *zclig.Context, stream: zclig.Stream) zrich.Console {
    if (stream.capabilities.width == 0) assert.panic("the output stream reports width 0; zclig must supply a terminal width", .{});
    if (stream.capabilities.width > max_console_width) assert.panic("the output stream reports width {d}; wider than 4096 columns is not a terminal", .{stream.capabilities.width});
    return .{ .writer = stream.writer, .allocator = ctx.allocator, .options = stream.capabilities };
}
