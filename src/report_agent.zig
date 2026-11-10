//! The report for a coding agent: the totals and the next command first, then each rule that
//! fired with its fix once and its findings by file, within a budget an agent can read.
const std = @import("std");
const assert = @import("assert.zig");
const rules = @import("rules.zig");
const Finding = @import("facts.zig").Finding;
const report_module = @import("report.zig");
const Counts = report_module.Counts;
const Fired = report_module.Fired;
const RuleTally = report_module.RuleTally;
const brief = report_module.brief;
const severityLabel = report_module.severityLabel;
const renderList = report_module.renderList;
const renderTotals = report_module.renderTotals;

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
    try renderTotals(out, findings, counts);
    if (findings.len == 0) return;
    if (report.all) return renderList(out, findings);
    try out.writeAll("Next: fix this displayed batch");
    try out.writeAll(if (report.watching)
        "; saving a file checks again. This is a selected batch. Resolve the displayed findings in code. If the code is correct, make that correctness explicit enough for the rule to verify; never suppress the finding, disable its rule or exclude its path.\n"
    else
        ", rerun the full check with --fail-on warning. This is a selected batch. Resolve the displayed findings in code. If the code is correct, make that correctness explicit enough for the rule to verify; never suppress the finding, disable its rule or exclude its path.\n");
    const shown = if (report.limit == 0) findings.len else @min(report.limit, findings.len);
    try out.print("Shown {d} of {d}; omitted {d}.\n", .{ shown, findings.len, findings.len - shown });
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
        try out.print("  {s} [{s}] {d} in {d} {s}\n", .{ rule.name, severityLabel(rule.severity), tally.total, tally.files, if (tally.files == 1) "file" else "files" });
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

/// What renderAgent() reports: the run's sorted findings and their counts, the paths it checked,
/// and how many findings to show in all, 0 for every one; rules past that are listed by name.
pub const AgentReport = struct {
    findings: []const Finding,
    counts: Counts,
    paths: []const []const u8,
    limit: u32,
    /// Whether `zanity check --watch` reruns this check when a file is saved.
    watching: bool = false,
    /// Whether to list every finding on its own line, with no grouping or limit.
    all: bool = false,
};

/// One rule's heading, then up to `limit` of its findings and a count of the rest; returns how many
/// it showed. A
/// finding with a fix of its own shows only that fix, which names what to change; one without
/// shows its message without the explanation its rule's findings share.
fn renderAgentRule(out: *std.Io.Writer, report: AgentReport, tally: RuleTally) !u32 {
    const findings = report.findings;
    const limit = report.limit;
    const rule = rules.all[tally.index];
    if (tally.total == 0 or tally.files > tally.total) assert.panic("{s} fired {d} times in {d} files; a rule renders only when it fired, in at most one file per finding", .{ rule.name, tally.total, tally.files });
    try out.print("\n{s} [{s}] {d} in {d} {s}", .{ rule.name, severityLabel(rule.severity), tally.total, tally.files, if (tally.files == 1) "file" else "files" });
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
        try out.print("    {d}:{d}{s} ", .{ f.line + 1, f.column + 1, if (f.fixable()) " [--fix]" else "" });
        try out.print("{s}.\n", .{brief(if (f.fix.len > 0) f.fix else f.message)});
    }
    if (shown < tally.total) try out.print("  +{d} more: --rules {s} --limit 0\n", .{ tally.total - shown, rule.name });
    if (shown > tally.total) assert.panic("showed {d} {s} findings of {d}; show only the rule's own findings", .{ shown, rule.name, tally.total });
    return shown;
}
