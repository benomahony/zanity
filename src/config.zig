//! `zanity.yaml`: which rules run, which paths are skipped, and which model `--infer` asks and
//! how hard. zanity uses the nearest folder at or above the directory it runs in, up to the
//! repository root, holding zanity.yaml or ddd.yaml. Anything it doesn't recognise is an error
//! naming the line, never ignored.
//!
//!     exclude: [vendor/, tests/golden/]        # gitignore syntax, relative to this file
//!     infer:
//!       url: http://127.0.0.1:8009             # a System One server, such as a local Kev
//!       model: kev-latest                      # the model to ask
//!       api_key_env: KEV_API_KEY               # where the key is, if the server needs one
//!       concurrency: 16                        # requests to the model at once
//!       threshold: 0.9                         # how sure it must be to report
//!     questions:
//!       payment-without-key:                   # a --infer question of your own
//!         question: Does the function charge a card without an idempotency key?
//!         finding: A card is charged without an idempotency key
//!         fix: Pass the order's id as the payment's idempotency key.
//!         severity: error                      # error, warning (the default) or information
//!         asks: function                       # function, errors, fixture, test, file or project
//!         threshold: 0.9                       # this question's own; infer threshold otherwise
//!       cwe-15:                                # or retune one of zanity's: its threshold,
//!         threshold: 0.95                      # question, finding, fix or severity
//!     paths:
//!       - files: "*_test.zig"                  # gitignore syntax, relative to this file
//!         disable: [process-in-test]           # these rules don't report here
//!     rules:
//!       select: [recursion, long-function]     # run exactly these, like --rules
//!       disable: [duplicate-name]              # without these
//!
//! The project's words for things, contexts and directional, may sit here too, or in ddd.yaml
//! beside it, which ddd.zig reads.
const std = @import("std");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rules = @import("rules.zig");
const ignore = @import("ignore.zig");
const ddd = @import("ddd.zig");
const yaml = @import("yaml.zig");

pub const file_name = "zanity.yaml";
pub const max_excludes = 256;
pub const max_concurrency = 64;
/// Questions zanity.yaml can define or retune.
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

/// A context of ddd.yaml with paths: a part of the code with its own words. `context` is false
/// for a domain, whose words a context's words override.
pub const Scope = struct {
    name: []const u8,
    context: bool,
    line: u32,
    include: [max_scope_globs][]const u8 = undefined,
    include_len: usize = 0,

    pub fn globs(self: *const Scope) []const []const u8 {
        if (self.include_len > max_scope_globs) assert.panic("the context '{s}' has {d} paths in room for {d}; the ddd.yaml reader must refuse the path past max_scope_globs, so check where it reads paths", .{ self.name, self.include_len, max_scope_globs });
        if (self.name.len == 0) assert.panic("a context with paths has no name; the ddd.yaml reader must reject it, so check addScope()", .{});
        return self.include[0..self.include_len];
    }
};

/// An entry of `paths:`: rules that don't report in the files its pattern matches.
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
    /// The file the glossary was read from, zanity.yaml or ddd.yaml; empty when there is none.
    glossary_file: []const u8 = "",
    /// The questions `questions:` defines or retunes, in the order they appear.
    questions: [max_questions]rules.Rule = undefined,
    questions_len: usize = 0,

    pub fn questionRules(self: *const Config) []const rules.Rule {
        if (self.questions_len > max_questions) assert.panic("{d} questions in room for {d}; the reader must refuse more", .{ self.questions_len, max_questions });
        if (self.questions_len > 0 and self.questions[0].question.len == 0) assert.panic("the question '{s}' has no question text; the reader checks each entry is complete", .{self.questions[0].name});
        return self.questions[0..self.questions_len];
    }

    pub fn vocabulary(self: *const Config) []const Term {
        if (self.terms_len > max_terms) assert.panic("{d} vocabulary terms in room for {d}; the ddd.yaml reader must refuse the term past max_terms, so check where it adds terms", .{ self.terms_len, max_terms });
        if (self.scopes_len > max_scopes) assert.panic("{d} domains and contexts in room for {d}; the ddd.yaml reader must refuse the context past max_scopes, so check addScope()", .{ self.scopes_len, max_scopes });
        return self.terms[0..self.terms_len];
    }

    pub fn domainsAndContexts(self: *const Config) []const Scope {
        if (self.scopes_len > max_scopes) assert.panic("{d} domains and contexts in room for {d}; the ddd.yaml reader must refuse the context past max_scopes, so check addScope()", .{ self.scopes_len, max_scopes });
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
        if (self.paths_len > max_path_sections) assert.panic("{d} paths entries in room for {d}; readPathSections() must refuse entries past max_path_sections", .{ self.paths_len, max_path_sections });
        if (self.paths_len > 0 and self.dir.len == 0) assert.panic("{d} paths entries with no directory to anchor them; initConfig() must set dir to the folder holding zanity.yaml", .{self.paths_len});
        return self.paths[0..self.paths_len];
    }

    /// Whether a `paths:` entry turns `rule` off for the file at `relative`, a path from this
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
        if (self.exclude_len > 0 and self.dir.len == 0) assert.panic("{d} exclude patterns with no directory to anchor them; initConfig() must set dir to the folder holding zanity.yaml", .{self.exclude_len});
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

/// Where the working directory sits under the folder holding zanity.yaml, so the paths zanity
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

    /// The file called `name` in the config's folder, as a path from the working directory.
    pub fn configPath(self: Anchor, name: []const u8, buffer: []u8) []const u8 {
        if (self.config.dir.len == 0) assert.panic("asking where {s} is when no config was found; check config.dir first", .{name});
        var used: usize = 0;
        var parts = std.mem.tokenizeScalar(u8, self.below, '/');
        while (parts.next()) |_| {
            if (used + 3 > buffer.len) return name;
            @memcpy(buffer[used..][0..3], "../");
            used += 3;
        }
        if (used + name.len > buffer.len) return name;
        @memcpy(buffer[used..][0..name.len], name);
        if (used % 3 != 0) assert.panic("wrote {d} bytes of '../' steps; each step is 3 bytes", .{used});
        return buffer[0 .. used + name.len];
    }
};

fn pathMatches(glob: []const u8, relative: []const u8) bool {
    if (glob.len == 0) assert.panic("matching '{s}' against an empty pattern; readPathSections() and the glossary reader must refuse one", .{relative});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trimmed = std.mem.trimStart(u8, glob, "/");
    const whole = if (std.mem.endsWith(u8, trimmed, "/"))
        std.fmt.bufPrint(&buffer, "{s}**", .{trimmed}) catch return false
    else if (std.mem.indexOfScalar(u8, trimmed, '/') == null)
        std.fmt.bufPrint(&buffer, "**/{s}", .{trimmed}) catch return false
    else
        trimmed;
    if (whole.len < trimmed.len) assert.panic("widening the pattern '{s}' shortened it to '{s}'; pathMatches() must only add to a pattern, so check its format calls", .{ glob, whole });
    return ignore.matchPath(whole, relative);
}

/// What was wrong with the file, for the error message: the line and what to change.
pub var problem: [512]u8 = undefined;
pub var problem_len: usize = 0;

pub const Error = error{InvalidConfig};

/// Finds and reads the nearest folder holding `zanity.yaml` or `ddd.yaml`, or both, at or above
/// the current directory, stopping at the repository root. No file means an empty config.
pub fn initConfig(gpa: Allocator, io: Io) !Config {
    const cwd = Io.Dir.cwd();
    const start = try cwd.realPathFileAlloc(io, ".", gpa);
    if (!std.fs.path.isAbsolute(start)) assert.panic("looking for {s} from '{s}', which is relative; pass the real path", .{ file_name, start });
    var dir: ?[]const u8 = start;
    for (0..64) |_| {
        const d = dir orelse break;
        const path = try std.fs.path.join(gpa, &.{ d, file_name });
        const bytes = cwd.readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch null;
        const glossary_path = try std.fs.path.join(gpa, &.{ d, ddd.glossary_file });
        const glossary = cwd.readFileAlloc(io, glossary_path, gpa, .limited(max_file_bytes)) catch null;
        if (bytes != null or glossary != null) {
            var config: Config = if (bytes) |found| try parseConfig(found) else .{};
            if (glossary) |found| try ddd.parseGlossary(found, &config);
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

/// Parses zanity.yaml, reporting the first problem in `problem`. Strings are decoded in place, so
/// `bytes` must outlive the config.
pub fn parseConfig(bytes: []u8) Error!Config {
    if (bytes.len > max_file_bytes) assert.panic("{s} is {d} bytes; initConfig reads at most {d}", .{ file_name, bytes.len, max_file_bytes });
    var text: yaml.Reader = .{ .bytes = bytes, .file = file_name };
    var reader: ConfigReader = .{ .text = &text };
    var config: Config = .{};
    var mapping = (try text.topKeys()) orelse return config;
    for (0..bytes.len) |_| try reader.readSetting(&config, (try text.nextKey(&mapping)) orelse break);
    try text.finish();
    if (text.at != bytes.len) assert.panic("stopped parsing {s} at byte {d} of {d}; finish() must refuse anything left", .{ file_name, text.at, bytes.len });
    return config;
}

const Section = enum { rules, infer };

const ConfigReader = struct {
    text: *yaml.Reader,

    /// A top-level setting, or a key of the glossary, which may sit here instead of in ddd.yaml.
    fn readSetting(self: *ConfigReader, config: *Config, key: []const u8) Error!void {
        const text = self.text;
        const start = text.at;
        if (std.mem.eql(u8, key, "exclude")) {
            const items = try text.readStrings(key, 0);
            for (items) |glob| if (glob.len == 0) return text.fail("an 'exclude' pattern is empty; remove it or name a path.", .{});
            @memcpy(config.exclude[0..items.len], items);
            config.exclude_len = items.len;
        } else if (std.mem.eql(u8, key, "rules")) {
            try self.readSection(config, key, .rules);
        } else if (std.mem.eql(u8, key, "infer")) {
            try self.readSection(config, key, .infer);
        } else if (std.mem.eql(u8, key, "paths")) {
            try self.readPathSections(config, key);
        } else if (std.mem.eql(u8, key, "questions")) {
            try self.readQuestions(config, key);
        } else if (!try ddd.readGlossaryKey(text, config, key)) {
            return text.fail("'{s}' isn't a setting; the settings are exclude, rules, infer, questions and paths, and the glossary's contexts and directional.", .{key});
        }
        if (config.exclude_len > max_excludes) assert.panic("{d} exclude patterns in room for {d}; readStrings() must refuse lists longer than max_excludes", .{ config.exclude_len, max_excludes });
        if (text.at < start) assert.panic("reading '{s}' moved back from byte {d} to {d}; it must only move forward", .{ key, start, text.at });
    }

    /// The settings under `rules:` or `infer:`.
    fn readSection(self: *ConfigReader, config: *Config, key: []const u8, section: Section) Error!void {
        const text = self.text;
        const start = text.at;
        var mapping = (try text.nestedMapping(key, 0)) orelse return;
        for (0..text.bytes.len) |_| {
            const name = (try text.nextKey(&mapping)) orelse break;
            switch (section) {
                .rules => try self.readRulesSetting(config, name, mapping.indent),
                .infer => try self.readInferSetting(config, name),
            }
        }
        if (mapping.indent == 0) assert.panic("the settings of '{s}' sit at the left margin; nestedMapping() returns only indented ones", .{key});
        if (text.at <= start) assert.panic("reading the settings of '{s}' at byte {d} consumed nothing", .{ key, start });
    }

    fn readRulesSetting(self: *ConfigReader, config: *Config, key: []const u8, indent: usize) Error!void {
        const text = self.text;
        const Setting = enum { select, disable };
        const which = std.meta.stringToEnum(Setting, key) orelse return text.fail("'{s}' isn't a rules setting; the settings are select and disable.", .{key});
        const at_line = text.line();
        var set: rules.Set = .{};
        for (try text.readStrings(key, indent)) |name| if (!set.includeNamed(name)) return text.failAt(at_line, "'{s}' isn't a rule; the rules are listed in the README, 'all' names every rule, 'strict' the defaults and the strict rules, and 'zanity check --rules' takes the same names.", .{name});
        if (which == .select and set.len == 0) return text.failAt(at_line, "'select' is empty, so nothing would run; list at least one rule, or remove it to run the defaults.", .{});
        if (which == .disable) config.disable = set else config.rules = set;
        if (set.len > rules.all.len) assert.panic("'{s}' names {d} rules of {d}; Set.include() must add each rule once", .{ key, set.len, rules.all.len });
        if (at_line == 0) assert.panic("'{s}' on line 0; line() counts from 1", .{key});
    }

    fn readInferSetting(self: *ConfigReader, config: *Config, key: []const u8) Error!void {
        const text = self.text;
        const InferSetting = enum { url, model, api_key_env, concurrency, threshold };
        const setting = std.meta.stringToEnum(InferSetting, key) orelse return text.fail("'{s}' isn't an infer setting; the settings are url, model, api_key_env, concurrency and threshold.", .{key});
        const value = try text.readScalar(key, false);
        switch (setting) {
            .url => {
                if (!(std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://"))) return text.fail("url is '{s}'; it must start with http:// or https://, such as http://127.0.0.1:8009.", .{value});
                config.url = value;
            },
            .model, .api_key_env => {
                if (value.len == 0) return text.fail("'{s}' is empty; name one, or remove the line to use the default.", .{key});
                if (setting == .model) config.model = value else config.api_key_env = value;
            },
            .concurrency => {
                const number = std.fmt.parseInt(i64, value, 10) catch return text.fail("'concurrency' needs a whole number, such as concurrency: 8.", .{});
                if (number < 1 or number > max_concurrency) return text.fail("concurrency is {d}; it must be between 1 and {d}.", .{ number, max_concurrency });
                config.concurrency = @intCast(number);
            },
            .threshold => {
                const number = std.fmt.parseFloat(f64, value) catch return text.fail("'threshold' needs a number, such as threshold: 0.9.", .{});
                if (!(number > 0 and number <= 1)) return text.fail("threshold is {d}; it must be above 0 and at most 1, such as 0.9 to report only what the model is at least 90% sure of.", .{number});
                config.threshold = number;
            },
        }
        try text.endLine();
        if (setting == .concurrency and config.concurrency == null) assert.panic("read infer concurrency but stored nothing; its branch of readInferSetting() must store it", .{});
        if (setting == .threshold and config.threshold == null) assert.panic("read infer threshold but stored nothing; its branch of readInferSetting() must store it", .{});
    }

    /// The `questions:` settings: each key a question of the file's own, or one of zanity's to
    /// retune starting from what zanity asks, with its settings on the indented lines below.
    fn readQuestions(self: *ConfigReader, config: *Config, key: []const u8) Error!void {
        const text = self.text;
        const before = config.questions_len;
        var mapping = (try text.nestedMapping(key, 0)) orelse return;
        for (0..text.bytes.len) |_| {
            const name = (try text.nextKey(&mapping)) orelse break;
            const at_line = text.line();
            try self.addQuestion(config, name);
            if (try text.nestedMapping(name, mapping.indent)) |found| {
                var settings = found;
                for (0..text.bytes.len) |_| try self.readQuestionSetting(config, (try text.nextKey(&settings)) orelse break);
            }
            try self.finishQuestion(config, at_line);
        }
        if (config.questions_len < before) assert.panic("reading questions dropped them from {d} to {d}; it may only add them", .{ before, config.questions_len });
        if (config.questions_len > max_questions) assert.panic("{d} questions in room for {d}; addQuestion() must refuse more", .{ config.questions_len, max_questions });
    }

    /// Starts the question `name`: one of the file's own, or one of zanity's, from what it asks.
    fn addQuestion(self: *ConfigReader, config: *Config, name: []const u8) Error!void {
        const text = self.text;
        if (name.len == 0) assert.panic("adding a question with no name; nextKey() returns only named keys", .{});
        for (config.questionRules()) |q| if (std.mem.eql(u8, q.name, name)) return text.fail("the question '{s}' appears twice; put its settings in one entry.", .{name});
        if (config.questions_len == max_questions) return text.fail("there are more than {d} questions; keep the ones that matter most.", .{max_questions});
        const builtin = if (rules.ruleIndex(name)) |i| rules.all[i] else null;
        if (builtin) |b| if (b.question.len == 0) return text.fail("'{s}' is a deterministic rule, not a question, so there is nothing to retune; give your question a name of its own.", .{name});
        config.questions[config.questions_len] = builtin orelse .{ .name = name, .advice = "", .severity = .warning, .tier = .default, .question = "", .judgement = "", .asks = .function };
        config.questions[config.questions_len].name = name;
        config.questions_len += 1;
        if (config.questions_len > max_questions) assert.panic("{d} questions in room for {d}; the check above refuses more", .{ config.questions_len, max_questions });
    }

    /// One setting of the question being read.
    fn readQuestionSetting(self: *ConfigReader, config: *Config, key: []const u8) Error!void {
        const text = self.text;
        if (config.questions_len == 0) assert.panic("reading '{s}' with no question open; addQuestion() opens one first", .{key});
        const QuestionSetting = enum { question, finding, fix, severity, asks, threshold };
        const setting = std.meta.stringToEnum(QuestionSetting, key) orelse return text.fail("'{s}' isn't a question setting; the settings are question, finding, fix, severity, asks and threshold.", .{key});
        const q = &config.questions[config.questions_len - 1];
        const value = try text.readScalar(key, false);
        switch (setting) {
            .threshold => {
                const number = std.fmt.parseFloat(f64, value) catch return text.fail("'threshold' needs a number, such as threshold: 0.9.", .{});
                if (!(number > 0 and number <= 1)) return text.fail("threshold is {d}; it must be above 0 and at most 1, such as 0.9 to report only what the model is at least 90% sure of.", .{number});
                q.threshold = number;
            },
            .severity => q.severity = std.meta.stringToEnum(rules.Severity, value) orelse return text.fail("severity must be error, warning or information.", .{}),
            .asks => q.asks = std.meta.stringToEnum(rules.Asks, value) orelse return text.fail("asks must be function, errors, fixture, test, file or project.", .{}),
            .question => q.question = value,
            .finding => q.judgement = value,
            .fix => q.advice = value,
        }
        try text.endLine();
        if (setting == .question and q.question.len == 0) assert.panic("read a question for '{s}' but stored none", .{q.name});
    }

    /// Checks the question just read, which started on `at_line`, says everything a finding needs.
    fn finishQuestion(self: *ConfigReader, config: *Config, at_line: u32) Error!void {
        if (config.questions_len == 0) assert.panic("finishing a question that was never started", .{});
        const q = config.questions[config.questions_len - 1];
        if (q.name.len == 0) assert.panic("the question on line {d} has no name; addQuestion() names it", .{at_line});
        const missing: []const u8 = if (q.question.len == 0) "question" else if (q.judgement.len == 0) "finding" else if (q.advice.len == 0) "fix" else return;
        return self.text.failAt(at_line, "the question '{s}' has no {s}; a question of your own needs a question, a finding and a fix.", .{ q.name, missing });
    }

    /// The `paths:` list: each item a files pattern and the rules that don't report in its files.
    fn readPathSections(self: *ConfigReader, config: *Config, key: []const u8) Error!void {
        const text = self.text;
        const before = config.paths_len;
        var list = (try text.mappingList(key, 0)) orelse return;
        for (0..text.bytes.len) |_| {
            const item_line = (try text.nextItem(&list)) orelse break;
            if (config.paths_len == max_path_sections) return text.failAt(item_line, "there are more than {d} paths entries; combine patterns that disable the same rules.", .{max_path_sections});
            config.paths[config.paths_len] = .{ .glob = "" };
            config.paths_len += 1;
            var mapping: yaml.Mapping = .{ .indent = text.column() };
            for (0..text.bytes.len) |_| try self.readPathSetting(config, (try text.nextKey(&mapping)) orelse break, mapping.indent);
            if (config.paths[config.paths_len - 1].glob.len == 0) return text.failAt(item_line, "a paths entry names no files; give it a pattern, such as files: tests/e2e/.", .{});
        }
        if (config.paths_len < before) assert.panic("reading paths dropped entries from {d} to {d}; it may only add them", .{ before, config.paths_len });
        if (config.paths_len > max_path_sections) assert.panic("{d} paths entries in room for {d}; readPathSections() must refuse entries past max_path_sections", .{ config.paths_len, max_path_sections });
    }

    fn readPathSetting(self: *ConfigReader, config: *Config, key: []const u8, indent: usize) Error!void {
        const text = self.text;
        if (config.paths_len == 0) assert.panic("reading '{s}' as a paths setting outside a paths entry; readPathSections() adds the entry first", .{key});
        const section = &config.paths[config.paths_len - 1];
        if (std.mem.eql(u8, key, "files")) {
            section.glob = try text.readScalar(key, false);
            try text.endLine();
        } else if (std.mem.eql(u8, key, "disable")) {
            const at_line = text.line();
            for (try text.readStrings(key, indent)) |name| section.disable.include((rules.find(name) orelse return text.failAt(at_line, "'{s}' isn't a rule; the rules are listed in the README, and 'zanity check --rules' takes the same names.", .{name})).name);
        } else return text.fail("'{s}' isn't a paths setting; the settings are files and disable.", .{key});
        if (section.disable.len > rules.all.len) assert.panic("the paths entry '{s}' disables {d} rules of {d}; Set.include() must add each rule once", .{ section.glob, section.disable.len, rules.all.len });
    }
};
