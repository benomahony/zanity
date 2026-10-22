const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Row = @import("baseline.zig").Row;

/// One check's new IDs, retained only to describe what changed on the next watched check.
/// This is reporting state, never an acceptance baseline or agent session policy.
pub const History = struct {
    previous: memory.Bounded([64]u8),
    resolved: memory.Bounded([]const u8),
    current: std.AutoHashMapUnmanaged([64]u8, void) = .empty,

    pub fn initHistory(gpa: std.mem.Allocator, capacity: usize) !History {
        if (capacity == 0) assert.panic("history requires a positive finding capacity", .{});
        var history: History = .{
            .previous = try .initBounded(gpa, capacity, "new findings on previous check"),
            .resolved = try .initBounded(gpa, capacity, "new findings resolved since previous check"),
        };
        try history.current.ensureTotalCapacity(gpa, @intCast(capacity));
        if (history.previous.capacity() != capacity) assert.panic("history capacity differs from {d}", .{capacity});
        return history;
    }

    pub fn describeChanges(self: *History, text: *memory.Text, rows: []const Row) !void {
        if (rows.len > 2 * self.previous.capacity()) assert.panic("history input {d} exceeds capacity", .{rows.len});
        if (self.previous.len > self.previous.capacity()) assert.panic("history holds {d} IDs over capacity", .{self.previous.len});
        self.resolved.clear();
        self.current.clearRetainingCapacity();
        for (rows) |row| {
            if (std.mem.eql(u8, row.classification, "resolved")) continue;
            var id: [64]u8 = undefined;
            @memcpy(&id, row.id);
            self.current.putAssumeCapacity(id, {});
        }
        for (self.previous.items()) |id| {
            if (!self.current.contains(id)) try self.resolved.add(try text.copy(&id));
        }
        self.previous.clear();
        for (rows) |row| {
            if (!std.mem.eql(u8, row.classification, "new")) continue;
            var id: [64]u8 = undefined;
            @memcpy(&id, row.id);
            try self.previous.add(id);
        }
    }
};

test "watch resolutions describe previously new IDs without assigning inherited backlog" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var history = try History.initHistory(arena, 4);
    var text = try memory.Text.initText(arena, 4096);
    const inherited: Row = .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .classification = "existing", .path = "a.py", .line = 1, .column = 1, .rule = "assertion-message", .severity = "warning", .message = "inherited", .fix = "fix" };
    var new = inherited;
    new.id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    new.classification = "new";
    try history.describeChanges(&text, &.{ inherited, new });
    try std.testing.expectEqual(@as(usize, 1), history.previous.len);
    try std.testing.expectEqual(@as(usize, 0), history.resolved.len);
    text.used = 0;
    try history.describeChanges(&text, &.{inherited});
    try std.testing.expectEqual(@as(usize, 0), history.previous.len);
    try std.testing.expectEqualStrings(new.id, history.resolved.items()[0]);
    text.used = 0;
    try history.describeChanges(&text, &.{inherited});
    try std.testing.expectEqual(@as(usize, 0), history.resolved.len);
}
