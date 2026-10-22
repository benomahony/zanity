const std = @import("std");
const assert = @import("assert.zig");
const Row = @import("baseline.zig").Row;

pub const CheckOptions = struct {
    paths: []const []const u8,
    rules: ?[]const u8 = null,
    fix: bool = false,
    infer: bool = false,
    strict: bool = false,
    watch: bool = false,
    @"fail-on": FailOn = .@"error",
    agent: bool = false,
    limit: u32 = 10,
    baseline: ?[]const u8 = null,
    @"capture-baseline": bool = false,
    @"update-baseline": bool = false,
    @"new-only": bool = false,
    triage: bool = false,
    file: ?[]const u8 = null,
    rule: ?[]const u8 = null,
    classification: ?[]const u8 = null,
    offset: u32 = 0,
    @"page-size": ?u32 = null,
};

/// The least severe finding that makes `check` exit 1.
pub const FailOn = enum { @"error", warning };

pub fn order(_: void, a: Row, b: Row) bool {
    if (a.id.len != 64) assert.panic("identity A has {d} bytes", .{a.id.len});
    if (b.id.len != 64) assert.panic("identity B has {d} bytes", .{b.id.len});
    for ([_][2][]const u8{ .{ a.rule, b.rule }, .{ a.path, b.path } }) |pair| {
        const by = std.mem.order(u8, pair[0], pair[1]);
        if (by != .eq) return by == .lt;
    }
    if (a.line != b.line) return a.line < b.line;
    if (a.column != b.column) return a.column < b.column;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

pub fn special(options: anytype) bool {
    if (options.paths.len == 0) assert.panic("report has {d} checked paths", .{options.paths.len});
    if (options.paths[0].len == 0) assert.panic("first checked path is empty", .{});
    return options.baseline != null or options.triage or options.file != null or options.rule != null or options.classification != null or options.@"page-size" != null or options.offset != 0;
}

pub fn validate(options: anytype) !void {
    if (options.paths.len == 0) assert.panic("validation requires checked paths", .{});
    if (options.paths[0].len == 0) assert.panic("first validated path is empty", .{});
    if (needsBaseline(options) and options.baseline == null) return error.BaselinePathRequired;
    if (options.@"capture-baseline" and options.@"update-baseline") return error.ConflictingBaselineActions;
    if (options.watch and (options.@"capture-baseline" or options.@"update-baseline")) return error.BaselineMutationCannotWatch;
    if (options.@"page-size") |size| if (size == 0 or size > 10000) return error.PageSizeMustBeBetween1And10000;
    if (options.classification) |status| {
        for ([_][]const u8{ "new", "existing", "resolved", "unclassified" }) |valid| if (std.mem.eql(u8, status, valid)) return;
        return error.InvalidClassification;
    }
}

fn matches(row: Row, options: anytype) bool {
    if (row.rule.len == 0) assert.panic("filter row has no rule", .{});
    if (row.path.len == 0) assert.panic("filter row has no path", .{});
    if (options.rule) |rule| if (!std.mem.eql(u8, row.rule, rule)) return false;
    if (options.file) |file| if (!std.mem.eql(u8, row.path, file)) return false;
    if (options.classification) |status| if (!std.mem.eql(u8, row.classification, status)) return false;
    return true;
}

pub fn selectRows(ws: anytype, options: anytype, resolved: []const Row) !void {
    if (ws.rows.len > ws.rows.capacity()) assert.panic("selection has {d} rows over capacity", .{ws.rows.len});
    if (resolved.len > ws.limits.findings) assert.panic("selection has {d} resolutions over capacity", .{resolved.len});
    if (!special(options)) return;
    for (resolved) |row| try ws.rows.add(row);
    std.mem.sort(Row, ws.rows.items(), {}, order);
    var kept: usize = 0;
    var matching: usize = 0;
    const size: usize = options.@"page-size" orelse if (options.triage) @as(u32, 20) else std.math.maxInt(u32);
    for (ws.rows.items()) |row| {
        if (!matches(row, options)) continue;
        if (matching >= options.offset and kept < size) {
            ws.rows.buffer[kept] = row;
            kept += 1;
        }
        matching += 1;
    }
    ws.rows.len = kept;
    ws.review.matching = matching;
    ws.review.next = if (@as(usize, options.offset) + kept < matching) @as(usize, options.offset) + kept else null;
    for (ws.rows.items()) |*row| {
        row.matching_total = matching;
        row.next_offset = ws.review.next;
    }
}

pub fn renderReview(ctx: anytype, ws: anytype, options: anytype, agent: bool) !void {
    if (ws.rows.len > ws.review.matching) assert.panic("display has {d} rows over matching total", .{ws.rows.len});
    if (options.paths.len == 0) assert.panic("display requires checked paths", .{});
    const output = ctx.runtime.out;
    const out = output.writer;
    const review = ws.review;
    if (options.baseline != null) try out.print("Baseline: {d} new, {d} existing (inherited backlog), {d} resolved.\n", .{ review.new, review.existing, review.resolved }) else try out.print("Current findings: {d} matching; no baseline comparison requested.\n", .{review.matching});
    const history = &ws.history;
    if (history.resolved.len > 0) try out.print("Resolved since previous check: {d} previously new findings.\n", .{history.resolved.len});
    if (agent) try out.writeAll(if (selectedBatch(options)) "Assignment: fix only current findings in this selected batch. Resolved findings require no work.\n" else "Assignment: fix new findings only. Inherited backlog is not a correction assignment.\n");
    const shown = try renderBatch(out, ws.rows.items(), options, agent);
    try out.print("Shown {d}; matching total {d}; omitted {d}.\n", .{ shown, review.matching, review.matching - shown });
    try continuation(out, ws.args, review.next orelse options.offset, options.@"page-size" orelse if (options.triage) @as(u32, 20) else @as(u32, 10000));
    if (options.watch) try out.writeAll("Saving checks again against the unchanged baseline.\n");
}

fn assigned(row: Row, options: anytype, agent: bool) bool {
    if (row.classification.len == 0) assert.panic("assignment requires classification", .{});
    if (row.id.len != 64) assert.panic("assignment ID has {d} bytes", .{row.id.len});
    if (!agent or options.baseline == null) return true;
    if (selectedBatch(options)) return true;
    return std.mem.eql(u8, row.classification, "new");
}

fn quote(out: *std.Io.Writer, arg: []const u8) !void {
    if (arg.len == 0) assert.panic("cannot quote an empty checked argument", .{});
    if (arg.len > 1 << 20) assert.panic("quoted argument has {d} bytes", .{arg.len});
    try out.writeByte('\'');
    for (arg) |c| if (c == '\'') try out.writeAll("'\\''") else try out.writeByte(c);
    try out.writeByte('\'');
}

pub fn continuation(out: *std.Io.Writer, args: []const []const u8, offset: usize, size: u32) !void {
    if (args.len == 0) assert.panic("continuation has no original arguments", .{});
    if (size == 0) assert.panic("continuation page size must be positive", .{});
    try out.writeAll("Inspect/export: ");
    try writeCommand(out, args, offset, size);
    try out.writeByte('\n');
}

fn writeCommand(out: *std.Io.Writer, args: []const []const u8, offset: usize, size: u32) !void {
    if (args.len == 0) assert.panic("command needs original arguments", .{});
    if (size == 0) assert.panic("command page size must be positive", .{});
    try out.writeAll("zanity");
    var skip = false;
    for (args) |arg| {
        if (skip) {
            skip = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--offset") or std.mem.eql(u8, arg, "--page-size") or std.mem.eql(u8, arg, "--limit")) {
            skip = true;
            continue;
        }
        if (omitArgument(arg)) continue;
        try out.writeByte(' ');
        try quote(out, arg);
    }
    try out.print(" --json --offset {d} --page-size {d}", .{ offset, size });
}

fn renderBatch(out: *std.Io.Writer, rows: []const Row, options: anytype, agent: bool) !usize {
    if (options.paths.len == 0) assert.panic("batch requires checked paths", .{});
    var shown: usize = 0;
    var last_rule: []const u8 = "";
    var last_path: []const u8 = "";
    for (rows) |row| {
        if (!assigned(row, options, agent)) continue;
        if (agent and !selectedBatch(options) and options.limit > 0 and shown >= options.limit) continue;
        if (!std.mem.eql(u8, row.rule, last_rule) or !std.mem.eql(u8, row.path, last_path)) try out.print("\n{s} / {s}\n", .{ row.rule, row.path });
        last_rule = row.rule;
        last_path = row.path;
        try out.print("{s}:{d}:{d} [{s}] {s} {s}\n  {s}\n  Fix: {s}\n", .{ row.path, row.line, row.column, row.severity, row.classification, row.id, row.message, row.fix });
        shown += 1;
    }
    if (shown > rows.len) assert.panic("showed {d} findings among {d}", .{ shown, rows.len });
    return shown;
}

fn omitArgument(arg: []const u8) bool {
    if (arg.len == 0) assert.panic("command argument is empty", .{});
    if (arg.len > 1 << 20) assert.panic("command argument has {d} bytes", .{arg.len});
    for ([_][]const u8{ "--offset=", "--page-size=", "--limit=", "--watch=", "--agent=", "--capture-baseline=", "--update-baseline=", "--fix=" }) |prefix| if (std.mem.startsWith(u8, arg, prefix)) return true;
    for ([_][]const u8{ "--agent", "--watch", "--capture-baseline", "--update-baseline", "--fix", "--json", "--plain" }) |flag| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

fn needsBaseline(options: anytype) bool {
    if (options.paths.len == 0) assert.panic("baseline options require checked paths", .{});
    if (options.paths[0].len == 0) assert.panic("first checked path is empty", .{});
    return options.@"capture-baseline" or options.@"update-baseline" or options.@"new-only";
}

fn selectedBatch(options: anytype) bool {
    if (options.paths.len == 0) assert.panic("batch options require checked paths", .{});
    if (options.paths[0].len == 0) assert.panic("first batch path is empty", .{});
    return options.triage or options.rule != null or options.file != null or options.classification != null or options.@"page-size" != null or options.offset > 0;
}

pub fn failsReview(options: anytype, counts: @import("report.zig").Counts, review: @import("baseline.zig").Review) bool {
    if (counts.errors + counts.warnings < review.new) assert.panic("{d} new findings exceeds {d} current findings", .{ review.new, counts.errors + counts.warnings });
    if (review.new_counts.errors + review.new_counts.warnings > review.new) assert.panic("new severity counts exceed {d} new findings", .{review.new});
    if (options.@"capture-baseline" or options.@"update-baseline") return false;
    const considered = if (options.@"new-only") review.new_counts else counts;
    return considered.errors > 0 or (options.@"fail-on" == .warning and considered.warnings > 0);
}

pub const check_options: []const @import("zcli").OptionInfo = &.{
    .{ .name = "baseline", .metavar = "PATH", .help = "Compare against this explicit baseline file." },
    .{ .name = "capture-baseline", .help = "Explicitly create --baseline from all current findings; refuses to overwrite." },
    .{ .name = "update-baseline", .help = "Explicitly replace --baseline with all current findings and report changes." },
    .{ .name = "new-only", .help = "With --baseline, fail only on new findings at --fail-on severity." },
    .{ .name = "triage", .help = "Group by rule and file, defaulting to pages of 20. Use --json to export full details." },
    .{ .name = "rule", .metavar = "RULE", .help = "Filter report to this exact rule without changing baseline comparison." },
    .{ .name = "file", .metavar = "PATH", .help = "Filter report to this exact reported path." },
    .{ .name = "classification", .metavar = "STATUS", .help = "Filter to new, existing, resolved, or unclassified." },
    .{ .name = "offset", .metavar = "N", .help = "Skip N matching findings in deterministic order." },
    .{ .name = "page-size", .metavar = "N", .help = "Return at most N matching findings (1 to 10000)." },
    .{ .name = "rules", .metavar = "RULES", .help = "Comma-separated rules to run instead of the defaults.", .example = "unbounded-loop,long-function" },
    .{ .name = "fix", .help = "Apply the fixes zanity can make, then report what is left." },
    .{ .name = "strict", .help = "Also run the strict rules, for what safety-critical code needs and most code doesn't, such as two assertions in every function." },
    .{ .name = "watch", .help = "Check again each time a file it checks, or zanity.toml, changes, until Ctrl-C." },
    .{ .name = "fail-on", .metavar = "SEVERITY", .help = "Exit 1 on findings this severe or worse: error, or warning as a pre-commit hook or CI should.", .example = "warning" },
    .{ .name = "agent", .help = "Print findings for a coding agent: totals and the next command first, then each finding with its fix. On by default when CLAUDECODE is set and neither --json nor --plain is given.", .env = "ZANITY_AGENT" },
    .{ .name = "limit", .metavar = "N", .help = "With --agent, show at most N findings in all, rules first to last, and list the other rules by name; 0 shows them all.", .example = "0" },
    .{ .name = "infer", .help = "Also ask a decision model what no deterministic check can decide, such as whether an error message misleads: TypeSafe's Jev, which needs TYPESAFE_API_KEY, or the System One server [infer] in zanity.toml names, such as a local Kev." },
};

pub fn renderOutput(ctx: anytype, ws: anytype, options: anytype, agent: bool) !void {
    if (ws.rows.len > ws.review.matching) assert.panic("output has {d} rows over matching total", .{ws.rows.len});
    if (options.paths.len == 0) assert.panic("output requires checked paths", .{});
    if (ctx.format == .human or agent) return renderReview(ctx, ws, options, agent);
    const output = ctx.runtime.out;
    if (ctx.format == .json) {
        const history = &ws.history;
        try std.json.Stringify.value(.{
            .schema_version = @as(u32, 1),
            .identity_version = @as(u32, 1),
            .summary = .{ .new = ws.review.new, .existing = ws.review.existing, .resolved = ws.review.resolved },
            .resolved_since_previous = history.resolved.items(),
            .pagination = .{ .matching_total = ws.review.matching, .returned = ws.rows.len, .offset = options.offset, .next_offset = ws.review.next, .next_command = try nextCommand(ws, options) },
            .findings = ws.rows.items(),
        }, .{}, output.writer);
        try output.writer.writeByte('\n');
    } else {
        try @import("watch.zig").renderRows(Row, output.writer, false, ws.rows.items());
        const err = ctx.runtime.err;
        try err.writer.print("Matching total {d}; returned {d}; next offset {?d}.\n", .{ ws.review.matching, ws.rows.len, ws.review.next });
        try continuation(err.writer, ws.args, ws.review.next orelse options.offset, options.@"page-size" orelse 20);
    }
}

fn nextCommand(ws: anytype, options: anytype) !?[]const u8 {
    const text = &ws.text;
    if (text.used > text.buffer.len) assert.panic("command text used {d} exceeds buffer", .{text.used});
    if (ws.rows.len > ws.review.matching) assert.panic("command selection has {d} rows over matching total", .{ws.rows.len});
    const offset = ws.review.next orelse return null;
    var command: std.Io.Writer = .fixed(text.buffer[text.used..]);
    try writeCommand(&command, ws.args, offset, options.@"page-size" orelse 20);
    const bytes = command.buffered();
    text.used += bytes.len;
    return bytes;
}

test "new-only thresholds ignore inherited errors but still fail on new errors" {
    var options: CheckOptions = .{ .paths = &.{"."}, .baseline = "baseline.json", .@"new-only" = true };
    const counts: @import("report.zig").Counts = .{ .files = 1, .errors = 10000, .warnings = 1 };
    var review: @import("baseline.zig").Review = .{ .new = 1, .existing = 10000, .new_counts = .{ .files = 1, .warnings = 1 } };
    try std.testing.expectEqual(false, failsReview(options, counts, review));
    options.@"fail-on" = .warning;
    try std.testing.expectEqual(true, failsReview(options, counts, review));
    options.@"fail-on" = .@"error";
    review.new_counts = .{ .files = 1, .errors = 1 };
    try std.testing.expectEqual(true, failsReview(options, counts, review));
    options.@"new-only" = false;
    review = .{};
    try std.testing.expectEqual(true, failsReview(options, counts, review));
}
