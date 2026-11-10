//! What each workflow file of a project does, as far as the workflows calling it need to know,
//! shared by release.zig and release_calls.zig.
const std = @import("std");
const assert = @import("assert.zig");

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
