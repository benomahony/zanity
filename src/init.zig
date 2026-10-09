//! `zanity init`: a zanity.toml with every setting written out and explained, so a project can
//! start from the whole picture and delete what it doesn't need. Like the schema, it is written
//! from the rules and limits in the code, so it never offers a setting or rule zanity lacks.
const std = @import("std");
const assert = @import("assert.zig");
const rules = @import("rules.zig");
const config = @import("config.zig");
const infer = @import("infer.zig");
const schema = @import("schema.zig");

/// Directories that usually hold code a project doesn't own or keeps wrong on purpose.
pub const usual_excludes = [_][]const u8{ "vendor", "third_party", "external", "testdata", "tests/fixtures", "test/fixtures", "tests/data", "fixtures" };

/// What `zanity init` found in the project, for the notes and the excludes it turns on.
pub const Project = struct {
    /// Files per language, as `adapters.all` orders the languages.
    languages: []const Count,
    /// The entries of `usual_excludes` that exist in the project.
    present: []const []const u8,

    pub const Count = struct { name: []const u8, files: usize };
};

/// Writes the whole zanity.toml.
pub fn renderConfig(w: *std.Io.Writer, project: Project) !void {
    if (project.present.len > usual_excludes.len) assert.panic("init found {d} usual excludes of {d}; pass only entries of init.usual_excludes that exist", .{ project.present.len, usual_excludes.len });
    if (rules.all.len == 0) assert.panic("rules.all is empty, so zanity init would list no rules; add the rules back to src/rules.zig", .{});
    try w.print(
        \\#:schema {s}
        \\# zanity's settings for this project. Every line is optional: delete what you don't need.
        \\# The first line lets TOML language servers complete and check this file as you type.
        \\
    , .{schema.url});
    try renderFound(w, project);
    try w.writeAll(
        \\
        \\# Which rules run. "all" is every rule, including those off by default; leave `rules` out to
        \\# run only the defaults. `zanity check --rules a,b` overrides it for one run.
        \\rules = ["all"]
        \\
        \\# Rules to switch off everywhere. Every rule is listed here, with its severity, whether it is
        \\# on by default, and how to fix what it finds; uncomment the ones you don't want.
        \\disable = [
        \\
    );
    try renderRuleList(w);
    try w.writeAll(
        \\]
        \\
        \\# Paths zanity never checks, in .gitignore syntax, relative to this file. It already skips what
        \\# .gitignore ignores, dot directories and build output.
        \\
    );
    try renderExcludes(w, project.present);
    try renderInferNotes(w);
}

fn renderFound(w: *std.Io.Writer, project: Project) !void {
    if (project.languages.len == 0) assert.panic("zanity init passed no language counts; pass one per language in adapters.all, even when it has no files", .{});
    var total: usize = 0;
    for (project.languages) |language| total += language.files;
    if (total == 0) {
        try w.writeAll("#\n# zanity init found no files in a language zanity checks; it checks Python, Zig, Go,\n# TypeScript, Rust and Java.\n");
        return;
    }
    try w.writeAll("#\n# zanity init found");
    var shown: usize = 0;
    for (project.languages) |language| {
        if (language.files == 0) continue;
        try w.print("{s} {d} {s} {s}", .{ if (shown == 0) "" else ",", language.files, language.name, if (language.files == 1) "file" else "files" });
        shown += 1;
    }
    try w.writeAll(".\n");
    if (shown > project.languages.len) assert.panic("init listed {d} languages of {d}; renderFound() must list each language once", .{ shown, project.languages.len });
}

/// One commented line per rule, `#   "name",  # severity, on or off by default. advice`.
fn renderRuleList(w: *std.Io.Writer) !void {
    var widest: usize = 0;
    for (rules.all) |rule| widest = @max(widest, rule.name.len);
    for (rules.all) |rule| {
        if (rule.advice.len == 0) assert.panic("rule {s} has no advice for zanity init to show; give it an .advice in src/rules.zig", .{rule.name});
        try w.print("  # \"{s}\",", .{rule.name});
        try w.splatByteAll(' ', widest - rule.name.len + 1);
        try w.print("# {t}, {s} by default. {s}\n", .{ rule.severity, if (rule.default) "on" else "off", rule.advice });
    }
    if (widest == 0) assert.panic("every rule in rules.all has an empty name; give each a .name in src/rules.zig", .{});
}

fn renderExcludes(w: *std.Io.Writer, present: []const []const u8) !void {
    if (present.len > usual_excludes.len) assert.panic("{d} excludes found of {d} candidates; pass only entries of init.usual_excludes", .{ present.len, usual_excludes.len });
    if (present.len == 0) {
        try w.writeAll("# exclude = [\"vendor/\", \"tests/fixtures/\"]\n");
        return;
    }
    try w.writeAll("# zanity init turned on the ones below that exist in this project.\nexclude = [");
    for (present, 0..) |dir, i| try w.print("{s}\"{s}/\"", .{ if (i == 0) "" else ", ", dir });
    try w.writeAll("]\n");
    if (present[0].len == 0) assert.panic("an empty directory name reached the excludes; init must pass only entries of usual_excludes", .{});
}

fn renderInferNotes(w: *std.Io.Writer) !void {
    if (!(infer.default_threshold > 0 and infer.default_threshold <= 1)) assert.panic("infer.default_threshold is {d}, outside (0, 1]; set it between 0 and 1 in src/infer.zig", .{infer.default_threshold});
    if (infer.default_concurrency > config.max_concurrency) assert.panic("the default concurrency {d} is above the most config allows, {d}; lower infer.default_concurrency or raise config.max_concurrency", .{ infer.default_concurrency, config.max_concurrency });
    try w.print(
        \\
        \\# `zanity check --infer` also asks a decision model what code structure can't settle, such
        \\# as whether an error message misleads. It sends only the source of the functions it asks
        \\# about, and caches every answer. By default it asks TypeSafe's Jev, which needs
        \\# TYPESAFE_API_KEY; any other System One server works, such as Kev on your own machine.
        \\[infer]
        \\# url = "http://127.0.0.1:8009"    # default: TYPESAFE_BASE_URL, then TypeSafe's API
        \\# model = "kev-latest"             # default: TYPESAFE_DEFAULT_MODEL, then jev-latest
        \\# api_key_env = "KEV_API_KEY"      # default: TYPESAFE_API_KEY; optional except for TypeSafe
        \\# Requests sent to the model at once, 1 to {d}.
        \\concurrency = {d}
        \\# How sure the model must be for a judgement to become a finding, above 0 and at most 1: 0.9
        \\# reports only what it is at least 90% sure of, and a lower value reports more.
        \\threshold = {d}
        \\
        \\# Rules that don't report in some files, one table per pattern (.gitignore syntax, relative
        \\# to this file). For example, end-to-end tests are meant to start processes and read files:
        \\# [paths."tests/e2e/"]
        \\# disable = ["process-in-test", "filesystem-in-test", "network-in-test"]
        \\
        \\# The project's words for things. Names that use a banned word, or an alias of a word the
        \\# project settled on, are reported. Domains and contexts carry their own words; a context
        \\# applies after a domain, and a definition can share its name with one in another context.
        \\# [vocabulary]
        \\# forbidden = ["util", "manager"]
        \\#
        \\# [vocabulary.synonyms]
        \\# customer = ["client", "user"]
        \\#
        \\# [contexts.billing]
        \\# include = ["src/billing/**"]
        \\# forbidden = ["discount"]
        \\#
        \\# [contexts.billing.synonyms]
        \\# invoice = ["bill", "statement"]
        \\
    , .{ config.max_concurrency, infer.default_concurrency, infer.default_threshold });
}
