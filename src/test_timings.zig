//! Measured per-test durations from a JUnit XML report. Never executes tests or expands entities.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Finding = @import("facts.zig").Finding;

pub const Case = struct { name: []const u8, seconds: ?f64, line: u32, skipped: bool = false };

const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    closing: bool,
    empty: bool,
    line: u32,
};

pub const Reader = struct {
    source: []const u8,
    offset: usize = 0,
    line: u32 = 0,
    stack: [128][]const u8 = undefined,
    depth: usize = 0,
    current: ?Case = null,
    root_seen: bool = false,

    fn advance(self: *Reader, end: usize) void {
        if (end < self.offset) assert.panic("JUnit reader cannot move from {d} backwards to {d}", .{ self.offset, end });
        if (end > self.source.len) assert.panic("JUnit reader advanced to {d} beyond {d} report bytes", .{ end, self.source.len });
        self.line += @intCast(std.mem.count(u8, self.source[self.offset..end], "\n"));
        self.offset = end;
    }

    fn tag(self: *Reader) !?Tag {
        if (self.offset > self.source.len) assert.panic("JUnit offset {d} exceeds {d} report bytes", .{ self.offset, self.source.len });
        if (self.depth > self.stack.len) assert.panic("JUnit depth {d} exceeds stack {d}", .{ self.depth, self.stack.len });
        while (self.offset < self.source.len) {
            const start = std.mem.indexOfScalarPos(u8, self.source, self.offset, '<') orelse {
                if (std.mem.trim(u8, self.source[self.offset..], " \t\r\n").len != 0 and self.depth == 0) return error.InvalidJUnit;
                self.advance(self.source.len);
                return null;
            };
            if (self.depth == 0 and std.mem.trim(u8, self.source[self.offset..start], " \t\r\n").len != 0) return error.InvalidJUnit;
            self.advance(start);
            const rest = self.source[start..];
            const terminator: ?[]const u8 = if (std.mem.startsWith(u8, rest, "<!--")) "-->" else if (std.mem.startsWith(u8, rest, "<![CDATA[")) "]]>" else if (std.mem.startsWith(u8, rest, "<?")) "?>" else null;
            if (terminator) |stop| {
                const end = std.mem.indexOfPos(u8, self.source, start + 2, stop) orelse return error.InvalidJUnit;
                self.advance(end + stop.len);
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<!")) return error.UnsupportedJUnitDeclaration;
            const end = try self.tagEnd(start);
            var body = std.mem.trim(u8, self.source[start + 1 .. end], " \t\r\n");
            if (body.len == 0) return error.InvalidJUnit;
            const closing = body[0] == '/';
            if (closing) body = body[1..];
            const empty = std.mem.endsWith(u8, body, "/");
            if (empty) body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " \t\r\n");
            const split = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
            const result: Tag = .{ .name = body[0..split], .attributes = body[split..], .closing = closing, .empty = empty, .line = self.line };
            self.advance(end + 1);
            return result;
        }
        return null;
    }

    fn tagEnd(self: *Reader, start: usize) !usize {
        if (start >= self.source.len) assert.panic("JUnit tag starts at {d}, outside {d} report bytes", .{ start, self.source.len });
        if (self.source[start] != '<') assert.panic("JUnit tag starts with byte {d}, expected '<'", .{self.source[start]});
        var end = start + 1;
        var quote: u8 = 0;
        while (end < self.source.len) : (end += 1) {
            const c = self.source[end];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '\'' or c == '"') {
                quote = c;
            } else if (c == '>') return end;
        }
        return error.InvalidJUnit;
    }

    fn openCase(self: *Reader, t: Tag) !void {
        if (t.closing) assert.panic("cannot open closing JUnit tag '{s}'", .{t.name});
        if (self.depth > self.stack.len) assert.panic("JUnit depth {d} exceeds stack {d}", .{ self.depth, self.stack.len });
        if (self.current != null or self.depth == 0) return error.InvalidJUnit;
        if (!std.mem.eql(u8, self.stack[self.depth - 1], "testsuite")) return error.InvalidJUnit;
        const name = try attribute(t.attributes, "name") orelse return error.InvalidJUnit;
        const time = try attribute(t.attributes, "time");
        const seconds = if (time) |value| try std.fmt.parseFloat(f64, value) else null;
        if (seconds) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidTestDuration;
        self.current = .{ .name = name, .seconds = seconds, .line = t.line };
    }

    fn closeTag(self: *Reader, t: Tag) !?Case {
        if (!t.closing) assert.panic("cannot close opening JUnit tag '{s}'", .{t.name});
        if (self.depth > self.stack.len) assert.panic("JUnit depth {d} exceeds stack {d}", .{ self.depth, self.stack.len });
        if (t.empty or std.mem.trim(u8, t.attributes, " \t\r\n").len != 0 or self.depth == 0) return error.InvalidJUnit;
        self.depth -= 1;
        if (!std.mem.eql(u8, self.stack[self.depth], t.name)) return error.InvalidJUnit;
        if (!std.mem.eql(u8, t.name, "testcase")) return null;
        const result = self.current orelse return error.InvalidJUnit;
        self.current = null;
        return result;
    }

    fn checkRoot(self: *Reader, t: Tag) !void {
        if (t.closing) assert.panic("root check received closing tag '{s}'", .{t.name});
        if (self.depth > self.stack.len) assert.panic("JUnit depth {d} exceeds stack {d}", .{ self.depth, self.stack.len });
        if (self.depth == 0) {
            if (self.root_seen or (!std.mem.eql(u8, t.name, "testsuites") and !std.mem.eql(u8, t.name, "testsuite"))) return error.InvalidJUnit;
            self.root_seen = true;
        }
    }

    pub fn next(self: *Reader) !?Case {
        if (self.offset > self.source.len) assert.panic("JUnit offset {d} exceeds {d} report bytes", .{ self.offset, self.source.len });
        if (self.depth > self.stack.len) assert.panic("JUnit depth {d} exceeds stack {d}", .{ self.depth, self.stack.len });
        while (try self.tag()) |t| {
            if (t.closing) {
                if (try self.closeTag(t)) |case| return case;
                continue;
            }
            try self.checkRoot(t);
            if (std.mem.eql(u8, t.name, "testcase")) {
                try self.openCase(t);
                if (t.empty) {
                    const result = self.current;
                    self.current = null;
                    return result;
                }
            } else if (std.mem.eql(u8, t.name, "skipped")) {
                if (self.current) |*current| current.skipped = true;
            }
            if (!t.empty) {
                if (self.depth == self.stack.len) return error.JUnitTooDeep;
                self.stack[self.depth] = t.name;
                self.depth += 1;
            }
        }
        if (self.depth != 0 or self.current != null or !self.root_seen) return error.InvalidJUnit;
        return null;
    }
};

fn attribute(source: []const u8, wanted: []const u8) !?[]const u8 {
    if (wanted.len == 0) assert.panic("JUnit attribute requires a name", .{});
    if (wanted.len > 128) assert.panic("JUnit attribute name has {d} bytes; supported names have at most 128", .{wanted.len});
    var rest = std.mem.trim(u8, source, " \t\r\n");
    var found: ?[]const u8 = null;
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, "= \t\r\n") orelse return error.InvalidJUnit;
        const name = rest[0..end];
        rest = std.mem.trimStart(u8, rest[end..], " \t\r\n");
        if (name.len == 0 or rest.len < 2 or rest[0] != '=') return error.InvalidJUnit;
        rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
        if (rest.len < 2 or (rest[0] != '\'' and rest[0] != '"')) return error.InvalidJUnit;
        const close = std.mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse return error.InvalidJUnit;
        if (std.mem.eql(u8, name, wanted)) {
            if (found != null) return error.InvalidJUnit;
            found = rest[1..close];
        }
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t\r\n");
    }
    return found;
}

pub const Options = struct { path: []const u8, threshold_ms: u32 };

pub fn check(source: []const u8, options: Options, text: *memory.Text, findings: *memory.Bounded(Finding)) !void {
    if (options.path.len == 0) assert.panic("timing finding requires a report path", .{});
    if (findings.len > findings.capacity()) assert.panic("{d} timing findings exceed capacity {d}", .{ findings.len, findings.capacity() });
    var reader: Reader = .{ .source = source };
    while (try reader.next()) |case| {
        const seconds = case.seconds orelse continue;
        if (case.skipped or seconds * 1000 <= @as(f64, @floatFromInt(options.threshold_ms))) continue;
        try findings.add(.{
            .path = options.path,
            .line = case.line,
            .column = 0,
            .rule = "slow-test",
            .message = try text.format("'{s}' took {d:.3} seconds in this JUnit report, exceeding the {d} ms limit.", .{ case.name, seconds, options.threshold_ms }),
        });
    }
}

test "JUnit reads individual measured durations, skips absent times, and preserves report locations" {
    var reader: Reader = .{ .source = "<?xml version='1.0'?>\n<testsuites><testsuite time='999'>\n<testcase name='fast' time='0.01'/>\n<testcase name='slow[a&gt;b]' time='2.5'><system-out><![CDATA[<testcase time='999'/>]]></system-out></testcase>\n<testcase name='skip' time='10'><skipped/></testcase><testcase name='unknown'/></testsuite></testsuites>" };
    try std.testing.expectEqual(@as(f64, 0.01), (try reader.next()).?.seconds.?);
    const slow = (try reader.next()).?;
    try std.testing.expectEqual(@as(f64, 2.5), slow.seconds.?);
    try std.testing.expectEqual(@as(u32, 3), slow.line);
    try std.testing.expect((try reader.next()).?.skipped);
    try std.testing.expectEqual(@as(?f64, null), (try reader.next()).?.seconds);
    try std.testing.expectEqual(@as(?Case, null), try reader.next());
}

test "JUnit refuses invalid durations, truncated reports and entity declarations" {
    for ([_][]const u8{ "nan", "inf", "-1" }) |time| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "<testsuite><testcase name='x' time='{s}'/></testsuite>", .{time});
        defer std.testing.allocator.free(source);
        var reader: Reader = .{ .source = source };
        try std.testing.expectError(error.InvalidTestDuration, reader.next());
    }
    var truncated: Reader = .{ .source = "<testsuite><testcase name='x' time='1'>" };
    try std.testing.expectError(error.InvalidJUnit, truncated.next());
    var entities: Reader = .{ .source = "<!DOCTYPE testsuite><testsuite/>" };
    try std.testing.expectError(error.UnsupportedJUnitDeclaration, entities.next());
}
