//! The YAML zanity.yaml and ddd.yaml are written in: mappings, block and inline lists, and plain
//! and quoted strings. Every value is a string, so `no` is never false; a value YAML would read
//! as more than text, such as an alias starting with `*`, must be quoted, and is reported until
//! it is. Each problem names the file and line and says what to write instead.
const std = @import("std");
const assert = @import("assert.zig");
const config = @import("config.zig");
const Error = config.Error;

const max_items = config.max_excludes;

/// The keys lined up at `indent`, read one at a time.
pub const Mapping = struct { indent: usize, started: bool = false };

/// The '- ' items of a list under a key at `indent`, read one at a time; `column` is where they
/// line up, once the first is found.
pub const List = struct { indent: usize, column: ?usize = null };

pub const Reader = struct {
    bytes: []u8,
    at: usize = 0,
    /// The file being read, for the problems reported in it.
    file: []const u8,
    items: [max_items][]const u8 = undefined,

    pub fn line(self: *const Reader) u32 {
        if (self.at > self.bytes.len) assert.panic("counting the line of byte {d} in a {d}-byte file; nothing may move self.at past the end, so check the last place that advanced it", .{ self.at, self.bytes.len });
        const counted = std.mem.count(u8, self.bytes[0..self.at], "\n") + 1;
        if (counted > self.bytes.len + 1) assert.panic("counted {d} lines in {d} bytes, more lines than bytes plus one; count only the newlines before self.at", .{ counted, self.bytes.len });
        return @intCast(counted);
    }

    pub fn fail(self: *const Reader, comptime fmt: []const u8, args: anytype) Error {
        if (self.at > self.bytes.len) assert.panic("reporting a problem at byte {d} of a {d}-byte file; fail() must be called with the reader inside the file", .{ self.at, self.bytes.len });
        if (self.file.len == 0) assert.panic("reporting a problem in a file with no name; set the reader's file to the name of the file it reads", .{});
        return self.failAt(self.line(), fmt, args);
    }

    /// Reports a problem on `at_line`, a line already read, such as where a list item began.
    pub fn failAt(self: *const Reader, at_line: u32, comptime fmt: []const u8, args: anytype) Error {
        if (at_line == 0 or at_line > self.line()) assert.panic("reporting a problem on line {d} while reading line {d}; pass a line already read, counting from 1", .{ at_line, self.line() });
        const written = std.fmt.bufPrint(&config.problem, "{s}:{d}: " ++ fmt, .{ self.file, at_line } ++ args) catch config.problem[0..];
        config.problem_len = written.len;
        if (config.problem_len <= self.file.len) assert.panic("described a config problem as '{s}', with no detail; give the fail() call a description of what is wrong", .{config.problem[0..config.problem_len]});
        return error.InvalidConfig;
    }

    /// The byte at the reading position, or null at the end of the file.
    pub fn peek(self: *const Reader) ?u8 {
        if (self.at > self.bytes.len) assert.panic("reading at byte {d} of a {d}-byte file; nothing may move self.at past the end", .{ self.at, self.bytes.len });
        if (self.at == self.bytes.len) return null;
        const c = self.bytes[self.at];
        if (self.at >= self.bytes.len) assert.panic("read byte {d} of a {d}-byte file; peek() must check the end before reading", .{ self.at, self.bytes.len });
        return c;
    }

    /// Skips spaces and tabs, staying on the line.
    pub fn skipSpaces(self: *Reader) void {
        const start = self.at;
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.at += 1;
        }
        if (self.at < start) assert.panic("skipping spaces moved back from byte {d} to {d}; skipSpaces() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("skipping spaces ran to byte {d} of {d}; skipSpaces() must stop at the end of the file", .{ self.at, self.bytes.len });
    }

    /// Skips spaces, newlines and comments, to the next thing to read.
    pub fn skipBlank(self: *Reader) void {
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

    /// Skips spaces and tabs, then requires the rest of the line to be empty or a comment.
    pub fn endLine(self: *Reader) Error!void {
        const start = self.at;
        self.skipSpaces();
        if (self.peek() == '#') self.at = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len;
        if (self.peek()) |c| if (c != '\n' and c != '\r') {
            return self.fail("unexpected '{c}' after a value; put each setting on its own line.", .{c});
        };
        if (self.at < start) assert.panic("ending a line moved back from byte {d} to {d}; endLine() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("ending a line ran to byte {d} of {d}; endLine() must stop at the end of the file", .{ self.at, self.bytes.len });
    }

    /// The keys at the top of the file, which must start at the left margin; null for a file
    /// with nothing in it but comments.
    pub fn topKeys(self: *Reader) Error!?Mapping {
        if (self.at != 0) assert.panic("starting {s} at byte {d}; topKeys() reads from the beginning of the file", .{ self.file, self.at });
        self.skipBlank();
        if (self.at == self.bytes.len) return null;
        if (self.column() != 0) return self.fail("the first key is indented; start the file's keys at the left margin.", .{});
        if (self.at > self.bytes.len) assert.panic("skipping to the first key ran to byte {d} of {d}", .{ self.at, self.bytes.len });
        return .{ .indent = 0 };
    }

    /// Requires that nothing is left after the top-level keys.
    pub fn finish(self: *Reader) Error!void {
        if (self.file.len == 0) assert.panic("finishing a file with no name at byte {d}; set the reader's file to the name of the file it reads", .{self.at});
        const start_at = self.at;
        self.skipBlank();
        if (self.at != self.bytes.len) return self.fail("this line is indented differently from the keys above it; line it up with the key it belongs beside.", .{});
        if (self.at < start_at) assert.panic("finishing {s} moved back from byte {d} to {d}", .{ self.file, start_at, self.at });
    }

    /// How far the reading position is from the start of its line.
    pub fn column(self: *const Reader) usize {
        if (self.at > self.bytes.len) assert.panic("finding the column of byte {d} in a {d}-byte file; nothing may move the reader past the end", .{ self.at, self.bytes.len });
        const line_start = if (std.mem.lastIndexOfScalar(u8, self.bytes[0..self.at], '\n')) |i| i + 1 else 0;
        if (line_start > self.at) assert.panic("the line holding byte {d} starts after it, at {d}; column() must look only before the reading position", .{ self.at, line_start });
        return self.at - line_start;
    }

    /// Whether the line at the reading position belongs to the value of a key at `indent`: it is
    /// indented further, or is a list item lined up with the key.
    fn childOf(self: *const Reader, indent: usize) bool {
        if (self.at > self.bytes.len) assert.panic("checking indentation at byte {d} of a {d}-byte file; nothing may move the reader past the end", .{ self.at, self.bytes.len });
        if (self.at == self.bytes.len) return false;
        const at_column = self.column();
        if (at_column > self.at) assert.panic("column {d} at byte {d}; a column can't be past the bytes before it", .{ at_column, self.at });
        return at_column > indent or (at_column == indent and self.peek() == '-');
    }

    fn readKey(self: *Reader) ?[]const u8 {
        const start_at = self.at;
        while (self.at < self.bytes.len) : (self.at += 1) {
            const c = self.bytes[self.at];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
        }
        if (self.at < start_at) assert.panic("reading a key moved back from byte {d} to {d}; readKey() must only move self.at forward", .{ start_at, self.at });
        if (self.at > self.bytes.len) assert.panic("reading a key ran to byte {d} of {d}; readKey() must stop at the end of the file", .{ self.at, self.bytes.len });
        return if (self.at == start_at) null else self.bytes[start_at..self.at];
    }

    /// Moves past the mapping's next key and its colon, returning the key; null once a line is
    /// indented less than the keys, or starts the next item of a list.
    pub fn nextKey(self: *Reader, mapping: *Mapping) Error!?[]const u8 {
        if (mapping.started) {
            self.skipBlank();
            if (self.at == self.bytes.len or self.column() != mapping.indent or self.peek() == '-') return null;
        }
        mapping.started = true;
        const key = self.readKey() orelse return self.fail("expected a key such as 'name:'; write each setting as name: value.", .{});
        if (self.peek() != ':') return self.fail("expected ':' after '{s}'; write each setting as name: value.", .{key});
        self.at += 1;
        self.skipSpaces();
        if (key.len == 0) assert.panic("read an empty key at byte {d}; readKey() returns null when it reads nothing", .{self.at});
        if (self.at > self.bytes.len) assert.panic("reading the key '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, self.at, self.bytes.len });
        return key;
    }

    /// The settings after `key:`, indented on the lines below; null when there are none, or for
    /// `{}`.
    pub fn nestedMapping(self: *Reader, key: []const u8, indent: usize) Error!?Mapping {
        if (key.len == 0) assert.panic("reading settings for a key with no name at byte {d}; nextKey() reads a key first", .{self.at});
        if (self.peek() == '{') {
            self.at += 1;
            self.skipSpaces();
            if (self.peek() != '}') return self.fail("write the settings of '{s}' on the lines below it, indented, one per line.", .{key});
            self.at += 1;
            try self.endLine();
            return null;
        }
        if (self.peek()) |c| if (c != '\n' and c != '\r' and c != '#') return self.fail("'{s}' takes its settings on the indented lines below it, one name: value per line.", .{key});
        self.skipBlank();
        if (!self.childOf(indent)) return null;
        if (self.peek() == '-') return self.fail("'{s}' takes settings, not a list; write them as name: value on the lines below it.", .{key});
        if (self.column() <= indent) assert.panic("the settings of '{s}' at column {d} aren't indented past it at {d}; childOf() accepts only deeper lines", .{ key, self.column(), indent });
        return .{ .indent = self.column() };
    }

    /// Moves to the content of the list's next item and returns the line its dash is on; null once
    /// a line is indented less, or isn't an item.
    pub fn nextItem(self: *Reader, list: *List) Error!?u32 {
        self.skipBlank();
        if (self.at == self.bytes.len) return null;
        const dash_column = self.column();
        if (list.column) |lined_up| {
            if (dash_column != lined_up or self.peek() != '-') return null;
        } else if (self.childOf(list.indent)) {
            list.column = dash_column;
        } else return null;
        if (self.peek() != '-') return self.fail("expected '- ' to start an item of the list; begin each item with a dash.", .{});
        const item_line = self.line();
        self.at += 1;
        self.skipBlank();
        if (dash_column < list.indent) assert.panic("an item's dash at column {d} is left of its key at {d}; childOf() accepts only lines at or past the key", .{ dash_column, list.indent });
        if (self.at == self.bytes.len or self.column() <= dash_column) return self.failAt(item_line, "an item of the list is empty; write it after the dash.", .{});
        if (item_line == 0) assert.panic("an item on line 0; line() counts from 1", .{});
        return item_line;
    }

    /// The list of mappings after `key:`, one '- name: ...' item per line below; null for `[]`.
    pub fn mappingList(self: *Reader, key: []const u8, indent: usize) Error!?List {
        if (key.len == 0) assert.panic("reading a list for a key with no name at byte {d}; nextKey() reads a key first", .{self.at});
        if (self.peek() == '[') {
            self.at += 1;
            self.skipSpaces();
            if (self.peek() != ']') return self.fail("write each item of '{s}' on its own line, starting with '- '.", .{key});
            self.at += 1;
            try self.endLine();
            return null;
        }
        try self.endLine();
        if (self.at > self.bytes.len) assert.panic("reading the list '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, self.at, self.bytes.len });
        return .{ .indent = indent };
    }

    /// Skips the value of a key at `indent` that zanity doesn't use: the rest of its line, and
    /// every line below indented further or listed under it, which covers text blocks such as `|`.
    pub fn skipValue(self: *Reader, indent: usize) void {
        const start_at = self.at;
        self.at = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len;
        for (0..self.bytes.len) |_| {
            self.skipBlank();
            if (!self.childOf(indent)) break;
            self.at = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len;
        }
        if (self.at < start_at) assert.panic("skipping a value moved back from byte {d} to {d}; skipValue() must only move forward", .{ start_at, self.at });
        if (self.at > self.bytes.len) assert.panic("skipping a value ran to byte {d} of {d}; it must stop at the end of the file", .{ self.at, self.bytes.len });
    }

    /// A list of strings: `[a, b]`, or one '- item' per line below the key. The items stay valid
    /// until the next list is read.
    pub fn readStrings(self: *Reader, key: []const u8, indent: usize) Error![]const []const u8 {
        if (self.peek() == '[') return self.readFlow(key);
        if (self.peek()) |c| if (c != '\n' and c != '\r' and c != '#') return self.fail("'{s}' needs a list, such as {s}: [a, b], or one '- item' per line below it.", .{ key, key });
        var list: List = .{ .indent = indent };
        var count: usize = 0;
        for (0..self.bytes.len) |_| {
            _ = (try self.nextItem(&list)) orelse break;
            if (count == max_items) return self.fail("'{s}' has more than {d} items; use fewer, broader ones.", .{ key, max_items });
            self.items[count] = try self.readScalar(key, false);
            count += 1;
            try self.endLine();
        }
        if (count > max_items) assert.panic("read {d} items of '{s}' in room for {d}; readStrings() must refuse more", .{ count, key, max_items });
        if (self.at > self.bytes.len) assert.panic("reading '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, self.at, self.bytes.len });
        return self.items[0..count];
    }

    /// A list written inline, `[a, b]`, which may span lines.
    fn readFlow(self: *Reader, key: []const u8) Error![]const []const u8 {
        if (self.peek() != '[') assert.panic("reading an inline list for '{s}' that doesn't start with '['; readStrings() checks first", .{key});
        self.at += 1;
        var count: usize = 0;
        for (0..self.bytes.len) |_| {
            self.skipBlank();
            if (self.at == self.bytes.len or self.peek() == ']') break;
            if (count == max_items) return self.fail("'{s}' has more than {d} items; use fewer, broader ones.", .{ key, max_items });
            self.items[count] = try self.readScalar(key, true);
            count += 1;
            self.skipBlank();
            if (self.peek() == ',') {
                self.at += 1;
            } else if (self.at < self.bytes.len and self.peek() != ']') {
                return self.fail("items in '{s}' must be separated by commas, such as [a, b].", .{key});
            }
        }
        if (self.peek() != ']') return self.fail("'{s}' opens a list that is never closed with ']'; separate its items with commas and close it after the last.", .{key});
        self.at += 1;
        try self.endLine();
        if (count > max_items) assert.panic("read {d} items of '{s}' in room for {d}; readFlow() must refuse more", .{ count, key, max_items });
        return self.items[0..count];
    }

    /// A quoted string, or a plain one; inside `[]` a plain one also ends at a comma or bracket.
    /// A plain value starting with a character YAML reads as more than text must be quoted.
    pub fn readScalar(self: *Reader, key: []const u8, flow: bool) Error![]const u8 {
        const first = self.peek() orelse return self.fail("'{s}' has no value; write one after the colon.", .{key});
        if (first == '"' or first == '\'') return self.readString(key);
        if (std.mem.indexOfScalar(u8, "*&!|>%@`{", first) != null) return self.fail("a value of '{s}' starts with '{c}', which YAML reads as more than text; put the value in quotes.", .{ key, first });
        const start_at = self.at;
        const end = self.skipPlain(flow);
        if (end == start_at) return self.fail("'{s}' has an empty value; write one, or remove it.", .{key});
        if (end > self.at) assert.panic("a plain value for '{s}' ends at byte {d}, past the reading position {d}; skipPlain() must end it at a byte it read", .{ key, end, self.at });
        if (end < start_at) assert.panic("a plain value for '{s}' ends at byte {d}, before it starts at {d}", .{ key, end, start_at });
        return self.bytes[start_at..end];
    }

    /// Moves past a plain value, to the end of the line or a comment, and returns where it ends
    /// without its trailing spaces.
    fn skipPlain(self: *Reader, flow: bool) usize {
        const start_at = self.at;
        var end = start_at;
        while (self.peek()) |c| {
            if (c == '\n' or c == '\r') break;
            if (c == '#' and (self.at == start_at or self.bytes[self.at - 1] == ' ')) break;
            if (flow and (c == ',' or c == ']')) break;
            self.at += 1;
            if (c != ' ' and c != '\t') end = self.at;
        }
        if (end < start_at or end > self.at) assert.panic("a plain value from byte {d} ends at {d}, outside what was read up to {d}", .{ start_at, end, self.at });
        if (self.at > self.bytes.len) assert.panic("reading a plain value ran to byte {d} of {d}; it must stop at the end of the file", .{ self.at, self.bytes.len });
        return end;
    }

    /// A string in single or double quotes, decoded in place.
    fn readString(self: *Reader, key: []const u8) Error![]const u8 {
        if (self.at >= self.bytes.len) assert.panic("reading a string for '{s}' at byte {d} of {d}; call readString() only inside the file", .{ key, self.at, self.bytes.len });
        const quote = self.bytes[self.at];
        if (quote != '"' and quote != '\'') assert.panic("reading a quoted string for '{s}' that starts with '{c}'; readScalar() hands over only quoted strings", .{ key, quote });
        self.at += 1;
        const start_at = self.at;
        var written = start_at;
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
        if (written > self.at) assert.panic("decoding a string for '{s}' wrote {d} bytes but read only {d}; decoding escapes can only shrink a string, so check how readString() writes", .{ key, written - start_at, self.at - start_at });
        self.at += 1;
        return self.bytes[start_at..written];
    }
};
