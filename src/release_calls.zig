//! Release and deploy gates across workflow files: a job calling a local reusable workflow is judged by what
//! that workflow's jobs do, not its file name, and a workflow that only runs when called is judged
//! through its callers.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const release = @import("release.zig");

const Io = std.Io;

/// The most workflow files one project may hold for the calls between them to be followed.
pub const max_workflows = 64;

/// What each workflow file of the project does, as far as the workflows calling it need to know.
pub const Calls = struct {
    paths: [max_workflows][]const u8 = undefined,
    len: usize = 0,
    /// Whether some job of the workflow runs the checks.
    checks: [max_workflows]bool = @splat(false),
    /// Whether the workflow runs only when another workflow calls it.
    call_only: [max_workflows]bool = @splat(false),
    /// Whether the workflow releases from a job the tests do not gate.
    releases: [max_workflows]bool = @splat(false),
    /// Whether the workflow deploys from a job the tests do not gate.
    deploys: [max_workflows]bool = @splat(false),

    /// The project's workflow file a job's `uses:` names, when it names a local one.
    pub fn find(self: *const Calls, uses: []const u8) ?usize {
        if (self.len > max_workflows) assert.panic("{d} workflows recorded past the {d} slots; checkWorkflows() must refuse the extra", .{ self.len, max_workflows });
        if (std.mem.indexOfScalar(u8, uses, '\n') != null) assert.panic("'{s}' spans lines, but a job's uses: value is one line", .{uses});
        if (!std.mem.startsWith(u8, uses, "./")) return null;
        const wanted = uses["./".len..];
        if (wanted.len == 0) return null;
        for (self.paths[0..self.len], 0..) |path, i| {
            if (std.mem.eql(u8, path, wanted)) return i;
            if (path.len > wanted.len and std.mem.endsWith(u8, path, wanted) and path[path.len - wanted.len - 1] == '/') return i;
        }
        return null;
    }
};

/// Which fact of each workflow a settling pass works out.
const Fact = enum { checks, releases, deploys };

/// Reads workflow files into one buffer, a file at a time, as checkProjectFiles reads them.
pub const WorkflowFiles = struct {
    io: Io,
    /// One extra byte beyond the largest accepted file, to detect truncated reads.
    buffer: []u8,

    fn read(self: WorkflowFiles, path: []const u8) ![]const u8 {
        if (path.len == 0) assert.panic("reading a workflow with an empty path; checkWorkflows() keeps only workflow paths", .{});
        const source = try Io.Dir.cwd().readFile(self.io, path, self.buffer);
        if (source.len == self.buffer.len) {
            memory.exceeded = "bytes in one project file";
            return error.LimitExceeded;
        }
        if (source.len > self.buffer.len) assert.panic("read {d} bytes of {s} into a {d}-byte buffer", .{ source.len, path, self.buffer.len });
        return source;
    }
};

/// Reports each release and deploy in the workflows among `paths` that runs without the tests having passed,
/// following each job's calls to the project's own reusable workflows.
pub fn checkWorkflows(files: WorkflowFiles, report: release.Report, paths: []const []const u8) !void {
    if (files.buffer.len == 0) assert.panic("reading workflows into an empty buffer; size it from memory.Limits.file_bytes", .{});
    if (report.findings == null) assert.panic("checking every workflow with nowhere to report; pass the run's findings", .{});
    var calls: Calls = .{};
    for (paths) |path| if (release.isWorkflow(path)) {
        if (calls.len == max_workflows) {
            memory.exceeded = "GitHub Actions workflows in one project";
            return error.LimitExceeded;
        }
        calls.paths[calls.len] = path;
        calls.len += 1;
    };
    // Whether a workflow releases or deploys ungated depends on which workflows run the checks, so
    // the checks settle first and stay fixed while the releases and deploys settle.
    try settle(files, report.text, &calls, .checks);
    try settle(files, report.text, &calls, .releases);
    try settle(files, report.text, &calls, .deploys);
    for (calls.paths[0..calls.len]) |path| _ = try release.checkWorkflow(report, path, try files.read(path), &calls);
    if (calls.len > paths.len) assert.panic("found {d} workflows among {d} paths", .{ calls.len, paths.len });
}

/// Works `fact` out for every workflow, from what the workflows it calls do. A fact only ever turns
/// on, so it stops changing after at most one pass per workflow.
fn settle(files: WorkflowFiles, text: *memory.Text, calls: *Calls, fact: Fact) !void {
    if (calls.len > max_workflows) assert.panic("settling {d} workflows past the {d} slots", .{ calls.len, max_workflows });
    const known = switch (fact) {
        .checks => &calls.checks,
        .releases => &calls.releases,
        .deploys => &calls.deploys,
    };
    var pass: usize = 0;
    while (pass <= calls.len) : (pass += 1) {
        var changed = false;
        for (calls.paths[0..calls.len], 0..) |path, i| {
            const gating = try release.checkWorkflow(.{ .findings = null, .text = text }, path, try files.read(path), calls);
            calls.call_only[i] = gating.call_only;
            const now = switch (fact) {
                .checks => gating.checks,
                .releases => gating.releases,
                .deploys => gating.deploys,
            };
            if (known[i] == now) continue;
            if (!now) assert.panic("{s} stopped having its {s} fact while the workflows it calls only gain theirs", .{ path, @tagName(fact) });
            known[i] = true;
            changed = true;
        }
        if (!changed) return;
    }
    assert.panic("the {s} of {d} workflows still changed after {d} passes; each pass must turn one on or stop", .{ @tagName(fact), calls.len, pass });
}
