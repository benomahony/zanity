//! Git's ignore rules: `.gitignore` files in the checked tree and its
//! ancestors up to the repository root, plus `.git/info/exclude`.
const std = @import("std");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const memory = @import("memory.zig");

const Pattern = struct {
    /// Absolute directory the pattern is relative to, without a trailing slash.
    base: []const u8,
    glob: []const u8,
    negated: bool,
    directories_only: bool,
    /// Matches against the whole path below `base` rather than the basename.
    anchored: bool,
};

pub const Kind = enum { file, directory };

pub const Ignore = struct {
    patterns: memory.Bounded(Pattern),
    text: memory.Text,
    file: []u8,

    pub fn initIgnore(gpa: Allocator, limits: memory.Limits) Allocator.Error!Ignore {
        if (limits.ignore_patterns == 0) assert.panic("memory.Limits.ignore_patterns is 0, so no .gitignore line could be honoured; set it above 0", .{});
        if (limits.ignore_bytes == 0) assert.panic("memory.Limits.ignore_bytes is 0, so no .gitignore file could be read; set it above 0", .{});
        return .{
            .patterns = try .initBounded(gpa, limits.ignore_patterns, "ignore patterns"),
            .text = try .initText(gpa, limits.ignore_bytes),
            .file = try memory.reserve(gpa, u8, limits.ignore_bytes),
        };
    }

    /// Loads the ignore files that apply above `root`, an absolute directory:
    /// every ancestor's `.gitignore` up to the repository root and its `.git/info/exclude`.
    pub fn loadAncestors(self: *Ignore, io: Io, root: []const u8) !void {
        if (!std.fs.path.isAbsolute(root)) assert.panic("ignore files are found by walking up from '{s}', which is relative; pass the directory's real path", .{root});
        var chain: [64][]const u8 = undefined;
        var depth: usize = 0;
        var dir: ?[]const u8 = root;
        const repository = while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            if (depth == chain.len) break null;
            chain[depth] = d;
            depth += 1;
            if (exists(io, d, ".git")) break d;
        } else null;
        const top = repository orelse return;
        try self.loadFile(io, top, ".git/info/exclude");
        for (1..depth) |i| try self.loadFile(io, chain[depth - i], ".gitignore");
        if (depth == 0) assert.panic("walking up from '{s}' visited no directory; it should visit at least '{s}' itself", .{ root, root });
    }

    /// Loads `name` inside the absolute directory `base`, if it exists.
    pub fn loadFile(self: *Ignore, io: Io, base: []const u8, name: []const u8) !void {
        if (!std.fs.path.isAbsolute(base)) assert.panic("'{s}/{s}' has a relative directory; ignore patterns are matched against absolute paths, so pass the real path", .{ base, name });
        if (name.len == 0) assert.panic("asked to load an ignore file with no name from '{s}'; pass '.gitignore' or '.git/info/exclude'", .{base});
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ base, name }) catch return;
        const bytes = Io.Dir.cwd().readFile(io, path, self.file) catch return;
        if (bytes.len == self.file.len) {
            memory.exceeded = "bytes in one ignore file";
            return error.LimitExceeded;
        }
        try self.parse(try self.text.copy(base), bytes);
    }

    /// Adds one pattern in gitignore syntax, relative to the absolute directory `base`, as zanity.toml's `exclude` does.
    pub fn exclude(self: *Ignore, base: []const u8, glob: []const u8) !void {
        if (!std.fs.path.isAbsolute(base)) assert.panic("excluding '{s}' relative to '{s}', which is relative; pass the real path", .{ glob, base });
        if (glob.len == 0) assert.panic("excluding an empty pattern relative to '{s}'; readStrings() must refuse empty exclude patterns", .{base});
        try self.parse(try self.text.copy(base), glob);
    }

    fn parse(self: *Ignore, base: []const u8, bytes: []const u8) !void {
        if (base.len == 0) assert.panic("parsing ignore patterns with no directory to anchor them; pass the directory the ignore file is in", .{});
        const before = self.patterns.len;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trimEnd(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const negated = line[0] == '!';
            if (negated) line = line[1..];
            if (line.len > 0 and line[0] == '\\') line = line[1..];
            const directories_only = std.mem.endsWith(u8, line, "/");
            if (directories_only) line = line[0 .. line.len - 1];
            const anchored = std.mem.indexOfScalar(u8, line, '/') != null;
            if (line.len > 0 and line[0] == '/') line = line[1..];
            if (line.len == 0) continue;
            try self.patterns.add(.{ .base = base, .glob = try self.text.copy(line), .negated = negated, .directories_only = directories_only, .anchored = anchored });
        }
        if (self.patterns.len < before) assert.panic("parsing the ignore file in {s} removed patterns: {d} before, {d} after; parse() must only add patterns", .{ base, before, self.patterns.len });
    }

    /// Whether the entry at absolute `path` is ignored. The last matching pattern decides.
    pub fn ignored(self: *const Ignore, path: []const u8, kind: Kind) bool {
        if (!std.fs.path.isAbsolute(path)) assert.panic("asked whether '{s}' is ignored, but ignore patterns match absolute paths; join it to the walk's real root first", .{path});
        if (self.patterns.len > self.patterns.capacity()) assert.panic("{d} ignore patterns recorded in room for {d}; raise memory.Limits for ignore patterns, or trim the ignore files", .{ self.patterns.len, self.patterns.capacity() });
        var result = false;
        for (self.patterns.items()) |p| {
            if (p.directories_only and kind != .directory) continue;
            if (!std.mem.startsWith(u8, path, p.base) or path.len <= p.base.len + 1 or path[p.base.len] != '/') continue;
            const relative = path[p.base.len + 1 ..];
            const subject = if (p.anchored) relative else std.fs.path.basename(relative);
            if (matchPath(p.glob, subject)) result = !p.negated;
        }
        return result;
    }
};

fn exists(io: Io, dir: []const u8, name: []const u8) bool {
    if (!std.fs.path.isAbsolute(dir)) assert.panic("looking for '{s}' in relative directory '{s}'; pass the real path", .{ name, dir });
    if (name.len == 0) assert.panic("asked whether an unnamed entry exists in {s}; pass a name such as '.git'", .{dir});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, name }) catch return false;
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const max_segments = 128;

fn segments(path: []const u8, out: *[max_segments][]const u8) ?[]const []const u8 {
    if (path.len == 0) assert.panic("asked to split an empty path into segments; ignored() only passes paths below a pattern's directory", .{});
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| : (count += 1) {
        if (count == out.len) return null;
        out[count] = segment;
    }
    if (count == 0) assert.panic("'{s}' split into no segments; splitting always yields at least one", .{path});
    return out[0..count];
}

/// Matches `/`-separated segments, where a `**` segment spans any number of segments.
pub fn matchPath(glob: []const u8, path: []const u8) bool {
    if (glob.len == 0) assert.panic("matching '{s}' against an empty ignore pattern; parse() drops empty lines", .{path});
    if (path.len == 0) assert.panic("matching ignore pattern '{s}' against an empty path; ignored() only passes paths below the pattern's directory", .{glob});
    var glob_buffer: [max_segments][]const u8 = undefined;
    var path_buffer: [max_segments][]const u8 = undefined;
    const gs = segments(glob, &glob_buffer) orelse return false;
    const ps = segments(path, &path_buffer) orelse return false;
    var gi: usize = 0;
    var pi: usize = 0;
    var star: ?usize = null;
    var star_path: usize = 0;
    while (gi < gs.len or pi < ps.len) {
        if (gi < gs.len and std.mem.eql(u8, gs[gi], "**")) {
            star = gi;
            star_path = pi;
            gi += 1;
            continue;
        }
        if (gi < gs.len and pi < ps.len and (if (gs[gi].len == 0) ps[pi].len == 0 else matchSegment(gs[gi], ps[pi]))) {
            gi += 1;
            pi += 1;
            continue;
        }
        const s = star orelse return false;
        if (star_path >= ps.len) return false;
        star_path += 1;
        gi = s + 1;
        pi = star_path;
    }
    if (gi != gs.len or pi != ps.len) assert.panic("matching '{s}' against '{s}' stopped at segment {d} of {d} and {d} of {d}; matchPath() must consume both lists or return false, so check its exits", .{ glob, path, gi, gs.len, pi, ps.len });
    return true;
}

/// Matches one segment with `*`, `?` and `[...]` classes; nothing crosses a `/`.
pub fn matchSegment(glob: []const u8, name: []const u8) bool {
    if (glob.len == 0) assert.panic("matching '{s}' against an empty segment pattern; matchPath handles empty segments itself, so call matchSegment() only with a non-empty pattern", .{name});
    var gi: usize = 0;
    var ni: usize = 0;
    var star: ?usize = null;
    var star_name: usize = 0;
    while (ni < name.len or gi < glob.len) {
        if (gi < glob.len and glob[gi] == '*') {
            star = gi;
            star_name = ni;
            gi += 1;
            continue;
        }
        if (gi < glob.len and ni < name.len) if (step(glob, gi, name[ni])) |width| {
            gi += width;
            ni += 1;
            continue;
        };
        const s = star orelse return false;
        if (star_name >= name.len) return false;
        star_name += 1;
        gi = s + 1;
        ni = star_name;
    }
    if (gi != glob.len) assert.panic("matching '{s}' against '{s}' stopped at byte {d} of the pattern; matchSegment() must consume the whole pattern or return false, so check its exits", .{ glob, name, gi });
    return true;
}

/// How many pattern bytes at `glob[gi]` match the one name byte `c`, or null if they don't.
fn step(glob: []const u8, gi: usize, c: u8) ?usize {
    if (gi >= glob.len) assert.panic("stepping past the end of pattern '{s}' at byte {d}; call step() only while bytes of the pattern remain", .{ glob, gi });
    const width: ?usize = switch (glob[gi]) {
        '?' => 1,
        '[' => matchClass(glob[gi..], c),
        '\\' => if (gi + 1 < glob.len and glob[gi + 1] == c) 2 else null,
        else => if (glob[gi] == c) 1 else null,
    };
    if (width) |w| if (gi + w > glob.len) assert.panic("a {d}-byte step at byte {d} runs past the end of '{s}'; step() must measure a [...] class up to its ']', so check how it finds the end", .{ w, gi, glob });
    return width;
}

/// The width of the class at the start of `glob` if it admits `c`, else null.
fn matchClass(glob: []const u8, c: u8) ?usize {
    if (glob.len == 0 or glob[0] != '[') assert.panic("matching a class, but '{s}' does not start with '['; call matchClass() only at a '['", .{glob});
    const negated = glob.len > 1 and (glob[1] == '!' or glob[1] == '^');
    const scan = scanClass(glob, if (negated) 2 else 1, c);
    if (scan.end >= glob.len) return null;
    if (glob[scan.end] != ']') assert.panic("the class in '{s}' should close at byte {d}, but has '{c}' there; scanClass() must return the index of the class's ']'", .{ glob, scan.end, glob[scan.end] });
    return if (scan.hit != negated) scan.end + 1 else null;
}

/// Walks a class's members from `start` to its `]`, noting whether any single byte or range admits `c`.
fn scanClass(glob: []const u8, start: usize, c: u8) struct { end: usize, hit: bool } {
    if (start == 0 or start > 2) assert.panic("a class's members start at byte 1 or 2 of '{s}', not {d}; scanClass() must start after '[' and an optional '!' or '^'", .{ glob, start });
    var i = start;
    var hit = false;
    while (i < glob.len and (i == start or glob[i] != ']')) {
        const range = i + 2 < glob.len and glob[i + 1] == '-' and glob[i + 2] != ']';
        hit = hit or (if (range) c >= glob[i] and c <= glob[i + 2] else c == glob[i]);
        i += if (range) 3 else 1;
    }
    if (i < start) assert.panic("scanning the class in '{s}' went backwards from {d} to {d}; scanClass() must only scan forward", .{ glob, start, i });
    return .{ .end = i, .hit = hit };
}

test "segments match stars, single characters and classes" {
    try std.testing.expect(matchSegment("*.pyc", "a.pyc"));
    try std.testing.expect(!matchSegment("*.pyc", "a.py"));
    try std.testing.expect(matchSegment("zig-*", "zig-pkg"));
    try std.testing.expect(matchSegment("a?c", "abc"));
    try std.testing.expect(matchSegment("[abc]x", "bx"));
    try std.testing.expect(!matchSegment("[!abc]x", "bx"));
    try std.testing.expect(matchSegment("[a-z]*", "q9"));
    try std.testing.expect(matchSegment("*", ""));
}

test "paths match double stars across any number of directories" {
    try std.testing.expect(matchPath("foo/bar", "foo/bar"));
    try std.testing.expect(!matchPath("foo/bar", "foo/bar/baz"));
    try std.testing.expect(matchPath("**/bar", "bar"));
    try std.testing.expect(matchPath("**/bar", "a/b/bar"));
    try std.testing.expect(matchPath("a/**/b", "a/b"));
    try std.testing.expect(matchPath("a/**/b", "a/x/y/b"));
    try std.testing.expect(!matchPath("a/**/b", "a/x/y/c"));
    try std.testing.expect(matchPath("a/**", "a/x/y"));
    try std.testing.expect(matchPath("*/x", "d/x"));
    try std.testing.expect(!matchPath("*/x", "d/e/x"));
}

test "the last matching pattern decides and negation re-includes" {
    var ignore = try Ignore.initIgnore(std.testing.allocator, .{ .ignore_patterns = 16, .ignore_bytes = 1024 });
    defer std.testing.allocator.free(ignore.patterns.buffer);
    defer std.testing.allocator.free(ignore.text.buffer);
    defer std.testing.allocator.free(ignore.file);
    try ignore.parse("/r", "# comment\n*.log\n!keep.log\nbuild/\n/top.py\ndocs/**/*.md\n");
    try std.testing.expect(ignore.ignored("/r/a/x.log", .file));
    try std.testing.expect(!ignore.ignored("/r/a/keep.log", .file));
    try std.testing.expect(ignore.ignored("/r/a/build", .directory));
    try std.testing.expect(!ignore.ignored("/r/a/build", .file));
    try std.testing.expect(ignore.ignored("/r/top.py", .file));
    try std.testing.expect(!ignore.ignored("/r/a/top.py", .file));
    try std.testing.expect(ignore.ignored("/r/docs/a/b/c.md", .file));
    try std.testing.expect(!ignore.ignored("/other/x.log", .file));
}
