const std = @import("std");
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
    ignore_patterns: u32 = 1 << 14,
    ignore_bytes: u32 = 1 << 20,
    store_bytes: usize = 1 << 25,
    judgement_bytes: u32 = 1 << 26,
};

pub var exceeded: []const u8 = "";

pub fn Bounded(comptime T: type) type {
    comptime if (@sizeOf(T) == 0) @compileError("Bounded(" ++ @typeName(T) ++ ") holds a zero-sized type; it needs no storage, so count items instead");
    comptime if (@alignOf(T) == 0) @compileError("Bounded(" ++ @typeName(T) ++ ") has zero alignment, which Zig types never have");
    return struct {
        const Self = @This();

        buffer: []T,
        len: usize = 0,
        what: []const u8,

        pub fn initBounded(gpa: Allocator, capacity: usize, what: []const u8) Allocator.Error!Self {
            if (capacity == 0) std.debug.panic("Bounded buffer for {s} was given capacity 0; check the matching field in memory.Limits", .{what});
            if (what.len == 0) std.debug.panic("Bounded buffer of capacity {d} has no description; pass what it holds so a full buffer can say which limit to raise", .{capacity});
            return .{ .buffer = try gpa.alloc(T, capacity), .what = what };
        }

        pub fn add(self: *Self, item: T) error{LimitExceeded}!void {
            if (self.len > self.buffer.len) std.debug.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.len == self.buffer.len) {
                exceeded = self.what;
                return error.LimitExceeded;
            }
            self.buffer[self.len] = item;
            self.len += 1;
            if (self.len > self.buffer.len) std.debug.panic("{s}: add() left {d} items in {d} slots; add() must refuse to add past the buffer", .{ self.what, self.len, self.buffer.len });
        }

        pub fn items(self: *const Self) []T {
            if (self.len > self.buffer.len) std.debug.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.buffer.len == 0) std.debug.panic("{s}: the buffer was never allocated; call initBounded before items()", .{self.what});
            return self.buffer[0..self.len];
        }

        pub fn last(self: *const Self) ?*T {
            if (self.len > self.buffer.len) std.debug.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.len == 0) return null;
            if (self.buffer.len == 0) std.debug.panic("{s}: holds {d} items in an unallocated buffer; call initBounded first", .{ self.what, self.len });
            return &self.buffer[self.len - 1];
        }

        pub fn drop(self: *Self) ?T {
            if (self.len > self.buffer.len) std.debug.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            if (self.len == 0) return null;
            self.len -= 1;
            if (self.len >= self.buffer.len) std.debug.panic("{s}: drop() left {d} items in {d} slots; drop() must take one item off", .{ self.what, self.len, self.buffer.len });
            return self.buffer[self.len];
        }

        pub fn clear(self: *Self) void {
            if (self.len > self.buffer.len) std.debug.panic("{s}: {d} items recorded but only {d} slots exist; something set len without add()", .{ self.what, self.len, self.buffer.len });
            self.len = 0;
            if (self.items().len != 0) std.debug.panic("{s}: clear() left {d} items; clear() must set len to 0", .{ self.what, self.items().len });
        }
    };
}

pub const Text = struct {
    buffer: []u8,
    used: usize = 0,

    pub fn initText(gpa: Allocator, capacity: usize) Allocator.Error!Text {
        if (capacity == 0) std.debug.panic("Text buffer was given capacity 0; check memory.Limits.text_bytes", .{});
        const buffer = try gpa.alloc(u8, capacity);
        if (buffer.len != capacity) std.debug.panic("Text buffer: asked for {d} bytes, the allocator returned {d}; check the allocator passed to initText()", .{ capacity, buffer.len });
        return .{ .buffer = buffer };
    }

    pub fn format(self: *Text, comptime fmt: []const u8, args: anytype) error{LimitExceeded}![]const u8 {
        if (self.used > self.buffer.len) std.debug.panic("Text buffer: {d} bytes marked used out of {d}; something moved used past the end", .{ self.used, self.buffer.len });
        const written = std.fmt.bufPrint(self.buffer[self.used..], fmt, args) catch {
            exceeded = "bytes of message text";
            return error.LimitExceeded;
        };
        self.used += written.len;
        if (self.used > self.buffer.len) std.debug.panic("Text buffer: format() left {d} bytes used out of {d}; format() must refuse to write past the buffer", .{ self.used, self.buffer.len });
        return written;
    }

    pub fn copy(self: *Text, bytes: []const u8) error{LimitExceeded}![]const u8 {
        if (self.used > self.buffer.len) std.debug.panic("Text buffer: {d} bytes marked used out of {d}; something moved used past the end, so only copy() and format() may move used forward", .{ self.used, self.buffer.len });
        if (self.buffer.len - self.used < bytes.len) {
            exceeded = "bytes of names and paths";
            return error.LimitExceeded;
        }
        const out = self.buffer[self.used .. self.used + bytes.len];
        @memcpy(out, bytes);
        self.used += bytes.len;
        if (!std.mem.eql(u8, out, bytes)) std.debug.panic("Text buffer: copied '{s}' but the buffer holds '{s}'; the source overlaps the buffer, so copy from outside the buffer, or use the slice already in it", .{ bytes, out });
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
        if (capacity % header != 0) std.debug.panic("Pool for {s}: capacity {d} is not a multiple of the {d}-byte header; round memory.Limits up", .{ what, capacity, header });
        if (what.len == 0) std.debug.panic("Pool of {d} bytes has no description; pass what it holds so running out can say which limit to raise", .{capacity});
        return .{ .buffer = try gpa.alignedAlloc(u8, .fromByteUnits(header), capacity), .what = what };
    }

    fn take(self: *Pool, size: usize) ?[*]u8 {
        if (self.used % header != 0) std.debug.panic("Pool for {s}: {d} bytes used is not header-aligned ({d}); take() must round every allocation", .{ self.what, self.used, header });
        const rounded = std.mem.alignForward(usize, size, header) + header;
        if (self.buffer.len - self.used < rounded) {
            exceeded = self.what;
            return null;
        }
        std.mem.writeInt(usize, self.buffer[self.used..][0..@sizeOf(usize)], size, .little);
        self.last = self.used;
        self.used += rounded;
        if (self.used > self.buffer.len) std.debug.panic("Pool for {s}: take() used {d} of {d} bytes; take() must refuse to hand out past the buffer", .{ self.what, self.used, self.buffer.len });
        return self.buffer.ptr + self.last + header;
    }

    fn sizeOf(self: *const Pool, ptr: [*]u8) usize {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buffer.ptr) - header;
        if (offset >= self.used) std.debug.panic("Pool for {s}: pointer at offset {d} is past the {d} bytes handed out; tree-sitter freed or resized memory the pool never gave it", .{ self.what, offset, self.used });
        if (offset % header != 0) std.debug.panic("Pool for {s}: pointer at offset {d} is not at a {d}-byte allocation boundary; it was not returned by take()", .{ self.what, offset, header });
        return std.mem.readInt(usize, self.buffer[offset..][0..@sizeOf(usize)], .little);
    }

    fn release(self: *Pool, ptr: [*]u8) void {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buffer.ptr) - header;
        if (offset >= self.used) std.debug.panic("Pool for {s}: freeing offset {d}, past the {d} bytes handed out; a pointer was freed twice or came from another allocator", .{ self.what, offset, self.used });
        if (offset == self.last) self.used = self.last;
        if (self.used > self.buffer.len) std.debug.panic("Pool for {s}: release() left {d} of {d} bytes used; release() must free the most recent block only", .{ self.what, self.used, self.buffer.len });
    }

    fn owns(self: *const Pool, ptr: [*]u8) bool {
        const address = @intFromPtr(ptr);
        const start = @intFromPtr(self.buffer.ptr);
        if (self.buffer.len == 0) std.debug.panic("Pool for {s} was never allocated; call initPool first", .{self.what});
        if (start % header != 0) std.debug.panic("Pool for {s}: buffer starts at 0x{x}, not {d}-byte aligned; allocate it with alignedAlloc", .{ self.what, start, header });
        return address >= start and address < start + self.buffer.len;
    }

    pub fn reset(self: *Pool) void {
        if (self.used > self.buffer.len) std.debug.panic("Pool for {s}: {d} bytes used of {d} before reset; only alloc() may move used forward, and never past the buffer", .{ self.what, self.used, self.buffer.len });
        self.used = 0;
        self.last = 0;
        if (self.used != 0) std.debug.panic("Pool for {s}: reset() left {d} bytes used; reset() must set used to 0", .{ self.what, self.used });
    }
};

pub var tree_pool: ?*Pool = null;

fn active() *Pool {
    const pool = tree_pool orelse unreachable;
    if (pool.buffer.len == 0) std.debug.panic("the tree-sitter pool was installed without a buffer; call initPool before parsing", .{});
    if (pool.used > pool.buffer.len) std.debug.panic("the tree-sitter pool reports {d} bytes used of {d}; only the pool's own functions may move used forward", .{ pool.used, pool.buffer.len });
    return pool;
}

export fn zanityMalloc(size: usize) ?*anyopaque {
    if (size >= std.math.maxInt(u32)) std.debug.panic("tree-sitter asked for {d} bytes, more than a 4 GiB file could need; the parse state is corrupt", .{size});
    const ptr = active().take(size);
    if (ptr != null and @intFromPtr(ptr.?) % header != 0) std.debug.panic("zanityMalloc returned 0x{x}, not {d}-byte aligned; zanityMalloc() must round each block up to the alignment", .{ @intFromPtr(ptr.?), header });
    return ptr;
}

export fn zanityCalloc(count: usize, size: usize) ?*anyopaque {
    const total = count * size;
    if (count != 0 and total / count != size) std.debug.panic("tree-sitter asked for {d} x {d} bytes, which overflows; the input is too large to parse, so lower memory.Limits.file_bytes", .{ count, size });
    if (total >= std.math.maxInt(u32)) std.debug.panic("tree-sitter asked for {d} x {d} = {d} bytes, more than a 4 GiB file could need; lower memory.Limits.file_bytes, or check the tree-sitter version in vendor/tree-sitter/REVISION", .{ count, size, total });
    const ptr = active().take(total) orelse return null;
    @memset(ptr[0..total], 0);
    return ptr;
}

export fn zanityRealloc(old: ?*anyopaque, size: usize) ?*anyopaque {
    const pool = active();
    const previous: [*]u8 = @ptrCast(old orelse return pool.take(size));
    if (!pool.owns(previous)) std.debug.panic("tree-sitter resized 0x{x}, which the pool did not allocate; it came from another allocator, so install the pool with ts_set_allocator before any parse", .{@intFromPtr(previous)});
    const previous_size = pool.sizeOf(previous);
    const fresh = pool.take(size) orelse return null;
    @memcpy(fresh[0..@min(size, previous_size)], previous[0..@min(size, previous_size)]);
    if (fresh == previous) std.debug.panic("zanityRealloc returned the block it was resizing (0x{x}); take() must hand out new memory", .{@intFromPtr(fresh)});
    return fresh;
}

export fn zanityFree(ptr: ?*anyopaque) void {
    const pool = active();
    const bytes: [*]u8 = @ptrCast(ptr orelse return);
    if (!pool.owns(bytes)) std.debug.panic("tree-sitter freed 0x{x}, which the pool did not allocate; it came from another allocator, so install the pool with ts_set_allocator before any parse", .{@intFromPtr(bytes)});
    pool.release(bytes);
    if (pool.used > pool.buffer.len) std.debug.panic("the tree-sitter pool reports {d} bytes used of {d} after a free; zanityFree() must not move used past the buffer", .{ pool.used, pool.buffer.len });
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
