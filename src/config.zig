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
//!     threshold = 0.9                          # how sure it must be to report
//!
//!     [paths."src/*_test.zig"]                 # gitignore syntax, relative to this file
//!     disable = ["process-in-test"]            # these rules don't report here
//!
//!     [vocabulary]                             # the project's words for things
//!     forbidden = ["util", "manager"]          # never in a name
//!
//!     [vocabulary.synonyms]                    # the canonical word = the words it replaces
//!     customer = ["client", "user"]
//!
//!     [contexts.billing]                       # also [domains.<name>]; contexts apply after
//!     include = ["src/billing/**"]             # domains, so a context's words win
//!     forbidden = ["discount"]
//!
//!     [contexts.billing.synonyms]
//!     invoice = ["bill", "statement"]
const std = @import("std");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rules = @import("rules.zig");
const ignore = @import("ignore.zig");

pub const file_name = "zanity.toml";
pub const max_excludes = 256;
pub const max_concurrency = 64;
pub const max_path_sections = 32;
const max_file_bytes = 1 << 20;
pub const max_terms = 512;
pub const max_scopes = 32;
pub const max_scope_globs = 16;
pub const max_directional = 32;

/// A word of the project's vocabulary: banned outright when `canonical` is empty, otherwise an
/// alias to be replaced by `canonical`. `scope` is 0 for the whole project, or one more than the
/// index of the domain or context it belongs to.
pub const Term = struct { scope: u8, word: []const u8, canonical: []const u8 = "", line: u32 };

/// A `[domains.<name>]` or `[contexts.<name>]` table: a part of the code with its own words.
pub const Scope = struct {
    name: []const u8,
    context: bool,
    line: u32,
    include: [max_scope_globs][]const u8 = undefined,
    include_len: usize = 0,

    pub fn globs(self: *const Scope) []const []const u8 {
        if (self.include_len > max_scope_globs) assert.panic("[{s}] has {d} include patterns in room for {d}; TomlReader must refuse the pattern past max_scope_globs, so check where it adds include patterns", .{ self.name, self.include_len, max_scope_globs });
        if (self.name.len == 0) assert.panic("a domain or context has no name; TomlReader must reject an empty table name such as [domains.\"\"], so check where it reads table headers", .{});
        return self.include[0..self.include_len];
    }
};

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
    /// How sure TypeSafe must be for a judgement to become a finding, above 0 and at most 1.
    threshold: ?f64 = null,
    paths: [max_path_sections]PathRules = undefined,
    paths_len: usize = 0,
    terms: [max_terms]Term = undefined,
    terms_len: usize = 0,
    scopes: [max_scopes]Scope = undefined,
    scopes_len: usize = 0,
    /// Words that give a name its direction, so `us_to_uk` and `uk_to_us` aren't drift; none for the defaults.
    directional: [max_directional][]const u8 = undefined,
    directional_len: usize = 0,

    pub fn vocabulary(self: *const Config) []const Term {
        if (self.terms_len > max_terms) assert.panic("{d} vocabulary terms in room for {d}; TomlReader must refuse the term past max_terms, so check where it adds terms", .{ self.terms_len, max_terms });
        if (self.scopes_len > max_scopes) assert.panic("{d} domains and contexts in room for {d}; TomlReader must refuse the table past max_scopes, so check where it adds domains and contexts", .{ self.scopes_len, max_scopes });
        return self.terms[0..self.terms_len];
    }

    pub fn domainsAndContexts(self: *const Config) []const Scope {
        if (self.scopes_len > max_scopes) assert.panic("{d} domains and contexts in room for {d}; TomlReader must refuse the table past max_scopes, so check where it adds domains and contexts", .{ self.scopes_len, max_scopes });
        if (self.scopes_len > 0 and self.dir.len == 0) assert.panic("{d} domains and contexts with no directory to anchor their patterns; initConfig() must set dir", .{self.scopes_len});
        return self.scopes[0..self.scopes_len];
    }

    /// The domain or context the file at `relative`, a path from this file's directory, belongs
    /// to, as an index into domainsAndContexts(); a context wins over a domain, a later one over an
    /// earlier one. Null when it belongs to none.
    pub fn scopeOf(self: *const Config, relative: []const u8) ?usize {
        if (relative.len == 0) assert.panic("asked which domain an empty path belongs to; pass the path from the config's folder", .{});
        var found: ?usize = null;
        for (self.domainsAndContexts(), 0..) |scope, i| {
            const matches = for (scope.globs()) |glob| {
                if (pathMatches(glob, relative)) break true;
            } else false;
            if (!matches) continue;
            if (found) |f| if (self.scopes[f].context and !scope.context) continue;
            found = i;
        }
        if (found) |f| if (f >= self.scopes_len) assert.panic("chose scope {d} of {d}; scopeOf() picks only listed scopes", .{ f, self.scopes_len });
        return found;
    }

    pub fn pathRules(self: *const Config) []const PathRules {
        if (self.paths_len > max_path_sections) assert.panic("{d} [paths] sections in room for {d}; readPathSection() must refuse sections past max_path_sections", .{ self.paths_len, max_path_sections });
        if (self.paths_len > 0 and self.dir.len == 0) assert.panic("{d} [paths] sections with no directory to anchor them; initConfig() must set dir to the folder holding zanity.toml", .{self.paths_len});
        return self.paths[0..self.paths_len];
    }

    /// Whether a `[paths]` section turns `rule` off for the file at `relative`, a path from this
    /// file's directory. As in gitignore, a pattern without a `/` matches the file's name at any
    /// depth, and one ending in `/` matches everything under that directory.
    pub fn disabledAt(self: *const Config, relative: []const u8, rule: []const u8) bool {
        if (relative.len == 0) assert.panic("asked whether '{s}' is disabled for an empty path; dropDisabled() must skip findings whose path is outside the config's folder", .{rule});
        if (rules.find(rule) == null) assert.panic("asked whether '{s}', which is not a rule, is disabled at '{s}'; pass a rule name from rules.all", .{ rule, relative });
        for (self.pathRules()) |section| {
            if (!section.disable.enabled(rule)) continue;
            if (pathMatches(section.glob, relative)) return true;
        }
        return false;
    }

    pub fn excludes(self: *const Config) []const []const u8 {
        if (self.exclude_len > max_excludes) assert.panic("{d} exclude patterns in room for {d}; readStrings() must reject lists longer than max_excludes", .{ self.exclude_len, max_excludes });
        if (self.exclude_len > 0 and self.dir.len == 0) assert.panic("{d} exclude patterns with no directory to anchor them; initConfig() must set dir to the folder holding zanity.toml", .{self.exclude_len});
        return self.exclude[0..self.exclude_len];
    }

    /// The rules to run: `rules` if given, else the defaults, without anything in `disable`.
    pub fn selection(self: *const Config) rules.Set {
        const chosen = self.rules orelse rules.Set.defaults();
        var kept: rules.Set = .{};
        for (chosen.names()) |name| if (!self.disable.enabled(name)) kept.include(name);
        if (kept.len > chosen.len) assert.panic("disabling rules kept {d} of {d}, more than were chosen; selection() must copy only chosen rules, so check its loop", .{ kept.len, chosen.len });
        if (kept.len + self.disable.len < chosen.len) assert.panic("kept {d} of {d} rules after disabling {d}; disabling dropped extra rules, so selection() must skip only the rules in disable", .{ kept.len, chosen.len, self.disable.len });
        return kept;
    }
};

/// Where the working directory sits under the folder holding zanity.toml, so the paths zanity
/// was given can be matched against the file's patterns.
pub const Anchor = struct {
    config: *const Config,
    /// The working directory, from the config's folder; empty when they are the same.
    below: []const u8,

    /// `path`, as zanity was given it, from the config's folder; empty when it is outside it.
    pub fn relative(self: Anchor, path: []const u8, buffer: []u8) []const u8 {
        if (path.len == 0) assert.panic("anchoring an empty path; findings and definitions always have one", .{});
        var trimmed = path;
        while (std.mem.startsWith(u8, trimmed, "./")) trimmed = trimmed[2..];
        if (std.fs.path.isAbsolute(trimmed)) {
            const dir = self.config.dir;
            const inside = std.mem.startsWith(u8, trimmed, dir) and trimmed.len > dir.len and trimmed[dir.len] == '/';
            return if (inside) trimmed[dir.len + 1 ..] else "";
        }
        if (self.below.len == 0) return trimmed;
        const joined = std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.below, trimmed }) catch "";
        if (joined.len > 0 and joined.len <= trimmed.len) assert.panic("joining '{s}' under '{s}' gave '{s}', no longer than the path; relative() must prefix it", .{ trimmed, self.below, joined });
        return joined;
    }

    /// The config file, as a path from the working directory.
    pub fn configPath(self: Anchor, buffer: []u8) []const u8 {
        if (self.config.dir.len == 0) assert.panic("asking where zanity.toml is when none was found; check config.dir first", .{});
        var used: usize = 0;
        var parts = std.mem.tokenizeScalar(u8, self.below, '/');
        while (parts.next()) |_| {
            if (used + 3 > buffer.len) return file_name;
            @memcpy(buffer[used..][0..3], "../");
            used += 3;
        }
        if (used + file_name.len > buffer.len) return file_name;
        @memcpy(buffer[used..][0..file_name.len], file_name);
        if (used % 3 != 0) assert.panic("wrote {d} bytes of '../' steps; each step is 3 bytes", .{used});
        return buffer[0 .. used + file_name.len];
    }
};

fn pathMatches(glob: []const u8, relative: []const u8) bool {
    if (glob.len == 0) assert.panic("matching '{s}' against an empty [paths] pattern; TomlReader must reject [paths.\"\"], so check where it reads table headers", .{relative});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trimmed = std.mem.trimStart(u8, glob, "/");
    const whole = if (std.mem.endsWith(u8, trimmed, "/"))
        std.fmt.bufPrint(&buffer, "{s}**", .{trimmed}) catch return false
    else if (std.mem.indexOfScalar(u8, trimmed, '/') == null)
        std.fmt.bufPrint(&buffer, "**/{s}", .{trimmed}) catch return false
    else
        trimmed;
    if (whole.len < trimmed.len) assert.panic("widening the [paths] pattern '{s}' shortened it to '{s}'; pathMatches() must only add to a pattern, so check its format calls", .{ glob, whole });
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
    if (!std.fs.path.isAbsolute(start)) assert.panic("looking for {s} from '{s}', which is relative; pass the real path", .{ file_name, start });
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
    if (start.len == 0) assert.panic("searched for {s} from an empty directory; initConfig() must start from the real path of the working directory", .{file_name});
    return .{};
}

fn isRepositoryRoot(io: Io, dir: []const u8) bool {
    if (dir.len == 0) assert.panic("checking whether an empty path is a repository root; initConfig() must stop at the filesystem root before calling it", .{});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const git = std.fmt.bufPrint(&buffer, "{s}/.git", .{dir}) catch return false;
    Io.Dir.cwd().access(io, git, .{}) catch return false;
    if (git.len <= dir.len) assert.panic("'{s}' is no longer than its directory '{s}'; isRepositoryRoot() must join .git onto the directory", .{ git, dir });
    return true;
}

/// Parses the TOML zanity understands, reporting the first problem in `problem`. Strings are
/// decoded in place, so `bytes` must outlive the config.
pub fn parseConfig(bytes: []u8) Error!Config {
    if (bytes.len > max_file_bytes) assert.panic("{s} is {d} bytes; initConfig reads at most {d}", .{ file_name, bytes.len, max_file_bytes });
    var reader: TomlReader = .{ .bytes = bytes };
    var config: Config = .{};
    for (0..bytes.len + 1) |_| {
        reader.skipBlank();
        if (reader.at == bytes.len) break;
        try reader.readEntry(&config);
    }
    if (reader.at != bytes.len) assert.panic("stopped parsing {s} at byte {d} of {d}; the loop in parseConfig() must read to the end of the file", .{ file_name, reader.at, bytes.len });
    return config;
}

const Table = enum { root, infer, paths, vocabulary, synonyms, scope };

const max_items = max_excludes;

const TomlReader = struct {
    bytes: []u8,
    at: usize = 0,
    table: Table = .root,
    items: [max_items][]const u8 = undefined,
    /// The pattern of a `[paths."<glob>"]` header, until its section is added.
    pending_glob: []const u8 = "",
    /// The vocabulary table being read: 0 for [vocabulary], else one more than a scope's index.
    scope: u8 = 0,

    fn line(self: *const TomlReader) u32 {
        if (self.at > self.bytes.len) assert.panic("counting the line of byte {d} in a {d}-byte file; nothing may move self.at past the end, so check the last place that advanced it", .{ self.at, self.bytes.len });
        const counted = std.mem.count(u8, self.bytes[0..self.at], "\n") + 1;
        if (counted > self.bytes.len + 1) assert.panic("counted {d} lines in {d} bytes, more lines than bytes plus one; count only the newlines before self.at", .{ counted, self.bytes.len });
        return @intCast(counted);
    }

    fn fail(self: *const TomlReader, comptime fmt: []const u8, args: anytype) Error {
        if (self.at > self.bytes.len) assert.panic("reporting a problem at byte {d} of a {d}-byte file; fail() must be called with the reader inside the file", .{ self.at, self.bytes.len });
        const written = std.fmt.bufPrint(&problem, "{s}:{d}: " ++ fmt, .{ file_name, self.line() } ++ args) catch problem[0..];
        problem_len = written.len;
        if (problem_len <= file_name.len) assert.panic("described a config problem as '{s}', with no detail; give the fail() call a description of what is wrong", .{problem[0..problem_len]});
        return error.InvalidConfig;
    }

    /// The byte at the reading position, or null at the end of the file.
    fn peek(self: *const TomlReader) ?u8 {
        if (self.at > self.bytes.len) assert.panic("reading at byte {d} of a {d}-byte file; nothing may move self.at past the end", .{ self.at, self.bytes.len });
        if (self.at == self.bytes.len) return null;
        const c = self.bytes[self.at];
        if (self.at >= self.bytes.len) assert.panic("read byte {d} of a {d}-byte file; peek() must check the end before reading", .{ self.at, self.bytes.len });
        return c;
    }

    /// Skips spaces and tabs, staying on the line.
    fn skipSpaces(self: *TomlReader) void {
        const start = self.at;
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.at += 1;
        }
        if (self.at < start) assert.panic("skipping spaces moved back from byte {d} to {d}; skipSpaces() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("skipping spaces ran to byte {d} of {d}; skipSpaces() must stop at the end of the file", .{ self.at, self.bytes.len });
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
        if (self.at < start) assert.panic("skipping blanks moved back from byte {d} to {d}; skipBlank() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("skipping blanks ran to byte {d} of {d}; skipBlank() must stop at the end of the file", .{ self.at, self.bytes.len });
    }

    /// Skips spaces and tabs, then requires the rest of the line to be empty or a comment.
    fn endLine(self: *TomlReader) Error!void {
        const start = self.at;
        self.skipSpaces();
        if (self.peek() == '#') self.at = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len;
        if (self.peek()) |c| if (c != '\n' and c != '\r') {
            return self.fail("unexpected '{c}' after a value; put each setting on its own line.", .{c});
        };
        if (self.at < start) assert.panic("ending a line moved back from byte {d} to {d}; endLine() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("ending a line ran to byte {d} of {d}; endLine() must stop at the end of the file", .{ self.at, self.bytes.len });
    }

    fn readEntry(self: *TomlReader, config: *Config) Error!void {
        if (self.at >= self.bytes.len) assert.panic("reading an entry at byte {d} of a {d}-byte file; parseConfig() must stop before the end of the file", .{ self.at, self.bytes.len });
        const start = self.at;
        if (self.bytes[self.at] == '[') {
            try self.readHeader(config);
        } else {
            const key = self.readKey() orelse return self.fail("expected a setting such as 'rules = [...]' or a table such as '[infer]'.", .{});
            self.skipSpaces();
            if (self.peek() != '=') return self.fail("expected '=' after '{s}'; write each setting as name = value.", .{key});
            self.at += 1;
            self.skipSpaces();
            try self.readSetting(config, key);
        }
        try self.endLine();
        if (self.at <= start) assert.panic("reading an entry at byte {d} consumed nothing; readEntry() must consume at least the key or header it read", .{start});
    }

    /// Reads a table header: `[infer]`, or `[paths."<glob>"]`, which starts a new section.
    fn readHeader(self: *TomlReader, config: *Config) Error!void {
        if (self.bytes[self.at] != '[') assert.panic("reading a table header at byte {d}, which is not '['; call readHeader() only at a '['", .{self.at});
        const start = self.at;
        self.at += 1;
        const name = self.readKey() orelse return self.fail("expected a table name after '['; write [infer] or [paths.\"<pattern>\"].", .{});
        if (std.mem.eql(u8, name, "vocabulary") or std.mem.eql(u8, name, "domains") or std.mem.eql(u8, name, "contexts")) {
            try self.readVocabularyHeader(config, name);
            if (self.at <= start) assert.panic("reading a vocabulary header at byte {d} consumed nothing", .{start});
            return;
        }
        if (std.mem.eql(u8, name, "paths")) {
            if (self.peek() != '.') return self.fail("'[paths]' needs a pattern for the files it covers, such as [paths.\"tests/**\"].", .{});
            self.at += 1;
            if (self.at >= self.bytes.len) return self.fail("expected a quoted pattern after '[paths.'; write it as [paths.\"tests/**\"].", .{});
            self.pending_glob = try self.readString("paths");
        }
        if (self.peek() != ']') return self.fail("expected ']' after '[{s}'; close the table name with ']'.", .{name});
        self.at += 1;
        self.table = std.meta.stringToEnum(Table, name) orelse .root;
        if (self.table == .root or self.table == .vocabulary) return self.fail("'[{s}]' isn't a table zanity knows; the tables are [infer], [paths.\"<pattern>\"], [vocabulary], [domains.<name>] and [contexts.<name>].", .{name});
        if (self.table == .paths) try self.readPathSection(config);
        if (self.at <= start) assert.panic("reading a table header at byte {d} consumed nothing; readHeader() must consume at least the '[' it starts at", .{start});
    }

    /// `[vocabulary]`, `[vocabulary.synonyms]`, `[domains.<name>]`, `[contexts.<name>]`, or either
    /// of those with `.synonyms`; a domain or context is added when its own table starts.
    fn readVocabularyHeader(self: *TomlReader, config: *Config, kind: []const u8) Error!void {
        if (kind.len == 0) assert.panic("reading a vocabulary table with no kind; readHeader() passes vocabulary, domains or contexts", .{});
        const start = self.at;
        self.scope = 0;
        if (!std.mem.eql(u8, kind, "vocabulary")) {
            const header_line = self.line();
            if (self.peek() != '.') return self.fail("'[{s}]' needs a name, such as [{s}.billing].", .{ kind, kind });
            self.at += 1;
            const name = (if (self.peek() == '"') try self.readString(kind) else self.readKey()) orelse return self.fail("expected a name after '[{s}.', such as [{s}.billing].", .{ kind, kind });
            self.scope = try self.scopeNamed(config, .{ .name = name, .context = std.mem.eql(u8, kind, "contexts"), .line = header_line });
        }
        self.table = if (self.scope == 0) .vocabulary else .scope;
        if (self.peek() == '.') {
            self.at += 1;
            const part = self.readKey() orelse "";
            if (!std.mem.eql(u8, part, "synonyms")) return self.fail("'[{s}.{s}]' isn't a table zanity knows; the only one inside [{s}] is synonyms.", .{ kind, part, kind });
            self.table = .synonyms;
        }
        if (self.peek() != ']') return self.fail("expected ']' after the [{s}] table's name; close it with ']'.", .{kind});
        self.at += 1;
        if (self.at <= start) assert.panic("reading the [{s}] header consumed nothing; it must consume at least the ']'", .{kind});
    }

    /// The scope number of the domain or context called `name`, adding it when it is new.
    fn scopeNamed(self: *TomlReader, config: *Config, wanted: Scope) Error!u8 {
        if (wanted.name.len == 0) return self.fail("a domain or context name is empty; give it a name, such as [contexts.billing].", .{});
        if (wanted.line == 0) assert.panic("the [{s}] table has no line; line() counts from 1", .{wanted.name});
        for (config.scopes[0..config.scopes_len], 0..) |scope, i| {
            if (std.mem.eql(u8, scope.name, wanted.name) and scope.context == wanted.context) return @intCast(i + 1);
        }
        if (config.scopes_len == max_scopes) return self.fail("there are more than {d} domains and contexts; merge the ones that share their words.", .{max_scopes});
        config.scopes[config.scopes_len] = wanted;
        config.scopes_len += 1;
        if (config.scopes_len > max_scopes) assert.panic("{d} scopes in room for {d}; scopeNamed() must refuse more", .{ config.scopes_len, max_scopes });
        return @intCast(config.scopes_len);
    }

    fn addTerm(self: *TomlReader, config: *Config, term: Term) Error!void {
        if (term.scope > config.scopes_len) assert.panic("a term for scope {d} of {d}; scopeNamed() numbers each scope before its terms", .{ term.scope, config.scopes_len });
        if (term.word.len == 0) return self.fail("a vocabulary word is empty; remove it or write the word.", .{});
        if (config.terms_len == max_terms) return self.fail("the vocabulary has more than {d} words; keep the ones that matter most.", .{max_terms});
        config.terms[config.terms_len] = term;
        config.terms_len += 1;
        if (config.terms_len > max_terms) assert.panic("{d} terms in room for {d}; addTerm() must refuse more", .{ config.terms_len, max_terms });
    }

    /// A setting in [vocabulary], a domain or context, or one of their synonyms tables.
    fn readVocabularySetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (key.len == 0) assert.panic("a vocabulary setting with no name at byte {d}; readEntry() reads a key first", .{self.at});
        const at_line = self.line();
        if (self.table == .scope and self.scope == 0) assert.panic("reading '{s}' in a domain or context table without one; readVocabularyHeader() sets the scope", .{key});
        const items = try self.readStrings(key);
        if (self.table == .synonyms) {
            for (items) |alias| try self.addTerm(config, .{ .scope = self.scope, .word = alias, .canonical = key, .line = at_line });
            return;
        }
        if (std.mem.eql(u8, key, "forbidden")) {
            for (items) |word| try self.addTerm(config, .{ .scope = self.scope, .word = word, .line = at_line });
        } else if (self.table == .vocabulary and std.mem.eql(u8, key, "directional")) {
            if (items.len > max_directional) return self.fail("'directional' has more than {d} words; keep the ones names use.", .{max_directional});
            @memcpy(config.directional[0..items.len], items);
            config.directional_len = items.len;
        } else if (self.table == .scope and std.mem.eql(u8, key, "include")) {
            const scope = &config.scopes[self.scope - 1];
            if (items.len > max_scope_globs) return self.fail("[{s}] has more than {d} include patterns; use broader ones.", .{ scope.name, max_scope_globs });
            for (items) |glob| if (glob.len == 0) return self.fail("an include pattern of [{s}] is empty; name the files it covers.", .{scope.name});
            @memcpy(scope.include[0..items.len], items);
            scope.include_len = items.len;
        } else return self.fail("'{s}' isn't a setting here; [vocabulary] takes forbidden and directional, a domain or context takes include and forbidden, and a synonyms table takes canonical = [aliases].", .{key});
    }

    fn readKey(self: *TomlReader) ?[]const u8 {
        const start = self.at;
        while (self.at < self.bytes.len) : (self.at += 1) {
            const c = self.bytes[self.at];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
        }
        if (self.at < start) assert.panic("reading a key moved back from byte {d} to {d}; readKey() must only move self.at forward", .{ start, self.at });
        if (self.at > self.bytes.len) assert.panic("reading a key ran to byte {d} of {d}; readKey() must stop at the end of the file", .{ self.at, self.bytes.len });
        return if (self.at == start) null else self.bytes[start..self.at];
    }

    fn readPathSection(self: *TomlReader, config: *Config) Error!void {
        if (self.table != .paths) assert.panic("starting a [paths] section while reading [{t}]; readHeader() must set the table to paths before starting a section", .{self.table});
        const glob = self.pending_glob;
        if (glob.len == 0) return self.fail("a [paths] pattern is empty; name the files it covers, such as \"tests/**\".", .{});
        if (config.paths_len == max_path_sections) return self.fail("there are more than {d} [paths] sections; combine patterns that disable the same rules.", .{max_path_sections});
        config.paths[config.paths_len] = .{ .glob = glob };
        config.paths_len += 1;
        self.pending_glob = "";
        if (config.paths_len > max_path_sections) assert.panic("{d} [paths] sections in room for {d}; readPathSection() must refuse sections past max_path_sections", .{ config.paths_len, max_path_sections });
    }

    fn readPathSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (self.table != .paths or config.paths_len == 0) assert.panic("reading '{s}' as a [paths] setting outside a [paths] section; readSetting() must hand [paths] settings over only inside a section", .{key});
        if (!std.mem.eql(u8, key, "disable")) return self.fail("'{s}' isn't a [paths] setting; the only one is disable.", .{key});
        const section = &config.paths[config.paths_len - 1];
        for (try self.readStrings(key)) |name| section.disable.include((rules.find(name) orelse return self.fail("'{s}' isn't a rule; the rules are listed in the README, and 'zanity check --rules' takes the same names.", .{name})).name);
        if (section.disable.len > rules.all.len) assert.panic("[paths.\"{s}\"] disables {d} rules of {d}; Set.include() must add each rule once", .{ section.glob, section.disable.len, rules.all.len });
    }

    fn readInferSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (self.table != .infer) assert.panic("reading '{s}' as an [infer] setting outside [infer]; readSetting() must hand over only [infer] settings", .{key});
        const InferSetting = enum { concurrency, threshold };
        switch (std.meta.stringToEnum(InferSetting, key) orelse return self.fail("'{s}' isn't an [infer] setting; the settings are concurrency and threshold.", .{key})) {
            .concurrency => {
                const value = try self.readInteger(key);
                if (value < 1 or value > max_concurrency) return self.fail("concurrency is {d}; it must be between 1 and {d}.", .{ value, max_concurrency });
                config.concurrency = @intCast(value);
            },
            .threshold => {
                const value = try self.readDecimal(key);
                if (!(value > 0 and value <= 1)) return self.fail("threshold is {d}; it must be above 0 and at most 1, such as 0.9 to report only what TypeSafe is at least 90% sure of.", .{value});
                config.threshold = value;
            },
        }
        if (config.concurrency == null and config.threshold == null) assert.panic("read the [infer] setting '{s}' but stored nothing; each branch of readInferSetting() must store its value", .{key});
    }

    fn readSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (key.len == 0) assert.panic("setting a key with no name at byte {d}; readEntry() must read a key before calling readSetting()", .{self.at});
        if (self.table == .paths) return self.readPathSetting(config, key);
        if (self.table == .infer) return self.readInferSetting(config, key);
        if (self.table == .vocabulary or self.table == .synonyms or self.table == .scope) return self.readVocabularySetting(config, key);
        const Setting = enum { rules, disable, exclude };
        const which = std.meta.stringToEnum(Setting, key) orelse return self.fail("'{s}' isn't a setting; the settings are rules, disable, exclude and, under [infer], concurrency and threshold.", .{key});
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
        if (config.exclude_len > max_excludes) assert.panic("{d} exclude patterns in room for {d}; readStrings() must refuse lists longer than max_excludes", .{ config.exclude_len, max_excludes });
    }

    fn readInteger(self: *TomlReader, key: []const u8) Error!i64 {
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

    fn readDecimal(self: *TomlReader, key: []const u8) Error!f64 {
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
    fn readStrings(self: *TomlReader, key: []const u8) Error![]const []const u8 {
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
            self.items[count] = try self.readString(key);
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

    fn readString(self: *TomlReader, key: []const u8) Error![]const u8 {
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
};
