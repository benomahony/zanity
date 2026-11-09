//! The fix for a job that releases or deploys ungated, and the edit that makes it where the change
//! is mechanical: a condition that lets the job past a failed need, or a missing need on the one
//! job that runs the checks.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const strings = @import("strings.zig");
const release = @import("release.zig");
const Edit = @import("facts.zig").Edit;
const Job = release.Job;
const Workflow = release.Workflow;

/// The deepest indent an edit writes; a deeper workflow gets the message without an edit.
const max_indent = 64;
const spaces: [max_indent]u8 = @splat(' ');

/// A finding's fix: what to change, and the edit that changes it when zanity can make it exactly.
pub const Fixed = struct { text: []const u8, edit: ?Edit };

/// The fix for `job`: the need its condition lets it past, else the job that runs the checks to
/// need, else running the tests in a job first. Only the first two can be edits.
pub fn fix(text: *memory.Text, workflow: *const Workflow, job: *const Job) !Fixed {
    if (job.release == null and job.deploy == null) assert.panic("writing a release fix for job '{s}', which releases and deploys nothing", .{job.id});
    // The lines were read without their carriage returns, so an edit could split one from its newline.
    const editable = std.mem.indexOfScalar(u8, workflow.source, '\r') == null;
    for (job.needed()) |need| {
        if (workflow.find(need) == null or release.holds(job.condition, need)) continue;
        return .{
            .text = try text.format("Its 'if: {s}' runs it after '{s}' fails; add '&& needs.{s}.result == 'success'' to it.", .{ strings.header(job.condition), need, need }),
            .edit = if (editable) try conditionEdit(text, workflow, job, need) else null,
        };
    }
    var gate: ?*const Job = null;
    var gates: usize = 0;
    for (workflow.jobs[0..workflow.len]) |*other| if (other != job and other.checks()) {
        if (gate == null) gate = other;
        gates += 1;
    };
    if (gate) |other| return .{
        .text = try text.format("Add 'needs: {s}' to job '{s}', so it runs only after '{s}' passes.", .{ other.id, job.id, other.id }),
        .edit = if (editable and gates == 1) try needsEdit(text, workflow, job, other.id) else null,
    };
    if (workflow.len == 0) assert.panic("writing a release fix for job '{s}' in a workflow with no jobs", .{job.id});
    return .{ .text = try text.format("Run the tests in a job of this workflow, such as one calling the CI workflow with 'uses: ./.github/workflows/<ci>.yml', and add 'needs: <that job>' to job '{s}'.", .{job.id}), .edit = null };
}

/// Adds `&& needs.<need>.result == 'success'` to the job's condition: at its end when inline,
/// inside a `${{ }}` or double quotes that close it, or as a new last line of a block scalar.
fn conditionEdit(text: *memory.Text, workflow: *const Workflow, job: *const Job, need: []const u8) !?Edit {
    if (need.len == 0) assert.panic("adding an empty need to the condition of job '{s}'; addNeed() drops empty names", .{job.id});
    if (release.holds(job.condition, need)) assert.panic("asked to require '{s}' in the condition of job '{s}', which already holds it: '{s}'", .{ need, job.id, job.condition });
    const condition = job.condition;
    if (condition.len == 0) return null;
    const start = at(workflow, condition);
    const required = try text.format("&& needs.{s}.result == 'success'", .{need});
    if (job.condition_block) {
        const indent = start - lineStart(workflow.source, start);
        if (indent > max_indent) return null;
        return insertion(start + @as(u32, @intCast(condition.len)), try text.format("\n{s}{s}", .{ spaces[0..indent], required }));
    }
    if (condition[0] == '\'') return null;
    var end = condition.len;
    if (std.mem.endsWith(u8, condition, "}}")) end -= 2 else if (condition[0] == '"' and condition.len > 1 and condition[end - 1] == '"') end -= 1;
    while (end > 0 and condition[end - 1] == ' ') end -= 1;
    if (end == 0) return null;
    return insertion(start + @as(u32, @intCast(end)), try text.format(" {s}", .{required}));
}

/// Adds `need` to the job's needs: to an inline list or value, as a new item of a block list, or
/// as a new `needs:` straight after the job's key.
fn needsEdit(text: *memory.Text, workflow: *const Workflow, job: *const Job, need: []const u8) !?Edit {
    if (need.len == 0) assert.panic("adding an empty need to job '{s}'; every job has an id", .{job.id});
    if (job.key_line.len == 0) assert.panic("job '{s}' has no key line; addJob() records it", .{job.id});
    if (job.needs_last.len > 0) {
        const indent = std.mem.indexOfNone(u8, job.needs_last, " ") orelse return null;
        if (indent > max_indent) return null;
        return insertion(at(workflow, job.needs_last) + @as(u32, @intCast(job.needs_last.len)), try text.format("\n{s}- {s}", .{ spaces[0..indent], need }));
    }
    const value = job.needs_value;
    if (value.len > 0) {
        const start = at(workflow, value);
        if (value[0] != '[') return .{ .start = start, .end = start + @as(u32, @intCast(value.len)), .replacement = try text.format("[{s}, {s}]", .{ value, need }) };
        const close = std.mem.lastIndexOfScalar(u8, value, ']') orelse return null;
        return insertion(start + @as(u32, @intCast(close)), try text.format(", {s}", .{need}));
    }
    const indent = job.key_indent orelse return null;
    if (indent > max_indent) return null;
    return insertion(at(workflow, job.key_line) + @as(u32, @intCast(job.key_line.len)), try text.format("\n{s}needs: {s}", .{ spaces[0..indent], need }));
}

fn insertion(offset: u32, replacement: []const u8) Edit {
    if (replacement.len == 0) assert.panic("inserting nothing at byte {d}; an edit must change the file", .{offset});
    const edit: Edit = .{ .start = offset, .end = offset, .replacement = replacement };
    if (edit.end < edit.start) assert.panic("an insertion at byte {d} ends before it starts", .{offset});
    return edit;
}

/// The byte offset of `slice` in the workflow's source, which it must point into.
fn at(workflow: *const Workflow, slice: []const u8) u32 {
    const base = @intFromPtr(workflow.source.ptr);
    const from = @intFromPtr(slice.ptr);
    if (from < base or from + slice.len > base + workflow.source.len) assert.panic("'{s}' is not part of {s}'s source; only slices of the parsed source can be edited", .{ slice, workflow.path });
    if (from - base > std.math.maxInt(u32)) assert.panic("{s} is past the 4 GiB an edit can address", .{workflow.path});
    return @intCast(from - base);
}

fn lineStart(source: []const u8, offset: u32) u32 {
    if (offset > source.len) assert.panic("looking for the start of the line at byte {d} of a {d}-byte source", .{ offset, source.len });
    const start: u32 = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| @intCast(newline + 1) else 0;
    if (start > offset) assert.panic("the line at byte {d} starts after it, at {d}", .{ offset, start });
    return start;
}
