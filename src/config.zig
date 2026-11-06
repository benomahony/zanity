//! `zanity.toml`: which rules run, which paths are skipped, and which model `--infer` asks and
//! how hard. zanity uses the nearest one at or above the directory it runs in, up to the
//! repository root. Anything it doesn't recognise is an error naming the line, never ignored.
//!
//!     rules = ["recursion", "long-function"]   # run exactly these, like --rules
//!     disable = ["duplicate-name"]             # or: the defaults without these
//!     exclude = ["vendor/", "tests/golden/**"] # gitignore syntax, relative to this file
//!
//!     [infer]
//!     enabled = true                           # every check asks the model, as with --infer
//!     url = "http://127.0.0.1:8009"            # a System One server, such as a local Kev
//!     model = "kev-latest"                     # the model to ask
//!     api_key_env = "KEV_API_KEY"              # where the key is, if the server needs one
//!     concurrency = 16                         # requests to the model at once
//!     threshold = 0.9                          # how sure it must be to report
//!
//!     [questions."payment-without-key"]        # a --infer question of your own
//!     question = "Does the function charge a card without an idempotency key?"
//!     finding = "A card is charged without an idempotency key"
//!     fix = "Pass the order's id as the payment's idempotency key."
//!     severity = "error"                       # error, warning (the default) or information
//!     asks = "function"                        # function, errors, fixture, test, file or project
//!     threshold = 0.9                          # this question's own; [infer] threshold otherwise
//!
//!     [questions."cwe-15"]                     # or retune one of zanity's: its threshold,
//!     threshold = 0.95                         # question, finding, fix or severity
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
const toml = @import("config_toml.zig");
/// One step up a directory, as written in a relative path.
const parent_step = "../";
/// The most directories searched upwards for zanity.toml, deeper than any real path.
const max_parent_dirs = 64;

pub const file_name = "zanity.toml";
pub const max_excludes = 256;
pub const max_concurrency = 64;
/// Questions zanity.toml can define or retune.
pub const max_questions = 64;
pub const max_path_sections = 32;
pub const max_file_bytes = 1 << 20;
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
    /// Whether every check asks the model, as if run with `--infer`.
    infer: bool = false,
    /// The System One server `--infer` asks; TYPESAFE_BASE_URL, then TypeSafe's API, when unset.
    url: ?[]const u8 = null,
    /// The model to ask; TYPESAFE_DEFAULT_MODEL, then jev-latest, when unset.
    model: ?[]const u8 = null,
    /// The environment variable holding the API key; TYPESAFE_API_KEY when unset.
    api_key_env: ?[]const u8 = null,
    concurrency: ?u32 = null,
    /// How sure the model must be for a judgement to become a finding, above 0 and at most 1.
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
    /// The questions [questions."<name>"] tables define or retune, in the order they appear.
    questions: [max_questions]rules.Rule = undefined,
    questions_len: usize = 0,

    pub fn questionRules(self: *const Config) []const rules.Rule {
        if (self.questions_len > max_questions) assert.panic("{d} questions in room for {d}; the reader must refuse more", .{ self.questions_len, max_questions });
        if (self.questions_len > 0 and self.questions[0].question.len == 0) assert.panic("the question '{s}' has no question text; the reader checks each table is complete", .{self.questions[0].name});
        return self.questions[0..self.questions_len];
    }

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

    /// The rules to run: `rules` if given, else the defaults, and the strict rules when `strict`,
    /// without anything in `disable`.
    pub fn selection(self: *const Config, strict: bool) rules.Set {
        var chosen = self.rules orelse rules.Set.defaults();
        if (strict) chosen.includeTier(.strict);
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

    /// The config file, as a path from the working directory; NameTooLong when it doesn't fit `buffer`.
    pub fn configPath(self: Anchor, buffer: []u8) error{NameTooLong}![]const u8 {
        if (self.config.dir.len == 0) assert.panic("asking where zanity.toml is when none was found; check config.dir first", .{});
        var used: usize = 0;
        var parts = std.mem.tokenizeScalar(u8, self.below, '/');
        while (parts.next()) |_| {
            if (used + parent_step.len > buffer.len) return error.NameTooLong;
            @memcpy(buffer[used..][0..parent_step.len], parent_step);
            used += parent_step.len;
        }
        if (used + file_name.len > buffer.len) return error.NameTooLong;
        @memcpy(buffer[used..][0..file_name.len], file_name);
        if (used % parent_step.len != 0) assert.panic("wrote {d} bytes of '../' steps; each step is 3 bytes", .{used});
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

/// Reads `zanity.toml`'s text into a Config, failing with `problem` set on the first bad line.
pub const parseConfig = toml.parseConfig;

/// Finds and reads the nearest `zanity.toml` at or above the current directory, stopping at
/// the repository root. No file means an empty config.
pub fn initConfig(gpa: Allocator, io: Io) !Config {
    const start = try Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    if (!std.fs.path.isAbsolute(start)) assert.panic("looking for {s} from '{s}', which is relative; pass the real path", .{ file_name, start });
    var dir: ?[]const u8 = start;
    for (0..max_parent_dirs) |_| {
        const d = dir orelse break;
        const path = try std.fs.path.join(gpa, &.{ d, file_name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch null;
        if (bytes) |found| {
            var config = try toml.parseConfig(found);
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
