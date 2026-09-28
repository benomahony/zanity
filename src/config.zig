//! `zanity.toml`: which rules run, which paths are skipped, and how hard `--infer` may push
//! TypeSafe. zanity uses the nearest one at or above the directory it runs in, up to the
//! repository root. Anything it doesn't recognise is an error naming the line, never ignored.
//!
//!     rules = ["recursion", "long-function"]   # run exactly these, like --rules
//!     disable = ["duplicate-name"]             # or: the defaults without these
//!     exclude = ["vendor/", "tests/golden/**"] # gitignore syntax, relative to this file
//!
//!     [infer]
//!     concurrency = 16                         # requests to TypeSafe at once
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rules = @import("rules.zig");

pub const file_name = "zanity.toml";
pub const max_excludes = 256;
pub const max_concurrency = 64;
const max_file_bytes = 1 << 20;

pub const Config = struct {
    /// The directory holding the file, which `exclude` patterns are relative to; empty when none was found.
    dir: []const u8 = "",
    rules: ?rules.Set = null,
    disable: rules.Set = .{},
    exclude: [max_excludes][]const u8 = undefined,
    exclude_len: usize = 0,
    concurrency: ?u32 = null,

    pub fn excludes(self: *const Config) []const []const u8 {
        if (self.exclude_len > max_excludes) std.debug.panic("{d} exclude patterns in room for {d}", .{ self.exclude_len, max_excludes });
        if (self.exclude_len > 0 and self.dir.len == 0) std.debug.panic("{d} exclude patterns with no directory to anchor them", .{self.exclude_len});
        return self.exclude[0..self.exclude_len];
    }

    /// The rules to run: `rules` if given, else the defaults, without anything in `disable`.
    pub fn selection(self: *const Config) rules.Set {
        const chosen = self.rules orelse rules.Set.defaults();
        var kept: rules.Set = .{};
        for (chosen.names()) |name| if (!self.disable.enabled(name)) kept.include(name);
        if (kept.len > chosen.len) std.debug.panic("disabling rules kept {d} of {d}, more than were chosen", .{ kept.len, chosen.len });
        if (kept.len + self.disable.len < chosen.len) std.debug.panic("kept {d} of {d} rules after disabling {d}; disabling dropped extra rules", .{ kept.len, chosen.len, self.disable.len });
        return kept;
    }
};

/// What was wrong with the file, for the error message: the line and what to change.
pub var problem: [512]u8 = undefined;
pub var problem_len: usize = 0;

pub const Error = error{InvalidConfig};

/// Finds and reads the nearest `zanity.toml` at or above the current directory, stopping at
/// the repository root. No file means an empty config.
pub fn initConfig(gpa: Allocator, io: Io) !Config {
    const start = try Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    if (!std.fs.path.isAbsolute(start)) std.debug.panic("looking for {s} from '{s}', which is relative; pass the real path", .{ file_name, start });
    var dir: ?[]const u8 = start;
    for (0..64) |_| {
        const d = dir orelse break;
        const path = try std.fs.path.join(gpa, &.{ d, file_name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch null;
        if (bytes) |found| {
            var config = try parseConfig(found);
            config.dir = d;
            return config;
        }
        if (isRepositoryRoot(io, d)) break;
        dir = std.fs.path.dirname(d);
    }
    if (start.len == 0) std.debug.panic("searched for {s} from an empty directory", .{file_name});
    return .{};
}

fn isRepositoryRoot(io: Io, dir: []const u8) bool {
    if (dir.len == 0) std.debug.panic("checking whether an empty path is a repository root", .{});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const git = std.fmt.bufPrint(&buffer, "{s}/.git", .{dir}) catch return false;
    Io.Dir.cwd().access(io, git, .{}) catch return false;
    if (git.len <= dir.len) std.debug.panic("'{s}' is no longer than its directory '{s}'", .{ git, dir });
    return true;
}

/// Parses the TOML zanity understands, reporting the first problem in `problem`. Strings are
/// decoded in place, so `bytes` must outlive the config.
pub fn parseConfig(bytes: []u8) Error!Config {
    if (bytes.len > max_file_bytes) std.debug.panic("{s} is {d} bytes; initConfig reads at most {d}", .{ file_name, bytes.len, max_file_bytes });
    var reader: TomlReader = .{ .bytes = bytes };
    var config: Config = .{};
    for (0..bytes.len + 1) |_| {
        reader.skipBlank();
        if (reader.at == bytes.len) break;
        try reader.readEntry(&config);
    }
    if (reader.at != bytes.len) std.debug.panic("stopped parsing {s} at byte {d} of {d}", .{ file_name, reader.at, bytes.len });
    return config;
}

const Table = enum { root, infer };

const max_items = max_excludes;

const TomlReader = struct {
    bytes: []u8,
    at: usize = 0,
    table: Table = .root,
    items: [max_items][]const u8 = undefined,

    fn fail(self: *const TomlReader, comptime fmt: []const u8, args: anytype) Error {
        if (self.at > self.bytes.len) std.debug.panic("reporting a problem at byte {d} of a {d}-byte file", .{ self.at, self.bytes.len });
        const line = std.mem.count(u8, self.bytes[0..self.at], "\n") + 1;
        const written = std.fmt.bufPrint(&problem, "{s}:{d}: " ++ fmt, .{ file_name, line } ++ args) catch problem[0..];
        problem_len = written.len;
        if (problem_len <= file_name.len) std.debug.panic("described a config problem as '{s}', with no detail", .{problem[0..problem_len]});
        return error.InvalidConfig;
    }

    /// Skips spaces, newlines and comments between entries and list items.
    fn skipBlank(self: *TomlReader) void {
        const start = self.at;
        for (0..self.bytes.len + 1) |_| {
            if (self.at == self.bytes.len) break;
            switch (self.bytes[self.at]) {
                ' ', '\t', '\r', '\n' => self.at += 1,
                '#' => self.at = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len,
                else => break,
            }
        }
        if (self.at < start) std.debug.panic("skipping blanks moved back from byte {d} to {d}", .{ start, self.at });
        if (self.at > self.bytes.len) std.debug.panic("skipping blanks ran to byte {d} of {d}", .{ self.at, self.bytes.len });
    }

    /// Skips spaces and tabs, then requires the rest of the line to be empty or a comment.
    fn endLine(self: *TomlReader) Error!void {
        const start = self.at;
        while (self.at < self.bytes.len and (self.bytes[self.at] == ' ' or self.bytes[self.at] == '\t')) self.at += 1;
        if (self.at < self.bytes.len and self.bytes[self.at] == '#') self.at = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len;
        if (self.at < self.bytes.len and self.bytes[self.at] != '\n' and self.bytes[self.at] != '\r') {
            return self.fail("unexpected '{c}' after a value; put each setting on its own line.", .{self.bytes[self.at]});
        }
        if (self.at < start) std.debug.panic("ending a line moved back from byte {d} to {d}", .{ start, self.at });
        if (self.at > self.bytes.len) std.debug.panic("ending a line ran to byte {d} of {d}", .{ self.at, self.bytes.len });
    }

    fn readEntry(self: *TomlReader, config: *Config) Error!void {
        if (self.at >= self.bytes.len) std.debug.panic("reading an entry at byte {d} of a {d}-byte file", .{ self.at, self.bytes.len });
        const start = self.at;
        if (self.bytes[self.at] == '[') {
            self.at += 1;
            const name = self.readKey() orelse return self.fail("expected a table name after '['.", .{});
            if (self.at >= self.bytes.len or self.bytes[self.at] != ']') return self.fail("expected ']' after '[{s}'.", .{name});
            self.at += 1;
            self.table = std.meta.stringToEnum(Table, name) orelse .root;
            if (self.table == .root) return self.fail("'[{s}]' isn't a table zanity knows; the only table is [infer].", .{name});
        } else {
            const key = self.readKey() orelse return self.fail("expected a setting such as 'rules = [...]' or a table such as '[infer]'.", .{});
            while (self.at < self.bytes.len and (self.bytes[self.at] == ' ' or self.bytes[self.at] == '\t')) self.at += 1;
            if (self.at >= self.bytes.len or self.bytes[self.at] != '=') return self.fail("expected '=' after '{s}'.", .{key});
            self.at += 1;
            while (self.at < self.bytes.len and (self.bytes[self.at] == ' ' or self.bytes[self.at] == '\t')) self.at += 1;
            try self.readSetting(config, key);
        }
        try self.endLine();
        if (self.at <= start) std.debug.panic("reading an entry at byte {d} consumed nothing", .{start});
    }

    fn readKey(self: *TomlReader) ?[]const u8 {
        const start = self.at;
        while (self.at < self.bytes.len) : (self.at += 1) {
            const c = self.bytes[self.at];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
        }
        if (self.at < start) std.debug.panic("reading a key moved back from byte {d} to {d}", .{ start, self.at });
        if (self.at > self.bytes.len) std.debug.panic("reading a key ran to byte {d} of {d}", .{ self.at, self.bytes.len });
        return if (self.at == start) null else self.bytes[start..self.at];
    }

    fn readSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (key.len == 0) std.debug.panic("setting a key with no name at byte {d}", .{self.at});
        if (self.table == .infer) {
            if (!std.mem.eql(u8, key, "concurrency")) return self.fail("'{s}' isn't an [infer] setting; the only one is concurrency.", .{key});
            const value = try self.readInteger(key);
            if (value < 1 or value > max_concurrency) return self.fail("concurrency is {d}; it must be between 1 and {d}.", .{ value, max_concurrency });
            config.concurrency = @intCast(value);
            return;
        }
        const Setting = enum { rules, disable, exclude };
        const which = std.meta.stringToEnum(Setting, key) orelse return self.fail("'{s}' isn't a setting; the settings are rules, disable, exclude and, under [infer], concurrency.", .{key});
        const items = try self.readStrings(key);
        switch (which) {
            .exclude => {
                for (items) |glob| if (glob.len == 0) return self.fail("an 'exclude' pattern is empty; remove it or name a path.", .{});
                @memcpy(config.exclude[0..items.len], items);
                config.exclude_len = items.len;
            },
            .rules, .disable => {
                var set: rules.Set = .{};
                for (items) |name| set.include((rules.find(name) orelse return self.fail("'{s}' isn't a rule; the rules are listed in the README, and 'zanity check --rules' takes the same names.", .{name})).name);
                if (which == .rules and set.len == 0) return self.fail("'rules' is empty, so nothing would run; list at least one rule, or remove it to run the defaults.", .{});
                if (which == .rules) config.rules = set else config.disable = set;
            },
        }
        if (config.exclude_len > max_excludes) std.debug.panic("{d} exclude patterns in room for {d}", .{ config.exclude_len, max_excludes });
    }

    fn readInteger(self: *TomlReader, key: []const u8) Error!i64 {
        const start = self.at;
        while (self.at < self.bytes.len and (std.ascii.isDigit(self.bytes[self.at]) or self.bytes[self.at] == '_' or self.bytes[self.at] == '-' or self.bytes[self.at] == '+')) self.at += 1;
        var digits: [32]u8 = undefined;
        var n: usize = 0;
        for (self.bytes[start..self.at]) |c| if (c != '_' and n < digits.len) {
            digits[n] = c;
            n += 1;
        };
        const value = std.fmt.parseInt(i64, digits[0..n], 10) catch return self.fail("'{s}' needs a whole number, such as {s} = 8.", .{ key, key });
        if (self.at <= start) std.debug.panic("parsed {d} for '{s}' without reading a digit at byte {d}", .{ value, key, start });
        if (n > digits.len) std.debug.panic("kept {d} digits in room for {d}", .{ n, digits.len });
        return value;
    }

    /// Reads a list of strings, which may span lines and end with a comma.
    fn readStrings(self: *TomlReader, key: []const u8) Error![]const []const u8 {
        if (self.at >= self.bytes.len or self.bytes[self.at] != '[') return self.fail("'{s}' needs a list of strings, such as {s} = [\"a\", \"b\"].", .{ key, key });
        const start = self.at;
        self.at += 1;
        var count: usize = 0;
        for (0..self.bytes.len) |_| {
            self.skipBlank();
            if (self.at >= self.bytes.len) break;
            if (self.bytes[self.at] == ']') {
                self.at += 1;
                if (count > max_items) std.debug.panic("read {d} items of '{s}' in room for {d}", .{ count, key, max_items });
                return self.items[0..count];
            }
            if (count == max_items) return self.fail("'{s}' has more than {d} items; use fewer, broader ones.", .{ key, max_items });
            self.items[count] = try self.readString(key);
            count += 1;
            self.skipBlank();
            if (self.at < self.bytes.len and self.bytes[self.at] == ',') {
                self.at += 1;
            } else if (self.at >= self.bytes.len or self.bytes[self.at] != ']') {
                return self.fail("items in '{s}' must be separated by commas.", .{key});
            }
        }
        if (self.at <= start) std.debug.panic("reading '{s}' at byte {d} consumed nothing", .{ key, start });
        return self.fail("'{s}' opens a list that is never closed with ']'.", .{key});
    }

    fn readString(self: *TomlReader, key: []const u8) Error![]const u8 {
        if (self.at >= self.bytes.len) std.debug.panic("reading a string for '{s}' at byte {d} of {d}", .{ key, self.at, self.bytes.len });
        const quote = self.bytes[self.at];
        if (quote != '"' and quote != '\'') return self.fail("items in '{s}' must be quoted strings, such as \"recursion\".", .{key});
        self.at += 1;
        const start = self.at;
        var written = start;
        while (self.at < self.bytes.len and self.bytes[self.at] != quote) : (self.at += 1) {
            var c = self.bytes[self.at];
            if (c == '\n') return self.fail("a string in '{s}' is not closed before the end of the line.", .{key});
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
        if (self.at >= self.bytes.len) return self.fail("a string in '{s}' is never closed.", .{key});
        if (written > self.at) std.debug.panic("decoding a string for '{s}' wrote {d} bytes but read only {d}", .{ key, written - start, self.at - start });
        self.at += 1;
        return self.bytes[start..written];
    }
};
