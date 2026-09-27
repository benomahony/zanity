const std = @import("std");
const assert = std.debug.assert;
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
    edges: u32 = 1 << 21,
    tree_bytes: usize = 1 << 29,
    query_bytes: usize = 1 << 26,
};

pub var exceeded: []const u8 = "";

pub fn Bounded(comptime T: type) type {
    comptime assert(@sizeOf(T) > 0);
    comptime assert(@alignOf(T) > 0);
    return struct {
        const Self = @This();

        buffer: []T,
        len: usize = 0,
        what: []const u8,

        pub fn initBounded(gpa: Allocator, capacity: usize, what: []const u8) Allocator.Error!Self {
            assert(capacity > 0);
            assert(what.len > 0);
            return .{ .buffer = try gpa.alloc(T, capacity), .what = what };
        }

        pub fn add(self: *Self, item: T) error{LimitExceeded}!void {
            assert(self.len <= self.buffer.len);
            if (self.len == self.buffer.len) {
                exceeded = self.what;
                return error.LimitExceeded;
            }
            self.buffer[self.len] = item;
            self.len += 1;
            assert(self.len <= self.buffer.len);
        }

        pub fn items(self: *const Self) []T {
            assert(self.len <= self.buffer.len);
            assert(self.buffer.len > 0);
            return self.buffer[0..self.len];
        }

        pub fn last(self: *const Self) ?*T {
            assert(self.len <= self.buffer.len);
            if (self.len == 0) return null;
            assert(self.buffer.len > 0);
            return &self.buffer[self.len - 1];
        }

        pub fn drop(self: *Self) ?T {
            assert(self.len <= self.buffer.len);
            if (self.len == 0) return null;
            self.len -= 1;
            assert(self.len < self.buffer.len);
            return self.buffer[self.len];
        }

        pub fn clear(self: *Self) void {
            assert(self.len <= self.buffer.len);
            self.len = 0;
            assert(self.items().len == 0);
        }
    };
}

pub const Text = struct {
    buffer: []u8,
    used: usize = 0,

    pub fn initText(gpa: Allocator, capacity: usize) Allocator.Error!Text {
        assert(capacity > 0);
        const buffer = try gpa.alloc(u8, capacity);
        assert(buffer.len == capacity);
        return .{ .buffer = buffer };
    }

    pub fn format(self: *Text, comptime fmt: []const u8, args: anytype) error{LimitExceeded}![]const u8 {
        assert(self.used <= self.buffer.len);
        const written = std.fmt.bufPrint(self.buffer[self.used..], fmt, args) catch {
            exceeded = "bytes of message text";
            return error.LimitExceeded;
        };
        self.used += written.len;
        assert(self.used <= self.buffer.len);
        return written;
    }

    pub fn copy(self: *Text, bytes: []const u8) error{LimitExceeded}![]const u8 {
        assert(self.used <= self.buffer.len);
        if (self.buffer.len - self.used < bytes.len) {
            exceeded = "bytes of names and paths";
            return error.LimitExceeded;
        }
        const out = self.buffer[self.used .. self.used + bytes.len];
        @memcpy(out, bytes);
        self.used += bytes.len;
        assert(std.mem.eql(u8, out, bytes));
        return out;
    }
};

const header = 16;

pub const Pool = struct {
    buffer: []align(header) u8,
    used: usize = 0,
    last: usize = 0,
    what: []const u8,

    pub fn initPool(gpa: Allocator, capacity: usize, what: []const u8) Allocator.Error!Pool {
        assert(capacity % header == 0);
        assert(what.len > 0);
        return .{ .buffer = try gpa.alignedAlloc(u8, .fromByteUnits(header), capacity), .what = what };
    }

    fn take(self: *Pool, size: usize) ?[*]u8 {
        assert(self.used % header == 0);
        const rounded = std.mem.alignForward(usize, size, header) + header;
        if (self.buffer.len - self.used < rounded) {
            exceeded = self.what;
            return null;
        }
        std.mem.writeInt(usize, self.buffer[self.used..][0..@sizeOf(usize)], size, .little);
        self.last = self.used;
        self.used += rounded;
        assert(self.used <= self.buffer.len);
        return self.buffer.ptr + self.last + header;
    }

    fn sizeOf(self: *const Pool, ptr: [*]u8) usize {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buffer.ptr) - header;
        assert(offset < self.used);
        assert(offset % header == 0);
        return std.mem.readInt(usize, self.buffer[offset..][0..@sizeOf(usize)], .little);
    }

    fn release(self: *Pool, ptr: [*]u8) void {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buffer.ptr) - header;
        assert(offset < self.used);
        if (offset == self.last) self.used = self.last;
        assert(self.used <= self.buffer.len);
    }

    fn owns(self: *const Pool, ptr: [*]u8) bool {
        const address = @intFromPtr(ptr);
        const start = @intFromPtr(self.buffer.ptr);
        assert(self.buffer.len > 0);
        assert(start % header == 0);
        return address >= start and address < start + self.buffer.len;
    }

    pub fn reset(self: *Pool) void {
        assert(self.used <= self.buffer.len);
        self.used = 0;
        self.last = 0;
        assert(self.used == 0);
    }
};

pub var tree_pool: ?*Pool = null;

fn active() *Pool {
    const pool = tree_pool orelse unreachable;
    assert(pool.buffer.len > 0);
    assert(pool.used <= pool.buffer.len);
    return pool;
}

export fn zanityMalloc(size: usize) ?*anyopaque {
    assert(size < std.math.maxInt(u32));
    const ptr = active().take(size);
    assert(ptr == null or @intFromPtr(ptr.?) % header == 0);
    return ptr;
}

export fn zanityCalloc(count: usize, size: usize) ?*anyopaque {
    const total = count * size;
    assert(count == 0 or total / count == size);
    assert(total < std.math.maxInt(u32));
    const ptr = active().take(total) orelse return null;
    @memset(ptr[0..total], 0);
    return ptr;
}

export fn zanityRealloc(old: ?*anyopaque, size: usize) ?*anyopaque {
    const pool = active();
    const previous: [*]u8 = @ptrCast(old orelse return pool.take(size));
    assert(pool.owns(previous));
    const previous_size = pool.sizeOf(previous);
    const fresh = pool.take(size) orelse return null;
    @memcpy(fresh[0..@min(size, previous_size)], previous[0..@min(size, previous_size)]);
    assert(fresh != previous);
    return fresh;
}

export fn zanityFree(ptr: ?*anyopaque) void {
    const pool = active();
    const bytes: [*]u8 = @ptrCast(ptr orelse return);
    assert(pool.owns(bytes));
    pool.release(bytes);
    assert(pool.used <= pool.buffer.len);
}

test "bounded containers refuse to grow past their limit" {
    var numbers = try Bounded(u32).initBounded(std.testing.allocator, 2, "numbers");
    defer std.testing.allocator.free(numbers.buffer);
    try numbers.add(1);
    try numbers.add(2);
    try std.testing.expectError(error.LimitExceeded, numbers.add(3));
    try std.testing.expectEqualStrings("numbers", exceeded);
    try std.testing.expectEqual(@as(?u32, 2), numbers.drop());
}

test "the pool hands out, grows and reclaims memory without an allocator" {
    var pool = try Pool.initPool(std.testing.allocator, 4096, "tree bytes");
    defer std.testing.allocator.free(pool.buffer);
    tree_pool = &pool;
    defer tree_pool = null;
    const a: [*]u8 = @ptrCast(zanityMalloc(10).?);
    @memcpy(a[0..10], "0123456789");
    const b: [*]u8 = @ptrCast(zanityRealloc(a, 20).?);
    try std.testing.expectEqualStrings("0123456789", b[0..10]);
    zanityFree(b);
    try std.testing.expectEqual(pool.last, pool.used);
    try std.testing.expectEqual(@as(?*anyopaque, null), zanityMalloc(1 << 20));
}
