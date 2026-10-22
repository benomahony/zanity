const std = @import("std");
const assert = @import("assert.zig");
const triage = @import("triage.zig");
const baseline = @import("baseline.zig");

const Envelope = struct {
    summary: struct { new: usize, existing: usize, resolved: usize },
    pagination: struct { matching_total: usize, next_offset: ?usize },
    findings: []const baseline.Row,
};

/// Isolated --infer/--fix reruns still report transitions in the watching parent.
pub fn isolatedCheck(ctx: anytype, ws: anytype, rerun: anytype, options: anytype) !void {
    if (options.baseline == null) assert.panic("isolated baseline reporting needs a baseline", .{});
    if (rerun.argv.len > 256) assert.panic("isolated check has {d} arguments", .{rerun.argv.len});
    ws.rows.clear();
    ws.text.used = 0;
    var arena = std.heap.FixedBufferAllocator.init(ws.baseline_buffer);
    var args: [258][]const u8 = undefined;
    const argv = machineArgs(&args, rerun.argv);
    const run = try std.process.run(arena.allocator(), ws.io, .{ .argv = argv, .environ_map = rerun.environ, .stdout_limit = .limited(1 << 27), .stderr_limit = .limited(1 << 24) });
    const err = ctx.runtime.err;
    try err.writer.writeAll(run.stderr);
    if (run.term != .exited) return ctx.fail(.io, "The isolated watched check was interrupted.", "Run the check again.");
    if (run.term.exited > 1) return ctx.fail(.io, "The isolated watched check failed; see its diagnostic above.", "Correct the baseline or check options and restart watch.");
    const result = try std.json.parseFromSliceLeaky(Envelope, arena.allocator(), run.stdout, .{ .ignore_unknown_fields = true });
    for (result.findings) |row| try ws.rows.add(row);
    ws.review = .{ .new = result.summary.new, .existing = result.summary.existing, .resolved = result.summary.resolved, .matching = result.pagination.matching_total, .next = result.pagination.next_offset };
    try ws.history.describeChanges(&ws.text, ws.rows.items());
    try triage.selectRows(ws, options, &.{});
    ctx.status = if (run.term.exited == 1) .failure else .success;
    const agent = @import("watch.zig").agentOutput(ws.args, ws.chose_format, options.agent);
    try triage.renderOutput(ctx, ws, options, agent);
}

fn machineArgs(buffer: [][]const u8, original: []const []const u8) []const []const u8 {
    if (buffer.len < original.len + 1) assert.panic("machine argument capacity {d} is below {d}", .{ buffer.len, original.len + 1 });
    if (original.len == 0) assert.panic("isolated command is empty", .{});
    var count: usize = 0;
    var skip = false;
    for (original) |arg| {
        if (skip) {
            skip = false;
            continue;
        }
        if (reportValueFlag(arg)) {
            skip = true;
            continue;
        }
        if (omitReportFlag(arg)) continue;
        buffer[count] = arg;
        count += 1;
    }
    buffer[count] = "--json";
    return buffer[0 .. count + 1];
}

fn reportValueFlag(arg: []const u8) bool {
    if (arg.len == 0) assert.panic("isolated argument is empty", .{});
    if (arg.len > 1 << 20) assert.panic("isolated argument has {d} bytes", .{arg.len});
    for ([_][]const u8{ "--rule", "--file", "--classification", "--page-size", "--offset" }) |flag| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

fn omitReportFlag(arg: []const u8) bool {
    if (arg.len == 0) assert.panic("report argument is empty", .{});
    if (arg.len > 1 << 20) assert.panic("report argument has {d} bytes", .{arg.len});
    for ([_][]const u8{ "--agent", "--json", "--plain", "--triage", "--rule=", "--file=", "--classification=", "--page-size=", "--offset=" }) |prefix| if (std.mem.startsWith(u8, arg, prefix)) return true;
    return false;
}

test "isolated checks preserve analysis flags and remove display filters" {
    var buffer: [32][]const u8 = undefined;
    const args = machineArgs(&buffer, &.{ "zanity", "check", ".", "--baseline", "b.json", "--rules", "assertion-message", "--fix", "--agent=false", "--triage", "--page-size", "20", "--offset=5", "--classification", "new" });
    const expected = [_][]const u8{ "zanity", "check", ".", "--baseline", "b.json", "--rules", "assertion-message", "--fix", "--json" };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |want, got| try std.testing.expectEqualStrings(want, got);
}
