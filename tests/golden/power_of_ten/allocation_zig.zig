const std = @import("std");

const Buffer = struct {
    items: std.ArrayList(u8),
    storage: []u8,

    fn init(gpa: std.mem.Allocator, capacity: usize) !Buffer {
        const storage = try gpa.alloc(u8, capacity);
        return .{ .items = try std.ArrayList(u8).initCapacity(gpa, capacity), .storage = storage };
    }

    fn add(self: *Buffer, gpa: std.mem.Allocator, byte: u8) !void {
        try self.items.append(gpa, byte);
    }

    fn addBounded(self: *Buffer, byte: u8) !void {
        if (self.items.items.len == self.items.capacity) return error.BufferFull;
        self.items.appendAssumeCapacity(byte);
    }

    fn describe(gpa: std.mem.Allocator, value: u32) ![]u8 {
        return std.fmt.allocPrint(gpa, "{d}", .{value});
    }

    fn describeInto(buffer: []u8, value: u32) ![]u8 {
        return std.fmt.bufPrint(buffer, "{d}", .{value});
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    const names = try gpa.alloc([]const u8, 16);
    _ = names;
}
