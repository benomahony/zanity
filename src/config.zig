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
//!
//!     [paths."src/*_test.zig"]                 # gitignore syntax, relative to this file
//!     disable = ["process-in-test"]            # these rules don't report here
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rules = @import("rules.zig");
const ignore = @import("ignore.zig");

pub const file_name = "zanity.toml";
pub const max_excludes = 256;
pub const max_concurrency = 64;
pub const max_path_sections = 32;
const max_file_bytes = 1 << 20;

/// A `[paths."<glob>"]` section: rules that don't report in the files the pattern matches.
pub const PathRules = struct {
    glob: []const u8,
    disable: rules.Set = .{},
};

pub const Config = struct {
    /// The directory holding the file, which `exclude` patterns are relative to; empty when none was found.
    dir: []const u8 = "",
    rules: ?rules.Set = null,
    disable: rules.Set = .{},
    exclude: [max_excludes][]const u8 = undefined,
    exclude_len: usize = 0,
    concurrency: ?u32 = null,
    paths: [max_path_sections]PathRules = undefined,
    paths_len: usize = 0,

    pub fn pathRules(self: *const Config) []const PathRules {
        if (self.paths_len > max_path_sections) std.debug.panic("{d} [paths] sections in room for {d}", .{ self.paths_len, max_path_sections });
        if (self.paths_len > 0 and self.dir.len == 0) std.debug.panic("{d} [paths] sections with no directory to anchor them", .{self.paths_len});
        return self.paths[0..self.paths_len];
    }

    /// Whether a `[paths]` section turns `rule` off for the file at `relative`, a path from this
    /// file's directory. As in gitignore, a pattern without a `/` matches the file's name at any
    /// depth, and one ending in `/` matches everything under that directory.
    pub fn disabledAt(self: *const Config, relative: []const u8, rule: []const u8) bool {
        if (relative.len == 0) std.debug.panic("asked whether '{s}' is disabled for an empty path", .{rule});
        if (rules.find(rule) == null) std.debug.panic("asked whether '{s}', which is not a rule, is disabled at '{s}'", .{ rule, relative });
        for (self.pathRules()) |section| {
            if (!section.disable.enabled(rule)) continue;
            if (pathMatches(section.glob, relative)) return true;
        }
        return false;
    }

    pub fn excludes(self: *const Config) []const []const u8 {
        if (self.exclude_len > max_excludes) std.debug.panic("{d} exclude patterns in room for {d}; readStrings() must reject lists longer than max_excludes", .{ self.exclude_len, max_excludes });
        if (self.exclude_len > 0 and self.dir.len == 0) std.debug.panic("{d} exclude patterns with no directory to anchor them; initConfig() must set dir to the folder holding zanity.toml", .{self.exclude_len});
        return self.exclude[0..self.exclude_len];
    }

    /// The rules to run: `rules` if given, else the defaults, without anything in `disable`.
    pub fn selection(self: *const Config) rules.Set {
        const chosen = self.rules orelse rules.Set.defaults();
        var kept: rules.Set = .{};
        for (chosen.names()) |name| if (!self.disable.enabled(name)) kept.include(name);
        if (kept.len > chosen.len) std.debug.panic("disabling rules kept {d} of {d}, more than were chosen; selection() must copy only chosen rules, so check its loop", .{ kept.len, chosen.len });
        if (kept.len + self.disable.len < chosen.len) std.debug.panic("kept {d} of {d} rules after disabling {d}; disabling dropped extra rules, so selection() must skip only the rules in disable", .{ kept.len, chosen.len, self.disable.len });
        return kept;
    }
};

fn pathMatches(glob: []const u8, relative: []const u8) bool {
    if (glob.len == 0) std.debug.panic("matching '{s}' against an empty [paths] pattern; the reader rejects those", .{relative});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trimmed = std.mem.trimStart(u8, glob, "/");
    const whole = if (std.mem.endsWith(u8, trimmed, "/"))
        std.fmt.bufPrint(&buffer, "{s}**", .{trimmed}) catch return false
    else if (std.mem.indexOfScalar(u8, trimmed, '/') == null)
        std.fmt.bufPrint(&buffer, "**/{s}", .{trimmed}) catch return false
    else
        trimmed;
    if (whole.len < trimmed.len) std.debug.panic("widening the [paths] pattern '{s}' shortened it to '{s}'", .{ glob, whole });
    return ignore.matchPath(whole, relative);
}

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

const Table = enum { root, infer, paths };

const max_items = max_excludes;

const TomlReader = struct {
    bytes: []u8,
    at: usize = 0,
    table: Table = .root,
    items: [max_items][]const u8 = undefined,
    /// The pattern of a `[paths."<glob>"]` header, until its section is added.
    pending_glob: []const u8 = "",

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
        if (self.at < start) std.debug.panic("skipping blanks moved back from byte {d} to {d}; skipBlank() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) std.debug.panic("skipping blanks ran to byte {d} of {d}; skipBlank() must stop at the end of the file", .{ self.at, self.bytes.len });
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
            try self.readHeader(config);
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

    /// Reads a table header: `[infer]`, or `[paths."<glob>"]`, which starts a new section.
    fn readHeader(self: *TomlReader, config: *Config) Error!void {
        if (self.bytes[self.at] != '[') std.debug.panic("reading a table header at byte {d}, which is not '['", .{self.at});
        const start = self.at;
        self.at += 1;
        const name = self.readKey() orelse return self.fail("expected a table name after '['.", .{});
        if (std.mem.eql(u8, name, "paths")) {
            if (self.at >= self.bytes.len or self.bytes[self.at] != '.') return self.fail("'[paths]' needs a pattern for the files it covers, such as [paths.\"tests/**\"].", .{});
            self.at += 1;
            if (self.at >= self.bytes.len) return self.fail("expected a quoted pattern after '[paths.'.", .{});
            self.pending_glob = try self.readString("paths");
        }
        if (self.at >= self.bytes.len or self.bytes[self.at] != ']') return self.fail("expected ']' after '[{s}'.", .{name});
        self.at += 1;
        self.table = std.meta.stringToEnum(Table, name) orelse .root;
        if (self.table == .root) return self.fail("'[{s}]' isn't a table zanity knows; the tables are [infer] and [paths.\"<pattern>\"].", .{name});
        if (self.table == .paths) try self.readPathSection(config);
        if (self.at <= start) std.debug.panic("reading a table header at byte {d} consumed nothing", .{start});
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

    fn readPathSection(self: *TomlReader, config: *Config) Error!void {
        if (self.table != .paths) std.debug.panic("starting a [paths] section while reading [{t}]", .{self.table});
        const glob = self.pending_glob;
        if (glob.len == 0) return self.fail("a [paths] pattern is empty; name the files it covers, such as \"tests/**\".", .{});
        if (config.paths_len == max_path_sections) return self.fail("there are more than {d} [paths] sections; combine patterns that disable the same rules.", .{max_path_sections});
        config.paths[config.paths_len] = .{ .glob = glob };
        config.paths_len += 1;
        self.pending_glob = "";
        if (config.paths_len > max_path_sections) std.debug.panic("{d} [paths] sections in room for {d}", .{ config.paths_len, max_path_sections });
    }

    fn readPathSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (self.table != .paths or config.paths_len == 0) std.debug.panic("reading '{s}' as a [paths] setting outside a [paths] section", .{key});
        if (!std.mem.eql(u8, key, "disable")) return self.fail("'{s}' isn't a [paths] setting; the only one is disable.", .{key});
        const section = &config.paths[config.paths_len - 1];
        for (try self.readStrings(key)) |name| section.disable.include((rules.find(name) orelse return self.fail("'{s}' isn't a rule; the rules are listed in the README, and 'zanity check --rules' takes the same names.", .{name})).name);
        if (section.disable.len > rules.all.len) std.debug.panic("[paths.\"{s}\"] disables {d} rules of {d}", .{ section.glob, section.disable.len, rules.all.len });
    }

    fn readSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (key.len == 0) std.debug.panic("setting a key with no name at byte {d}", .{self.at});
        if (self.table == .paths) return self.readPathSetting(config, key);
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
                for (items) |name| if (!set.includeNamed(name)) return self.fail("'{s}' isn't a rule; the rules are listed in the README, 'all' names every rule, and 'zanity check --rules' takes the same names.", .{name});
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
