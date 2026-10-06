const std = @import("std");
const assert = @import("assert.zig");
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
    if (!std.sort.isSorted(Finding, findings, {}, findingOrder)) assert.panic("expected findings sorted by path and position, got {d} findings out of order; sort with findingOrder before checking the order", .{findings.len});
    if (findings.len >= std.math.maxInt(u32)) assert.panic("{d} findings is more than a report can number; raise the u32 counts in report.zig", .{findings.len});
}

fn findingOrder(_: void, a: Finding, b: Finding) bool {
    if (a.path.len == 0) assert.panic("a {s} finding at line {d} has no path; findings are added with the path of the file checked", .{ a.rule, a.line + 1 });
    if (b.path.len == 0) assert.panic("a {s} finding at line {d} has no path; findings are added with the path of the file checked", .{ b.rule, b.line + 1 });
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
    if (counts.errors + counts.warnings != findings.len) assert.panic("counted {d} errors and {d} warnings among {d} findings; a severity is missing from count()", .{ counts.errors, counts.warnings, findings.len });
    if (counts.flagged > findings.len) assert.panic("counted {d} flagged files from {d} findings; findings must be sorted by path before counting", .{ counts.flagged, findings.len });
    return counts;
}

/// What one file's findings add up to: `findings[start..end]` are its findings.
const FileTally = struct {
    path: []const u8,
    start: usize,
    end: usize,
    errors: u32 = 0,
    warnings: u32 = 0,
};

pub const TableScratch = struct {
    tallies: memory.Bounded(FileTally),
    cells: [][3]zrich.Cell,
    rows: [][]const zrich.Cell,

    pub fn initTableScratch(gpa: std.mem.Allocator, files: u32) std.mem.Allocator.Error!TableScratch {
        if (files == 0) assert.panic("the report table was given room for 0 files; memory.Limits.files must be above 0", .{});
        const cells = try memory.reserve(gpa, [3]zrich.Cell, files);
        if (cells.len != files) assert.panic("the report table asked for {d} rows and got {d}; raise the rows given to initTableScratch()", .{ files, cells.len });
        return .{ .tallies = try .initBounded(gpa, files, "files with findings"), .cells = cells, .rows = try memory.reserve(gpa, []const zrich.Cell, files) };
    }
};

pub const Sink = struct { console: zrich.Console, scratch: *TableScratch, text: *memory.Text };

/// Each file's findings with their fixes, then a table of files, worst first, and a table of rules.
pub fn render(sink: Sink, findings: []const Finding) !void {
    if (!std.sort.isSorted(Finding, findings, {}, findingOrder)) assert.panic("expected findings sorted by path and position, got {d} findings out of order; call sortFindings() before render()", .{findings.len});
    if (findings.len >= std.math.maxInt(u32)) assert.panic("{d} findings is more than a report can number; lower memory.Limits.findings below 4 billion", .{findings.len});
    try summariseFiles(sink, findings);
    const tallies = sink.scratch.tallies;
    for (tallies.items()) |t| try renderFile(sink.console, t, findings[t.start..t.end]);
    try renderTable(sink);
    try renderRules(sink, findings);
}

fn summariseFiles(sink: Sink, findings: []const Finding) !void {
    const tallies = &sink.scratch.tallies;
    tallies.clear();
    var start: usize = 0;
    for (0..findings.len) |_| {
        if (start == findings.len) break;
        var end = start;
        while (end < findings.len and std.mem.eql(u8, findings[end].path, findings[start].path)) end += 1;
        try tallies.add(summariseFile(findings[start].path, findings[start..end], start));
        start = end;
    }
    if (start != findings.len) assert.panic("tallied files up to finding {d} of {d}; findings must be sorted by path so each file's run is contiguous", .{ start, findings.len });
    if (tallies.len > findings.len) assert.panic("{d} file tallies from {d} findings; each tally needs a finding", .{ tallies.len, findings.len });
}

/// Counts one file's errors and warnings.
fn summariseFile(path: []const u8, findings: []const Finding, start: usize) FileTally {
    if (findings.len == 0) assert.panic("tallying {s} with no findings; only files with findings get a row, so summarise() must skip files with none", .{path});
    var tally: FileTally = .{ .path = path, .start = start, .end = start + findings.len };
    for (findings) |f| {
        switch (rules.all[ruleIndex(f.rule)].severity) {
            .@"error" => tally.errors += 1,
            .warning, .information => tally.warnings += 1,
        }
    }
    if (tally.errors + tally.warnings != findings.len) assert.panic("{s}: counted {d} errors and {d} warnings among {d} findings; every finding is an error or a warning, so check the severity switch in summariseFile()", .{ path, tally.errors, tally.warnings, findings.len });
    if (tally.end <= tally.start) assert.panic("{s}: tally covers findings {d}..{d}; the range must run forwards within the findings, so check how summarise() sets start and end", .{ path, tally.start, tally.end });
    return tally;
}

fn ruleOrder(per_rule: *const [rules.all.len]u32, a: usize, b: usize) bool {
    if (per_rule[a] == 0) assert.panic("sorting rule {s}, which did not fire; only fired rules are ordered", .{rules.all[a].name});
    if (per_rule[b] == 0) assert.panic("sorting rule {s}, which did not fire; only fired rules are ordered", .{rules.all[b].name});
    const sa = @backingInt(rules.all[a].severity);
    const sb = @backingInt(rules.all[b].severity);
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
    for (findings) |f| try renderFinding(console, f, width);
    if (findings.len != tally.end - tally.start) assert.panic("{s}: rendering {d} findings for a tally of {d} ({d}..{d}); render the tally's own range of findings", .{ tally.path, findings.len, tally.end - tally.start, tally.start, tally.end });
    if (width < 3) assert.panic("{s}: the widest location is {d} characters; a location is at least '1:1', so locationWidth() must measure line and column counted from 1", .{ tally.path, width });
}

/// A finding's location, severity, message and rule on one line, aligned to `width`, and how to fix it on the next.
fn renderFinding(console: zrich.Console, f: Finding, width: usize) !void {
    const out = console.writer;
    const rule = rules.find(f.rule) orelse unreachable;
    if (locationWidth(f) > width) assert.panic("{s}: the location of {d}:{d} is wider than the {d} columns kept for locations; measure every finding before rendering any", .{ f.path, f.line + 1, f.column + 1, width });
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
    if (f.message.len == 0) assert.panic("{s}:{d}: a {s} finding has no message; report() must pass one", .{ f.path, f.line + 1, f.rule });
}

fn plural(n: u32, word: []const u8) []const u8 {
    if (word.len == 0) assert.panic("asked for the plural of an empty word (count {d}); pass the word to pluralise", .{n});
    if (word[word.len - 1] == 's') assert.panic("'{s}' already ends in 's'; pass the singular", .{word});
    return if (n == 1) word else if (std.mem.eql(u8, word, "error")) "errors" else "warnings";
}

/// One row per file with findings, the files most in need of work first.
fn renderTable(sink: Sink) !void {
    const s = sink.scratch;
    const tallies = s.tallies.items();
    if (tallies.len == 0) return;
    std.mem.sort(FileTally, tallies, {}, worstFirst);
    if (!std.sort.isSorted(FileTally, tallies, {}, worstFirst)) assert.panic("expected files worst first, got {d} files out of order; sort the tallies worst first before rendering them", .{tallies.len});
    for (tallies, 0..) |t, row| {
        s.cells[row] = .{
            .{ .text = t.path },
            .{ .text = try sink.text.format("{d}", .{t.errors}), .style = if (t.errors > 0) severityStyle(.@"error") else quiet },
            .{ .text = try sink.text.format("{d}", .{t.warnings}), .style = if (t.warnings > 0) severityStyle(.warning) else quiet },
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
        },
        .rows = s.rows[0..tallies.len],
    };
    const console = sink.console;
    try console.writer.writeByte('\n');
    try table.render(sink.console.context(), fixed.allocator());
    if (tallies.len > s.rows.len) assert.panic("{d} files have findings but the table has {d} rows; raise memory.Limits.files", .{ tallies.len, s.rows.len });
}

/// One row per rule that fired: errors first, then the rules that fired most, so the table says where to start.
fn renderRules(sink: Sink, findings: []const Finding) !void {
    if (findings.len == 0) return;
    var per_rule: [rules.all.len]u32 = @splat(0);
    var files: [rules.all.len]u32 = @splat(0);
    var last_path: [rules.all.len][]const u8 = @splat("");
    for (findings) |f| {
        const index = ruleIndex(f.rule);
        per_rule[index] += 1;
        if (std.mem.eql(u8, last_path[index], f.path)) continue;
        files[index] += 1;
        last_path[index] = f.path;
    }
    var total: usize = 0;
    for (per_rule) |n| total += n;
    if (total != findings.len) assert.panic("the rule table counted {d} findings but was given {d}; every finding needs a known rule", .{ total, findings.len });
    var order: [rules.all.len]usize = undefined;
    var fired: usize = 0;
    for (per_rule, 0..) |n, i| if (n > 0) {
        order[fired] = i;
        fired += 1;
    };
    std.mem.sort(usize, order[0..fired], &per_rule, ruleOrder);
    var cells: [rules.all.len][4]zrich.Cell = undefined;
    var rows: [rules.all.len][]const zrich.Cell = undefined;
    for (order[0..fired], 0..) |i, row| {
        const rule = rules.all[i];
        cells[row] = .{
            .{ .text = rule.name },
            .{ .text = label(rule.severity), .style = severityStyle(rule.severity) },
            .{ .text = try sink.text.format("{d}", .{per_rule[i]}) },
            .{ .text = try sink.text.format("{d}", .{files[i]}), .style = quiet },
        };
        rows[row] = &cells[row];
    }
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const table: zrich.Table = .{
        .columns = &.{
            .{ .header = "Rule" },
            .{ .header = "Severity" },
            .{ .header = "Findings", .alignment = .right },
            .{ .header = "Files", .alignment = .right },
        },
        .rows = rows[0..fired],
    };
    const console = sink.console;
    try console.writer.writeByte('\n');
    try table.render(sink.console.context(), fixed.allocator());
    if (fired == 0) assert.panic("{d} findings but no rule fired; renderRules() must count every finding under its rule", .{findings.len});
}

fn worstFirst(_: void, a: FileTally, b: FileTally) bool {
    if (a.path.len == 0) assert.panic("a file tally with {d} errors has no path; summarise() must set each tally's path from its findings", .{a.errors});
    if (b.path.len == 0) assert.panic("a file tally with {d} errors has no path; summarise() must set each tally's path from its findings", .{b.errors});
    if (a.errors != b.errors) return a.errors > b.errors;
    if (a.warnings != b.warnings) return a.warnings > b.warnings;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn ruleIndex(name: []const u8) usize {
    if (name.len == 0) assert.panic("looked up the report column of a finding with no rule name; report() must always pass a rule name", .{});
    for (rules.all, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) {
        if (rules.find(name).?.severity != r.severity) assert.panic("rule {s} has two severities: {t} by name, {t} in rules.all; take the severity from rules.find(), not from the finding", .{ name, rules.find(name).?.severity, r.severity });
        return i;
    };
    unreachable;
}

fn locationWidth(f: Finding) usize {
    const width = digits(f.line + 1) + 1 + digits(f.column + 1);
    if (width < 3) assert.panic("'{d}:{d}' is {d} characters wide; a location is at least '1:1', so pass line and column counted from 1", .{ f.line + 1, f.column + 1, width });
    if (width > 21) assert.panic("'{d}:{d}' is {d} characters wide; the report pads locations to at most 21, so widen the padding in renderFile() for larger files", .{ f.line + 1, f.column + 1, width });
    return width;
}

fn label(severity: rules.Severity) []const u8 {
    const text = switch (severity) {
        .@"error" => "error",
        .warning => "warning",
        .information => "info",
    };
    if (text.len == 0) assert.panic("severity {t} has an empty label; give it a label in label()'s switch", .{severity});
    if (text.len > "warning".len) assert.panic("severity label '{s}' is longer than 'warning', which the report pads to, so shorten it or widen the padding in renderFile()", .{text});
    return text;
}

fn severityStyle(severity: rules.Severity) zrich.Style {
    const colour: zrich.NamedColor = switch (severity) {
        .@"error" => .red,
        .warning => .yellow,
        .information => .blue,
    };
    if (@backingInt(colour) >= 8) assert.panic("severity {t} uses colour {t}, outside the 8 basic terminal colours; pick one of zrich's named basic colours in severityStyle()", .{ severity, colour });
    if (colour == .green) assert.panic("severity {t} is green, which the report keeps for 'no issues found'; pick another colour for it in severityStyle()", .{severity});
    return .{ .fg = .{ .named = colour }, .bold = severity == .@"error" };
}

fn digits(value: usize) usize {
    if (value == 0) assert.panic("counting the digits of 0; line and column numbers start at 1, so pass them counted from 1", .{});
    const result = std.math.log10_int(value) + 1;
    if (result > 20) assert.panic("{d} has {d} digits, more than a usize can; the loop in digits() must stop at 0, so check its division", .{ value, result });
    return result;
}

pub fn summarise(console: zrich.Console, counts: Counts) !void {
    if (counts.flagged > counts.files) assert.panic("{d} files flagged out of {d} checked; summarise() must count a file at most once", .{ counts.flagged, counts.files });
    const files = if (counts.files == 1) "file" else "files";
    var buffer: [256]u8 = undefined;
    if (counts.errors + counts.warnings == 0) {
        const line = try std.fmt.bufPrint(&buffer, "zanity: checked {d} {s}, no issues found", .{ counts.files, files });
        try console.styled(line, .{ .fg = .{ .named = .green } });
        try console.writer.writeByte('\n');
        return;
    }
    if (counts.flagged == 0) assert.panic("{d} errors and {d} warnings but no file flagged; count() must flag the file of every finding", .{ counts.errors, counts.warnings });
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
