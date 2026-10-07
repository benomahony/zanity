const std = @import("std");
const assert = @import("assert.zig");
const zrich = @import("zrich");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const Finding = @import("facts.zig").Finding;

const quiet: zrich.Style = .{ .dim = true };

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

    pub fn initTableScratch(gpa: std.mem.Allocator, files: u32) std.mem.Allocator.Error!TableScratch {
        if (files == 0) assert.panic("the report table was given room for 0 files; memory.Limits.files must be above 0", .{});
        const scratch: TableScratch = .{ .tallies = try .initBounded(gpa, files, "files with findings") };
        if (scratch.tallies.capacity() != files) assert.panic("the report table asked for room for {d} files and got {d}", .{ files, scratch.tallies.capacity() });
        return scratch;
    }
};

pub const Sink = struct { console: zrich.Console, scratch: *TableScratch, text: *memory.Text };

/// The first findings, errors first, then a table of files, worst first, with a total, as a
/// coverage report has. How to fix each finding is in --agent, --plain and --json.
pub fn render(sink: Sink, findings: []const Finding) !void {
    if (!std.sort.isSorted(Finding, findings, {}, findingOrder)) assert.panic("expected findings sorted by path and position, got {d} findings out of order; call sortFindings() before render()", .{findings.len});
    if (findings.len >= std.math.maxInt(u32)) assert.panic("{d} findings is more than a report can number; lower memory.Limits.findings below 4 billion", .{findings.len});
    try summariseFiles(sink, findings);
    try renderPreview(sink.console, findings);
    try renderTable(sink, findings);
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

/// Findings shown before the table, errors first; the table counts the rest.
const preview_findings = 10;
/// Files the table lists, worst first; the others share one row.
const table_files = 20;

/// Up to `preview_findings` findings, errors first, one line each: where, how bad, which rule, and
/// what is wrong without the explanation every finding of its rule shares.
fn renderPreview(console: zrich.Console, findings: []const Finding) !void {
    if (findings.len == 0) return;
    var picked: [preview_findings]usize = undefined;
    var picked_count: usize = 0;
    for ([_]bool{ true, false }) |errors| {
        for (findings, 0..) |f, i| {
            if (picked_count == preview_findings) break;
            if ((rules.all[ruleIndex(f.rule)].severity == .@"error") != errors) continue;
            picked[picked_count] = i;
            picked_count += 1;
        }
    }
    var where: usize = 0;
    var rule: usize = 0;
    for (picked[0..picked_count]) |i| {
        const f = findings[i];
        where = @max(where, f.path.len + 1 + locationWidth(f));
        rule = @max(rule, f.rule.len);
    }
    const out = console.writer;
    var buffer: [512]u8 = undefined;
    for (picked[0..picked_count]) |i| {
        const f = findings[i];
        const severity = rules.all[ruleIndex(f.rule)].severity;
        const location = std.fmt.bufPrint(&buffer, "{s}:{d}:{d}", .{ f.path, f.line + 1, f.column + 1 }) catch f.path;
        try out.writeAll(location);
        try out.splatByteAll(' ', where - @min(where, location.len) + 2);
        try console.styled(label(severity), severityStyle(severity));
        try out.splatByteAll(' ', "warning".len - label(severity).len + 2);
        try console.styled(f.rule, quiet);
        try out.splatByteAll(' ', rule - f.rule.len + 2);
        const message = brief(f.message);
        const room = console.options.width -| (where + 2 + "warning".len + 2 + rule + 2);
        if (message.len <= room or room < 20) try out.print("{s}\n", .{message}) else try out.print("{s}...\n", .{message[0 .. room - 3]});
    }
    if (findings.len > picked_count) try console.styled(try std.fmt.bufPrint(&buffer, "+{d} more\n", .{findings.len - picked_count}), quiet);
    if (where < "a:1:1".len or rule == 0) assert.panic("the preview's columns came out {d} and {d} wide; a location is at least 'a:1:1' and every finding names its rule", .{ where, rule });
    if (picked_count > preview_findings) assert.panic("picked {d} findings to show, past the {d} the preview holds; the loops stop at preview_findings", .{ picked_count, preview_findings });
}

/// One row per file with findings, worst first, up to `table_files`, then one row for the rest and
/// a total, each with its errors, its warnings and the rule that fired most there: plain aligned
/// columns, as a coverage report has, fitted to the terminal by shortening paths from the left.
fn renderTable(sink: Sink, findings: []const Finding) !void {
    const scratch = sink.scratch;
    const tallies = scratch.tallies.items();
    if (tallies.len == 0) return;
    if (tallies.len > findings.len) assert.panic("{d} files with findings among {d} findings; each tallied file has at least one", .{ tallies.len, findings.len });
    std.mem.sort(FileTally, tallies, {}, worstFirst);
    const listed = @min(tallies.len, table_files);
    var rows: [table_files + 2]Row = undefined;
    for (tallies[0..listed], 0..) |t, i| rows[i] = .{ .name = t.path, .counts = .{ .errors = t.errors, .warnings = t.warnings }, .most = mostCommon(findings, tallies[i .. i + 1]) };
    var filled = listed;
    var total: Pair = .{};
    for (tallies) |t| total = .{ .errors = total.errors + t.errors, .warnings = total.warnings + t.warnings };
    if (tallies.len > listed) {
        var rest: Pair = .{};
        for (tallies[listed..]) |t| rest = .{ .errors = rest.errors + t.errors, .warnings = rest.warnings + t.warnings };
        const more = tallies.len - listed;
        rows[filled] = .{ .name = try sink.text.format("... {d} more {s}", .{ more, if (more == 1) "file" else "files" }), .counts = rest, .most = mostCommon(findings, tallies[listed..]) };
        filled += 1;
    }
    rows[filled] = .{ .name = "TOTAL", .counts = total, .most = mostCommon(findings, tallies) };
    try writeTable(sink.console, rows[0 .. filled + 1]);
    if (filled + 1 > rows.len) assert.panic("filled {d} table rows in room for {d}; the table lists at most table_files files, the rest and the total", .{ filled + 1, rows.len });
}

const Pair = struct { errors: u32 = 0, warnings: u32 = 0 };
const Row = struct { name: []const u8, counts: Pair, most: []const u8 };

/// The rule that fired most in the files of `tallies`.
fn mostCommon(findings: []const Finding, tallies: []const FileTally) []const u8 {
    if (tallies.len == 0) assert.panic("finding the most common rule of no files; renderTable() passes at least one", .{});
    var per_rule: [rules.all.len]u32 = @splat(0);
    for (tallies) |t| for (findings[t.start..t.end]) |f| {
        per_rule[ruleIndex(f.rule)] += 1;
    };
    var most: usize = 0;
    for (per_rule, 0..) |n, i| if (n > per_rule[most]) {
        most = i;
    };
    if (per_rule[most] == 0) assert.panic("the files of {d} tallies hold no findings; summariseFiles() only tallies files with some", .{tallies.len});
    return rules.all[most].name;
}

/// Writes `rows` as aligned columns under a header, the last row, the total, below a rule.
fn writeTable(console: zrich.Console, rows: []const Row) !void {
    if (rows.len < 2) assert.panic("writing a table of {d} rows; it always has a file and the total", .{rows.len});
    const out = console.writer;
    var most: usize = "Most common".len;
    var name: usize = "File".len;
    for (rows) |r| {
        most = @max(most, r.most.len);
        name = @max(name, r.name.len);
    }
    const counts = 2 + "Errors".len + 2 + "Warnings".len + 2;
    const room = console.options.width -| (counts + most);
    name = @max(@min(name, room), "TOTAL".len + 8);
    if (name < "TOTAL".len) assert.panic("the name column came out {d} wide, too narrow for TOTAL", .{name});
    try out.writeByte('\n');
    try writePadded(console, "File", name, .{ .bold = true });
    try console.styled("  Errors  Warnings  Most common\n", .{ .bold = true });
    for (rows, 0..) |r, i| {
        const last = i + 1 == rows.len;
        if (last) {
            try out.splatByteAll('-', name + counts + most);
            try out.writeByte('\n');
        }
        try writePadded(console, r.name, name, if (last) .{ .bold = true } else .{});
        try out.print("  {d:>6}  {d:>8}  ", .{ r.counts.errors, r.counts.warnings });
        try console.styled(r.most, quiet);
        try out.writeByte('\n');
    }
}

/// The last `width - 3` bytes of `text`, which padded() writes after `...`.
fn shortened(text: []const u8, width: usize) []const u8 {
    if (width < 4) assert.panic("shortening '{s}' to {d} bytes; writeTable() keeps at least 13 for names", .{ text, width });
    if (text.len <= width) return text;
    const kept = text[text.len - (width - 3) ..];
    if (kept.len + 3 != width) assert.panic("shortened '{s}' to {d} bytes, not {d}", .{ text, kept.len + 3, width });
    return kept;
}

/// Writes `text` padded with spaces to `width`, after shortening it from the left with `...` when
/// it is longer, so the end of a path, its file name, stays.
fn writePadded(console: zrich.Console, text: []const u8, width: usize, style: zrich.Style) !void {
    if (text.len == 0 or width < 4) assert.panic("padding '{s}' to {d} columns; table cells hold a name and are at least 4 wide", .{ text, width });
    const fits = text.len <= width;
    const shown = if (fits) text else shortened(text, width);
    if (!fits) try console.styled("...", style);
    try console.styled(shown, style);
    const used = shown.len + @as(usize, if (fits) 0 else 3);
    if (used > width) assert.panic("'{s}' took {d} columns of a {d}-column table cell; shortened() keeps width - 3 bytes", .{ text, used, width });
    try console.writer.splatByteAll(' ', width - used);
}

/// How often each rule fired and in how many files, and the fired rules' indexes in rules.all,
/// errors first and then the most frequent.
const Fired = struct {
    per_rule: [rules.all.len]u32 = @splat(0),
    files: [rules.all.len]u32 = @splat(0),
    order: [rules.all.len]usize = undefined,
    count: usize = 0,

    /// Counts `findings`, which are sorted by path, so a rule's findings in one file are adjacent
    /// among that rule's.
    fn initFired(findings: []const Finding) Fired {
        var fired: Fired = .{};
        var last_path: [rules.all.len][]const u8 = @splat("");
        for (findings) |f| {
            const index = ruleIndex(f.rule);
            fired.per_rule[index] += 1;
            if (std.mem.eql(u8, last_path[index], f.path)) continue;
            fired.files[index] += 1;
            last_path[index] = f.path;
        }
        var total: usize = 0;
        for (fired.per_rule, 0..) |n, i| if (n > 0) {
            total += n;
            fired.order[fired.count] = i;
            fired.count += 1;
        };
        if (total != findings.len) assert.panic("counted {d} findings under their rules but was given {d}; every finding needs a known rule", .{ total, findings.len });
        std.mem.sort(usize, fired.order[0..fired.count], &fired.per_rule, ruleOrder);
        if (findings.len > 0 and fired.count == 0) assert.panic("{d} findings but no rule fired; initFired() must count every finding under its rule", .{findings.len});
        return fired;
    }
};

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

/// Findings for a coding agent: the totals and what to run next first, so a truncated read still
/// has them, then each rule that fired, errors first, with its fix once and up to `limit` of its
/// findings by file as `line:column message`, `[--fix]` marking those zanity can fix itself. A
/// finding's own fix follows it only when it has one beyond the rule's. `limit` 0 shows them all.
pub fn renderAgent(out: *std.Io.Writer, report: AgentReport) !void {
    const findings = report.findings;
    const counts = report.counts;
    const paths = report.paths;
    if (paths.len == 0) assert.panic("rendering agent output with no paths to name in the next command; pass the paths the run checked", .{});
    if (counts.errors + counts.warnings != findings.len) assert.panic("rendering {d} findings for {d} errors and {d} warnings; count() the findings being rendered", .{ findings.len, counts.errors, counts.warnings });
    const files = if (counts.files == 1) "file" else "files";
    if (findings.len == 0) return out.print("zanity: checked {d} {s}, no issues found.\n", .{ counts.files, files });
    var fixable: usize = 0;
    for (findings) |f| fixable += @intFromBool(f.edit != null);
    try out.print("zanity: {d} {s}, {d} {s} in {d}/{d} {s}", .{ counts.errors, if (counts.errors == 1) "error" else "errors", counts.warnings, if (counts.warnings == 1) "warning" else "warnings", counts.flagged, counts.files, files });
    if (fixable > 0) {
        const scope: CheckedPaths = .{ .paths = paths };
        try out.print("; {d} [--fix].\nNext: `zanity check {f} --fix`, fix the rest", .{ fixable, scope });
    } else try out.writeAll(".\nNext: fix these");
    try out.writeAll(", rerun with --strict. Don't silence rules.\n");
    const fired = Fired.initFired(findings);
    var budget = report.limit;
    var listed = false;
    for (fired.order[0..fired.count]) |index| {
        const tally: RuleTally = .{ .index = index, .total = fired.per_rule[index], .files = fired.files[index] };
        if (report.limit == 0 or budget > 0) {
            var part = report;
            part.limit = budget;
            budget -|= try renderAgentRule(out, part, tally);
            continue;
        }
        const rule = rules.all[index];
        if (!listed) try out.writeAll("\nAlso, to see with --rules <name>:\n");
        listed = true;
        try out.print("  {s} [{s}] {d} in {d} {s}\n", .{ rule.name, label(rule.severity), tally.total, tally.files, if (tally.files == 1) "file" else "files" });
    }
    if (report.limit > 0 and budget > report.limit) assert.panic("showed findings past the budget of {d}; renderAgentRule() shows at most what remains", .{report.limit});
}

/// Whether any of the first `limit` findings of `rule` has no fix of its own, so the rule's advice is
/// needed; 0 means all of them.
fn anyWithoutFix(findings: []const Finding, rule: []const u8, limit: u32) bool {
    if (rule.len == 0) assert.panic("looking for findings of an unnamed rule; every rule has a name", .{});
    var seen: u32 = 0;
    for (findings) |f| {
        if (!std.mem.eql(u8, f.rule, rule)) continue;
        if (limit > 0 and seen == limit) break;
        seen += 1;
        if (f.fix.len == 0) return true;
    }
    if (seen == 0) assert.panic("no finding of '{s}' to show; renderAgentRule() runs only for rules that fired", .{rule});
    return false;
}

/// A finding's message or fix without its explanation, which is the same for every finding of its rule:
/// "'x' is written 3 times in 'f'" from "..., so a change to it has to be made in every copy."
fn brief(message: []const u8) []const u8 {
    if (message.len == 0) assert.panic("shortening an empty message; every finding says what is wrong", .{});
    const end = std.mem.indexOf(u8, message, ", so ") orelse message.len;
    const kept = std.mem.trimEnd(u8, message[0..end], ".");
    if (kept.len > message.len) assert.panic("'{s}' came out longer than '{s}'; brief() only cuts", .{ kept, message });
    return kept;
}

/// What renderAgent() reports: the run's sorted findings and their counts, the paths it checked,
/// and how many findings to show in all, 0 for every one; rules past that are listed by name.
pub const AgentReport = struct { findings: []const Finding, counts: Counts, paths: []const []const u8, limit: u32 };

/// A rule that fired: its index in rules.all, its findings, and the files they are in.
const RuleTally = struct { index: usize, total: u32, files: u32 };

/// One rule's heading, then up to `limit` of its findings and a count of the rest; returns how many
/// it showed. A
/// finding with a fix of its own shows only that fix, which names what to change; one without
/// shows its message without the explanation its rule's findings share.
fn renderAgentRule(out: *std.Io.Writer, report: AgentReport, tally: RuleTally) !u32 {
    const findings = report.findings;
    const limit = report.limit;
    const rule = rules.all[tally.index];
    if (tally.total == 0 or tally.files > tally.total) assert.panic("{s} fired {d} times in {d} files; a rule renders only when it fired, in at most one file per finding", .{ rule.name, tally.total, tally.files });
    try out.print("\n{s} [{s}] {d} in {d} {s}", .{ rule.name, label(rule.severity), tally.total, tally.files, if (tally.files == 1) "file" else "files" });
    if (anyWithoutFix(findings, rule.name, limit)) try out.print(": {s}", .{rule.advice});
    try out.writeByte('\n');
    var shown: u32 = 0;
    var path: []const u8 = "";
    for (findings) |f| {
        if (!std.mem.eql(u8, f.rule, rule.name)) continue;
        if (limit > 0 and shown == limit) break;
        shown += 1;
        if (!std.mem.eql(u8, path, f.path)) try out.print("  {s}\n", .{f.path});
        path = f.path;
        try out.print("    {d}:{d}{s} ", .{ f.line + 1, f.column + 1, if (f.edit != null) " [--fix]" else "" });
        try out.print("{s}.\n", .{brief(if (f.fix.len > 0) f.fix else f.message)});
    }
    if (shown < tally.total) try out.print("  +{d} more: --rules {s} --limit 0\n", .{ tally.total - shown, rule.name });
    if (shown > tally.total) assert.panic("showed {d} {s} findings of {d}; show only the rule's own findings", .{ shown, rule.name, tally.total });
    return shown;
}

/// The paths a run checked, written as they would be typed after `zanity check`.
const CheckedPaths = struct {
    paths: []const []const u8,

    pub fn format(self: CheckedPaths, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.paths.len == 0) assert.panic("writing a command with no paths; renderAgent() refuses an empty list", .{});
        for (self.paths, 0..) |path, i| {
            if (path.len == 0) assert.panic("path {d} of {d} is empty; zcli passes each path as typed, and none can be empty", .{ i + 1, self.paths.len });
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(path);
        }
    }
};

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
