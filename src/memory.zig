const std = @import("std");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    files: u32 = 1 << 16,
    file_bytes: u32 = 1 << 22,
    captures: u32 = 1 << 21,
    depth: u32 = 1 << 12,
    per_file: u32 = 1 << 16,
    findings: u32 = 1 << 18,
    text_bytes: u32 = 1 << 26,
    definitions: u32 = 1 << 18,
    functions: u32 = 1 << 18,
    calls: u32 = 1 << 20,
    /// Distinct names each file refers to, summed over all files, for dead-symbol.
    references: u32 = 1 << 22,
    edges: u32 = 1 << 21,
    ignore_patterns: u32 = 1 << 14,
    ignore_bytes: u32 = 1 << 20,
    store_bytes: usize = 1 << 25,
    judgement_bytes: u32 = 1 << 26,
};

/// Which limit ran out, for the thread whose add() or copy() returned error.LimitExceeded.
pub threadlocal var exceeded: []const u8 = "";

/// Room for `n` items, left as the allocator returned it. `Allocator.alloc` fills memory in Debug
/// builds, touching every page; zanity's buffers are sized for the largest input it accepts, so that
/// fill cost a Debug run 800 MB however little it checked. Callers write each item before reading it.
pub fn reserve(gpa: Allocator, comptime T: type, n: usize) Allocator.Error![]T {
    if (n == 0) assert.panic("reserving no {s}; size the buffer from a memory.Limits field above 0", .{@typeName(T)});
    const bytes = std.math.mul(usize, @sizeOf(T), n) catch return error.OutOfMemory;
    const raw = gpa.rawAlloc(bytes, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    const items = @as([*]T, @ptrCast(@alignCast(raw)))[0..n];
    if (@intFromPtr(items.ptr) % @alignOf(T) != 0) assert.panic("reserved {d} {s} at 0x{x}, not {d}-byte aligned; rawAlloc must honour the alignment it is given", .{ n, @typeName(T), @intFromPtr(items.ptr), @alignOf(T) });
    return items;
}

pub fn Bounded(comptime T: type) type {
    comptime if (@sizeOf(T) == 0) @compileError("Bounded(" ++ @typeName(T) ++ ") holds a zero-sized type; it needs no storage, so count items instead");
    comptime if (@alignOf(T) == 0) @compileError("Bounded(" ++ @typeName(T) ++ ") has zero alignment, which Zig types never have");
    return struct {
        const Self = @This();

        buffer: []T,
        len: usize = 0,
        what: []const u8,

        pub fn initBounded(gpa: Allocator, room: usize, what: []const u8) Allocator.Error!Self {
            if (room == 0) assert.panic("Bounded buffer for {s} was given capacity 0; check the matching field in memory.Limits", .{what});
            if (what.len == 0) assert.panic("Bounded buffer of capacity {d} has no description; pass what it holds so a full buffer can say which limit to raise", .{room});
            return .{ .buffer = try reserve(gpa, T, room), .what = what };
        }

        pub fn add(self: *Self, item: T) error{LimitExceeded}!void {
            if (self.len > self.buffer.len) assert.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.len == self.buffer.len) {
                exceeded = self.what;
                return error.LimitExceeded;
            }
            self.buffer[self.len] = item;
            self.len += 1;
            if (self.len > self.buffer.len) assert.panic("{s}: add() left {d} items in {d} slots; add() must refuse to add past the buffer", .{ self.what, self.len, self.buffer.len });
        }

        /// How many items it has room for.
        pub fn capacity(self: *const Self) usize {
            if (self.buffer.len == 0) assert.panic("{s}: the buffer was never allocated; call initBounded before capacity()", .{self.what});
            if (self.len > self.buffer.len) assert.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            return self.buffer.len;
        }

        pub fn items(self: *const Self) []T {
            if (self.len > self.buffer.len) assert.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.buffer.len == 0) assert.panic("{s}: the buffer was never allocated; call initBounded before items()", .{self.what});
            return self.buffer[0..self.len];
        }

        pub fn last(self: *const Self) ?*T {
            if (self.len > self.buffer.len) assert.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.len == 0) return null;
            if (self.buffer.len == 0) assert.panic("{s}: holds {d} items in an unallocated buffer; call initBounded first", .{ self.what, self.len });
            return &self.buffer[self.len - 1];
        }

        pub fn drop(self: *Self) ?T {
            if (self.len > self.buffer.len) assert.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.len == 0) return null;
            self.len -= 1;
            if (self.len >= self.buffer.len) assert.panic("{s}: drop() left {d} items in {d} slots; drop() must take one item off", .{ self.what, self.len, self.buffer.len });
            return self.buffer[self.len];
        }

        pub fn clear(self: *Self) void {
            if (self.len > self.buffer.len) assert.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            self.len = 0;
            if (self.items().len != 0) assert.panic("{s}: clear() left {d} items; clear() must set len to 0", .{ self.what, self.items().len });
        }
    };
}

pub const Text = struct {
    buffer: []u8,
    used: usize = 0,

    pub fn initText(gpa: Allocator, capacity: usize) Allocator.Error!Text {
        if (capacity == 0) assert.panic("Text buffer was given capacity 0; check memory.Limits.text_bytes", .{});
        const buffer = try reserve(gpa, u8, capacity);
        if (buffer.len != capacity) assert.panic("Text buffer: asked for {d} bytes, the allocator returned {d}; check the allocator passed to initText()", .{ capacity, buffer.len });
        return .{ .buffer = buffer };
    }

    pub fn format(self: *Text, comptime fmt: []const u8, args: anytype) error{LimitExceeded}![]const u8 {
        if (self.used > self.buffer.len) assert.panic("Text buffer: {d} bytes marked used out of {d}; something moved used past the end", .{ self.used, self.buffer.len });
        const written = std.fmt.bufPrint(self.buffer[self.used..], fmt, args) catch {
            exceeded = "bytes of message text";
            return error.LimitExceeded;
        };
        self.used += written.len;
        if (self.used > self.buffer.len) assert.panic("Text buffer: format() left {d} bytes used out of {d}; format() must refuse to write past the buffer", .{ self.used, self.buffer.len });
        return written;
    }

    pub fn copy(self: *Text, bytes: []const u8) error{LimitExceeded}![]const u8 {
        if (self.used > self.buffer.len) assert.panic("Text buffer: {d} bytes marked used out of {d}; something moved used past the end, so only copy() and format() may move used forward", .{ self.used, self.buffer.len });
        if (self.buffer.len - self.used < bytes.len) {
            exceeded = "bytes of names and paths";
            return error.LimitExceeded;
        }
        const out = self.buffer[self.used .. self.used + bytes.len];
        @memcpy(out, bytes);
        self.used += bytes.len;
        if (!std.mem.eql(u8, out, bytes)) assert.panic("Text buffer: copied '{s}' but the buffer holds '{s}'; the source overlaps the buffer, so copy from outside the buffer, or use the slice already in it", .{ bytes, out });
        return out;
    }
};

test "bounded containers refuse to grow past their limit" {
    var numbers = try Bounded(u32).initBounded(std.testing.allocator, 2, "numbers");
    defer std.testing.allocator.free(numbers.buffer);
    try numbers.add(1);
    try numbers.add(2);
    try std.testing.expectError(error.LimitExceeded, numbers.add(3));
    try std.testing.expectEqualStrings("numbers", exceeded);
    try std.testing.expectEqual(@as(?u32, 2), numbers.drop());
}
