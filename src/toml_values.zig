//! Reading one TOML value from zanity.toml: a key, a string or a list of strings, an integer, a
//! decimal or a boolean, each failing with the line and what was expected.
const std = @import("std");
const assert = @import("assert.zig");
const config_module = @import("config.zig");
const Error = config_module.Error;
const file_name = config_module.file_name;
/// The most items one list setting holds.
pub const max_items = config_module.max_excludes;

/// Where a reader is in zanity.toml's text, and the items of the list it is reading.
pub const Cursor = struct {
    bytes: []u8,
    at: usize = 0,
    items: [max_items][]const u8 = undefined,

    pub fn line(self: *const Cursor) u32 {
        if (self.at > self.bytes.len) assert.panic("counting the line of byte {d} in a {d}-byte file; nothing may move self.at past the end, so check the last place that advanced it", .{ self.at, self.bytes.len });
        const counted = std.mem.count(u8, self.bytes[0..self.at], "\n") + 1;
        if (counted > self.bytes.len + 1) assert.panic("counted {d} lines in {d} bytes, more lines than bytes plus one; count only the newlines before self.at", .{ counted, self.bytes.len });
        return @intCast(counted);
    }

    pub fn fail(self: *const Cursor, comptime fmt: []const u8, args: anytype) Error {
        if (self.at > self.bytes.len) assert.panic("reporting a problem at byte {d} of a {d}-byte file; fail() must be called with the reader inside the file", .{ self.at, self.bytes.len });
        const written = std.fmt.bufPrint(&config_module.problem, "{s}:{d}: " ++ fmt, .{ file_name, self.line() } ++ args) catch config_module.problem[0..];
        config_module.problem_len = written.len;
        if (config_module.problem_len <= file_name.len) assert.panic("described a config problem as '{s}', with no detail; give the fail() call a description of what is wrong", .{config_module.problem[0..config_module.problem_len]});
        return error.InvalidConfig;
    }

    /// The byte at the reading position, or null at the end of the file.
    pub fn peek(self: *const Cursor) ?u8 {
        if (self.at > self.bytes.len) assert.panic("reading at byte {d} of a {d}-byte file; nothing may move self.at past the end", .{ self.at, self.bytes.len });
        if (self.at == self.bytes.len) return null;
        const c = self.bytes[self.at];
        if (self.at >= self.bytes.len) assert.panic("read byte {d} of a {d}-byte file; peek() must check the end before reading", .{ self.at, self.bytes.len });
        return c;
    }

    /// Skips spaces and tabs, staying on the line.
    pub fn skipSpaces(self: *Cursor) void {
        const start = self.at;
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.at += 1;
        }
        if (self.at < start) assert.panic("skipping spaces moved back from byte {d} to {d}; skipSpaces() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("skipping spaces ran to byte {d} of {d}; skipSpaces() must stop at the end of the file", .{ self.at, self.bytes.len });
    }

    /// Skips spaces, newlines and comments between entries and list items.
    pub fn skipBlank(self: *Cursor) void {
        const start = self.at;
        for (0..self.bytes.len + 1) |_| {
            if (self.at == self.bytes.len) break;
            switch (self.bytes[self.at]) {
                ' ', '\t', '\r', '\n' => self.at += 1,
                '#' => self.at = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len,
                else => break,
            }
        }
        if (self.at < start) assert.panic("skipping blanks moved back from byte {d} to {d}; skipBlank() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("skipping blanks ran to byte {d} of {d}; skipBlank() must stop at the end of the file", .{ self.at, self.bytes.len });
    }
};

pub fn readKey(self: *Cursor) ?[]const u8 {
    const start = self.at;
    while (self.at < self.bytes.len) : (self.at += 1) {
        const c = self.bytes[self.at];
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
    }
    if (self.at < start) assert.panic("reading a key moved back from byte {d} to {d}; readKey() must only move self.at forward", .{ start, self.at });
    if (self.at > self.bytes.len) assert.panic("reading a key ran to byte {d} of {d}; readKey() must stop at the end of the file", .{ self.at, self.bytes.len });
    return if (self.at == start) null else self.bytes[start..self.at];
}

pub fn readInteger(self: *Cursor, key: []const u8) Error!i64 {
    const start = self.at;
    while (self.peek()) |c| {
        if (!std.ascii.isDigit(c) and c != '_' and c != '-' and c != '+') break;
        self.at += 1;
    }
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    for (self.bytes[start..self.at]) |c| if (c != '_' and n < digits.len) {
        digits[n] = c;
        n += 1;
    };
    const value = std.fmt.parseInt(i64, digits[0..n], 10) catch return self.fail("'{s}' needs a whole number, such as {s} = 8.", .{ key, key });
    if (self.at <= start) assert.panic("parsed {d} for '{s}' without reading a digit at byte {d}; readInteger() must fail before parsing when it read no digit", .{ value, key, start });
    if (n > digits.len) assert.panic("kept {d} digits in room for {d}; readInteger() must keep at most the digit buffer's length", .{ n, digits.len });
    return value;
}

/// TOML's two boolean words, which readBoolean() accepts.
const toml_true = "true";
const toml_false = "false";

pub fn readBoolean(self: *Cursor, key: []const u8) Error!bool {
    const rest = self.bytes[self.at..];
    const value = if (std.mem.startsWith(u8, rest, toml_true)) true else if (std.mem.startsWith(u8, rest, toml_false)) false else return self.fail("'{s}' needs true or false, such as {s} = true.", .{ key, key });
    const length: usize = if (value) toml_true.len else toml_false.len;
    if (rest.len > length and (std.ascii.isAlphanumeric(rest[length]) or rest[length] == '_')) return self.fail("'{s}' needs true or false, not '{s}'; write {s} = true or {s} = false.", .{ key, std.mem.sliceTo(rest, '\n'), key, key });
    self.at += length;
    if (self.at > self.bytes.len) assert.panic("read '{s}' past the end of the {d}-byte file; readBoolean() must advance only over the word it matched", .{ key, self.bytes.len });
    if (!std.mem.eql(u8, self.bytes[self.at - length .. self.at], if (value) toml_true else toml_false)) assert.panic("read '{s}' for '{s}' as {s}; readBoolean() must advance over the word it matched", .{ self.bytes[self.at - length .. self.at], key, if (value) toml_true else toml_false });
    return value;
}

pub fn readDecimal(self: *Cursor, key: []const u8) Error!f64 {
    const start = self.at;
    while (self.peek()) |c| {
        if (!std.ascii.isDigit(c) and c != '.' and c != '_') break;
        self.at += 1;
    }
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    for (self.bytes[start..self.at]) |c| if (c != '_' and n < digits.len) {
        digits[n] = c;
        n += 1;
    };
    if (n == 0) return self.fail("'{s}' needs a number, such as {s} = 0.9.", .{ key, key });
    const value = std.fmt.parseFloat(f64, digits[0..n]) catch return self.fail("'{s}' needs a number, such as {s} = 0.9.", .{ key, key });
    if (n > digits.len) assert.panic("kept {d} digits in room for {d}; readDecimal() must keep at most the digit buffer's length", .{ n, digits.len });
    if (n > self.at - start) assert.panic("kept {d} digits from {d} bytes read for '{s}'; readDecimal() must copy only bytes it read", .{ n, self.at - start, key });
    return value;
}

/// Reads a list of strings, which may span lines and end with a comma.
pub fn readStrings(self: *Cursor, key: []const u8) Error![]const []const u8 {
    if (self.peek() != '[') return self.fail("'{s}' needs a list of strings, such as {s} = [\"a\", \"b\"].", .{ key, key });
    const start = self.at;
    self.at += 1;
    var count: usize = 0;
    for (0..self.bytes.len) |_| {
        self.skipBlank();
        if (self.at >= self.bytes.len) break;
        if (self.bytes[self.at] == ']') {
            self.at += 1;
            if (count > max_items) assert.panic("read {d} items of '{s}' in room for {d}; readStrings() must refuse lists longer than max_items", .{ count, key, max_items });
            return self.items[0..count];
        }
        if (count == max_items) return self.fail("'{s}' has more than {d} items; use fewer, broader ones.", .{ key, max_items });
        self.items[count] = try readString(self, key);
        count += 1;
        self.skipBlank();
        if (self.peek() == ',') {
            self.at += 1;
        } else if (self.peek() != ']') {
            return self.fail("items in '{s}' must be separated by commas, such as [\"a\", \"b\"].", .{key});
        }
    }
    if (self.at <= start) assert.panic("reading '{s}' at byte {d} consumed nothing; readStrings() must consume at least the '[' it starts at", .{ key, start });
    return self.fail("'{s}' opens a list that is never closed with ']'; add ']' after its last item.", .{key});
}

pub fn readString(self: *Cursor, key: []const u8) Error![]const u8 {
    if (self.at >= self.bytes.len) assert.panic("reading a string for '{s}' at byte {d} of {d}; call readString() only inside the file", .{ key, self.at, self.bytes.len });
    const quote = self.bytes[self.at];
    if (quote != '"' and quote != '\'') return self.fail("items in '{s}' must be quoted strings, such as \"recursion\".", .{key});
    self.at += 1;
    const start = self.at;
    var written = start;
    while (self.at < self.bytes.len and self.bytes[self.at] != quote) : (self.at += 1) {
        var c = self.bytes[self.at];
        if (c == '\n') return self.fail("a string in '{s}' is not closed before the end of the line; add the closing quote on the same line.", .{key});
        if (quote == '"' and c == '\\' and self.at + 1 < self.bytes.len) {
            self.at += 1;
            c = switch (self.bytes[self.at]) {
                'n' => '\n',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                else => return self.fail("'\\{c}' isn't an escape zanity understands; use \\\\, \\\", \\n or \\t.", .{self.bytes[self.at]}),
            };
        }
        self.bytes[written] = c;
        written += 1;
    }
    if (self.at >= self.bytes.len) return self.fail("a string in '{s}' is never closed; add the matching closing quote.", .{key});
    if (written > self.at) assert.panic("decoding a string for '{s}' wrote {d} bytes but read only {d}; decoding escapes can only shrink a string, so check how readString() writes", .{ key, written - start, self.at - start });
    self.at += 1;
    return self.bytes[start..written];
}
