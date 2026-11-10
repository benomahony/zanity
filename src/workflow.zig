//! The parse of one GitHub Actions workflow: its jobs, what each needs and ships, and whether a
//! job's condition holds when a job it needs fails.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Calls = @import("workflow_calls.zig").Calls;
const command_window_bytes = @import("release_text.zig").command_window_bytes;
const squeeze = @import("release_text.zig").squeeze;

/// The most jobs one workflow may define for its release gates to be checked.
pub const max_jobs = 64;

/// The most jobs one job may need.
pub const max_needs = 16;

/// Status functions that let a job run after a job it needs has failed.
const failure_tolerant = [_][]const u8{ "always()", "failure()", "cancelled()" };

/// Where a job ships, and the command, action or workflow that does it; for a deploy to a
/// production `environment:`, `text` is the environment's name.
pub const Shipment = struct { row: u32, column: u32, text: []const u8, environment: bool = false };

pub const Job = struct {
    id: []const u8,
    /// The line of the job's key, and that whole line in the workflow's source.
    row: u32,
    key_line: []const u8,
    key_indent: ?usize = null,
    needs: [max_needs][]const u8 = undefined,
    needs_len: u8 = 0,
    /// An inline `needs:` value as written, such as `test` or `[lint, test]`, or the last line of a
    /// block `needs:` list; both are slices of the workflow's source.
    needs_value: []const u8 = "",
    needs_last: []const u8 = "",
    /// The job's `if:` condition, a slice of the workflow's source, and whether a block scalar holds it.
    condition: []const u8 = "",
    condition_block: bool = false,
    /// Whether the job calls a reusable workflow that runs the checks.
    calls_checks: bool = false,
    first_check: ?u32 = null,
    release: ?Shipment = null,
    deploy: ?Shipment = null,
    /// The image_action step still being read, which releases once its `with:` sets `push`, and
    /// the indent of its first line, where the next step starts.
    image_step: ?Shipment = null,
    image_indent: usize = 0,

    pub fn needed(self: *const Job) []const []const u8 {
        if (self.id.len == 0) assert.panic("listing the needs of a job with no id; addJob() names every job", .{});
        if (self.needs_len > max_needs) assert.panic("job '{s}' records {d} needs past its {d} slots; addNeed() must refuse the extra", .{ self.id, self.needs_len, max_needs });
        return self.needs[0..self.needs_len];
    }

    pub fn addNeed(self: *Job, name: []const u8) !void {
        if (self.id.len == 0) assert.panic("adding need '{s}' to a job with no id; addJob() names every job", .{name});
        const id = std.mem.trim(u8, name, " \t\"'");
        if (id.len == 0) return;
        if (self.needs_len == max_needs) {
            memory.exceeded = "jobs one GitHub Actions job needs";
            return error.LimitExceeded;
        }
        self.needs[self.needs_len] = id;
        self.needs_len += 1;
        if (!std.mem.eql(u8, self.needed()[self.needs_len - 1], id)) assert.panic("job '{s}' added need '{s}' but its last need is '{s}'", .{ self.id, id, self.needed()[self.needs_len - 1] });
    }

    pub fn checks(self: *const Job) bool {
        if (self.id.len == 0) assert.panic("asked whether a job with no id runs the checks; parse() names every job", .{});
        if (self.first_check) |row| if (row < self.row) assert.panic("job '{s}' at line {d} records a check at line {d}, before the job starts", .{ self.id, self.row + 1, row + 1 });
        return self.calls_checks or self.first_check != null;
    }
};

/// The parse of one workflow: its jobs, and the block a multi-line value is still being read for.
pub const Workflow = struct {
    /// The workflow's path and source, which every job's slices point into.
    path: []const u8,
    source: []const u8,
    /// What the project's workflows do, for the jobs that call them.
    calls: *const Calls,
    jobs: [max_jobs]Job = undefined,
    len: usize = 0,
    in_jobs: bool = false,
    in_on: bool = false,
    on_indent: ?usize = null,
    /// Whether `on:` lists workflow_call, and whether it lists any other event.
    called: bool = false,
    triggered: bool = false,
    job_indent: ?usize = null,
    /// The indent of the `run:` or `if:` key whose block scalar the following lines continue.
    block_indent: ?usize = null,
    block_is_condition: bool = false,
    needs_indent: ?usize = null,
    /// The indent of a job's `environment:` key whose `name:` the following lines may give.
    environment_indent: ?usize = null,

    pub fn current(self: *Workflow) ?*Job {
        if (self.len > max_jobs) assert.panic("parsed {d} jobs past the {d} slots; addJob() must refuse the extra", .{ self.len, max_jobs });
        if (self.len == 0) return null;
        if (self.jobs[self.len - 1].id.len == 0) assert.panic("job {d} of the workflow has no id; addJob() names every job", .{self.len});
        return &self.jobs[self.len - 1];
    }

    pub fn addJob(self: *Workflow, id: []const u8, key_line: []const u8, row: u32) !void {
        if (id.len == 0) assert.panic("a job key at line {d} has no name; line() passes only keys before a colon", .{row + 1});
        if (self.len == max_jobs) {
            memory.exceeded = "jobs in one GitHub Actions workflow";
            return error.LimitExceeded;
        }
        self.jobs[self.len] = .{ .id = std.mem.trim(u8, id, "\"'"), .row = row, .key_line = key_line };
        self.len += 1;
        self.block_indent = null;
        self.needs_indent = null;
        self.environment_indent = null;
        if (self.current() == null) assert.panic("added job '{s}' but the workflow has no current job", .{id});
    }

    pub fn find(self: *const Workflow, id: []const u8) ?usize {
        if (id.len == 0) assert.panic("looking up a job with an empty id; addNeed() drops empty names", .{});
        if (self.len > max_jobs) assert.panic("looking up '{s}' among {d} jobs past the {d} slots", .{ id, self.len, max_jobs });
        for (self.jobs[0..self.len], 0..) |job, i| if (std.mem.eql(u8, job.id, id)) return i;
        return null;
    }
};

/// Whether a job with `condition` stops when `need` fails: it does unless a status function lets
/// it run after a failure without also requiring that need, or every need, to have succeeded.
pub fn holds(condition: []const u8, need: []const u8) bool {
    if (need.len == 0) assert.panic("checking a condition against a need with no name; addNeed() drops empty names", .{});
    var buffer: [command_window_bytes]u8 = undefined;
    const squeezed = squeeze(&buffer, condition);
    var tolerant = false;
    for (failure_tolerant) |status| tolerant = tolerant or std.mem.indexOf(u8, squeezed, status) != null;
    if (!tolerant) return true;
    var wanted: [command_window_bytes]u8 = undefined;
    const required = std.fmt.bufPrint(&wanted, "needs.{s}.result=='success'", .{need}) catch return false;
    if (required.len <= need.len) assert.panic("the requirement for '{s}' came out shorter than the name", .{need});
    return std.mem.indexOf(u8, squeezed, required) != null or std.mem.indexOf(u8, squeezed, "!contains(needs.*.result,'failure')") != null;
}
