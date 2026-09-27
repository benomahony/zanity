const std = @import("std");
const assert = std.debug.assert;
const zrich = @import("zrich");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const Finding = @import("facts.zig").Finding;

const path_style: zrich.Style = .{ .bold = true, .underline = true };
const quiet: zrich.Style = .{ .dim = true };
const fix_style: zrich.Style = .{ .fg = .{ .named = .green } };

pub const Counts = struct {
    files: usize,
    errors: usize = 0,
    warnings: usize = 0,
    flagged: usize = 0,
};

pub fn sortFindings(findings: []Finding) void {
    std.mem.sort(Finding, findings, {}, findingOrder);
    assert(std.sort.isSorted(Finding, findings, {}, findingOrder));
    assert(findings.len < std.math.maxInt(u32));
}

fn findingOrder(_: void, a: Finding, b: Finding) bool {
    assert(a.path.len > 0);
    assert(b.path.len > 0);
    const by_path = std.mem.order(u8, a.path, b.path);
    if (by_path != .eq) return by_path == .lt;
    if (a.line != b.line) return a.line < b.line;
    if (a.column != b.column) return a.column < b.column;
    return std.mem.order(u8, a.rule, b.rule) == .lt;
}

pub fn count(findings: []const Finding, files: usize) Counts {
    var counts: Counts = .{ .files = files };
    var previous: []const u8 = "";
    for (findings) |f| {
        switch ((rules.find(f.rule) orelse unreachable).severity) {
            .@"error" => counts.errors += 1,
            .warning, .information => counts.warnings += 1,
        }
        if (!std.mem.eql(u8, previous, f.path)) counts.flagged += 1;
        previous = f.path;
    }
    assert(counts.errors + counts.warnings == findings.len);
    assert(counts.flagged <= findings.len);
    return counts;
}

/// What one file's findings add up to: `findings[start..end]` are its findings.
const FileTally = struct {
    path: []const u8,
    start: usize,
    end: usize,
    errors: u32 = 0,
    warnings: u32 = 0,
    rules: []const u8 = "",
};

pub const TableScratch = struct {
    tallies: memory.Bounded(FileTally),
    cells: [][4]zrich.Cell,
    rows: [][]const zrich.Cell,

    pub fn initTableScratch(gpa: std.mem.Allocator, files: u32) std.mem.Allocator.Error!TableScratch {
        assert(files > 0);
        const cells = try gpa.alloc([4]zrich.Cell, files);
        assert(cells.len == files);
        return .{ .tallies = try .initBounded(gpa, files, "files with findings"), .cells = cells, .rows = try gpa.alloc([]const zrich.Cell, files) };
    }
};

pub const Sink = struct { console: zrich.Console, scratch: *TableScratch, text: *memory.Text };

/// Each file's findings with their fixes, then a table of files, worst first.
pub fn render(sink: Sink, findings: []const Finding) !void {
    assert(std.sort.isSorted(Finding, findings, {}, findingOrder));
    assert(findings.len < std.math.maxInt(u32));
    try summariseFiles(sink, findings);
    for (sink.scratch.tallies.items()) |t| try renderFile(sink.console, t, findings[t.start..t.end]);
    try renderTable(sink);
}

fn summariseFiles(sink: Sink, findings: []const Finding) !void {
    const tallies = &sink.scratch.tallies;
    tallies.clear();
    var start: usize = 0;
    for (0..findings.len) |_| {
        if (start == findings.len) break;
        var end = start;
        while (end < findings.len and std.mem.eql(u8, findings[end].path, findings[start].path)) end += 1;
        try tallies.add(try summariseFile(sink.text, findings[start].path, findings[start..end], start));
        start = end;
    }
    assert(start == findings.len);
    assert(tallies.len <= findings.len);
}

/// Counts one file's findings and lists the rules that fired in it, worst first.
fn summariseFile(text: *memory.Text, path: []const u8, findings: []const Finding, start: usize) !FileTally {
    assert(findings.len > 0);
    var tally: FileTally = .{ .path = path, .start = start, .end = start + findings.len };
    var per_rule: [rules.all.len]u32 = @splat(0);
    for (findings) |f| {
        const index = ruleIndex(f.rule);
        per_rule[index] += 1;
        switch (rules.all[index].severity) {
            .@"error" => tally.errors += 1,
            .warning, .information => tally.warnings += 1,
        }
    }
    var order: [rules.all.len]usize = undefined;
    var fired: usize = 0;
    for (per_rule, 0..) |n, i| if (n > 0) {
        order[fired] = i;
        fired += 1;
    };
    std.mem.sort(usize, order[0..fired], &per_rule, ruleOrder);
    const begin = text.used;
    for (order[0..fired], 0..) |i, n| {
        if (n > 0) _ = try text.copy("\n");
        if (per_rule[i] == 1) _ = try text.copy(rules.all[i].name) else _ = try text.format("{s} ({d})", .{ rules.all[i].name, per_rule[i] });
    }
    tally.rules = text.buffer[begin..text.used];
    assert(tally.errors + tally.warnings == findings.len);
    assert(fired > 0);
    return tally;
}

fn ruleOrder(per_rule: *const [rules.all.len]u32, a: usize, b: usize) bool {
    assert(per_rule[a] > 0);
    assert(per_rule[b] > 0);
    const sa = @intFromEnum(rules.all[a].severity);
    const sb = @intFromEnum(rules.all[b].severity);
    if (sa != sb) return sa < sb;
    if (per_rule[a] != per_rule[b]) return per_rule[a] > per_rule[b];
    return a < b;
}

/// A file's header and counts, then each finding followed by how to fix it.
fn renderFile(console: zrich.Console, tally: FileTally, findings: []const Finding) !void {
    const out = console.writer;
    var width: usize = 0;
    for (findings) |f| width = @max(width, locationWidth(f));
    try out.writeByte('\n');
    try console.styled(tally.path, path_style);
    var counts: [64]u8 = undefined;
    try console.styled(try std.fmt.bufPrint(&counts, "  {d} {s}, {d} {s}", .{ tally.errors, plural(tally.errors, "error"), tally.warnings, plural(tally.warnings, "warning") }), quiet);
    try out.writeByte('\n');
    for (findings) |f| {
        const rule = rules.find(f.rule) orelse unreachable;
        var location: [24]u8 = undefined;
        try out.splatByteAll(' ', 2 + width - locationWidth(f));
        try console.styled(try std.fmt.bufPrint(&location, "{d}:{d}", .{ f.line + 1, f.column + 1 }), quiet);
        try out.writeAll("  ");
        try console.styled(label(rule.severity), severityStyle(rule.severity));
        try out.splatByteAll(' ', 2 + "warning".len - label(rule.severity).len);
        try console.write(f.message);
        try out.writeAll("  ");
        try console.styled(rule.name, quiet);
        try out.writeByte('\n');
        try out.splatByteAll(' ', 2 + width + 2 + "warning".len + 2);
        try console.styled("fix: ", quiet);
        try console.styled(f.advice(), fix_style);
        try out.writeByte('\n');
    }
    assert(findings.len == tally.end - tally.start);
    assert(width >= 3);
}

fn plural(n: u32, word: []const u8) []const u8 {
    assert(word.len > 0);
    assert(word[word.len - 1] != 's');
    return if (n == 1) word else if (std.mem.eql(u8, word, "error")) "errors" else "warnings";
}

/// One row per file with findings, the files most in need of work first.
fn renderTable(sink: Sink) !void {
    const s = sink.scratch;
    const tallies = s.tallies.items();
    if (tallies.len == 0) return;
    std.mem.sort(FileTally, tallies, {}, worstFirst);
    assert(std.sort.isSorted(FileTally, tallies, {}, worstFirst));
    for (tallies, 0..) |t, row| {
        s.cells[row] = .{
            .{ .text = t.path },
            .{ .text = try sink.text.format("{d}", .{t.errors}), .style = if (t.errors > 0) severityStyle(.@"error") else quiet },
            .{ .text = try sink.text.format("{d}", .{t.warnings}), .style = if (t.warnings > 0) severityStyle(.warning) else quiet },
            .{ .text = t.rules, .style = quiet },
        };
        s.rows[row] = &s.cells[row];
    }
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const table: zrich.Table = .{
        .columns = &.{
            .{ .header = "File" },
            .{ .header = "Errors", .alignment = .right },
            .{ .header = "Warnings", .alignment = .right },
            .{ .header = "Rules" },
        },
        .rows = s.rows[0..tallies.len],
    };
    try sink.console.writer.writeByte('\n');
    try table.render(sink.console.context(), fixed.allocator());
    assert(tallies.len <= s.rows.len);
}

fn worstFirst(_: void, a: FileTally, b: FileTally) bool {
    assert(a.path.len > 0);
    assert(b.path.len > 0);
    if (a.errors != b.errors) return a.errors > b.errors;
    if (a.warnings != b.warnings) return a.warnings > b.warnings;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn ruleIndex(name: []const u8) usize {
    assert(name.len > 0);
    for (rules.all, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) {
        assert(rules.find(name).?.severity == r.severity);
        return i;
    };
    unreachable;
}

fn locationWidth(f: Finding) usize {
    const width = digits(f.line + 1) + 1 + digits(f.column + 1);
    assert(width >= 3);
    assert(width <= 21);
    return width;
}

fn label(severity: rules.Severity) []const u8 {
    const text = switch (severity) {
        .@"error" => "error",
        .warning => "warning",
        .information => "info",
    };
    assert(text.len > 0);
    assert(text.len <= "warning".len);
    return text;
}

fn severityStyle(severity: rules.Severity) zrich.Style {
    const colour: zrich.NamedColor = switch (severity) {
        .@"error" => .red,
        .warning => .yellow,
        .information => .blue,
    };
    assert(@intFromEnum(colour) < 8);
    assert(colour != .green);
    return .{ .fg = .{ .named = colour }, .bold = severity == .@"error" };
}

fn digits(value: usize) usize {
    assert(value > 0);
    const result = std.math.log10_int(value) + 1;
    assert(result <= 20);
    return result;
}

pub fn summarise(console: zrich.Console, counts: Counts) !void {
    assert(counts.flagged <= counts.files);
    const files = if (counts.files == 1) "file" else "files";
    var buffer: [256]u8 = undefined;
    if (counts.errors + counts.warnings == 0) {
        const line = try std.fmt.bufPrint(&buffer, "zanity: checked {d} {s}, no issues found", .{ counts.files, files });
        try console.styled(line, .{ .fg = .{ .named = .green } });
        try console.writer.writeByte('\n');
        return;
    }
    assert(counts.flagged > 0);
    const line = try std.fmt.bufPrint(&buffer, "zanity: {d} {s} and {d} {s} in {d} of {d} {s}", .{
        counts.errors,
        if (counts.errors == 1) "error" else "errors",
        counts.warnings,
        if (counts.warnings == 1) "warning" else "warnings",
        counts.flagged,
        counts.files,
        files,
    });
    const colour: zrich.NamedColor = if (counts.errors > 0) .red else .yellow;
    try console.styled(line, .{ .fg = .{ .named = colour } });
    try console.writer.writeByte('\n');
}
