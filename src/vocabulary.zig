//! The project's own words, from zanity.toml: names that use a banned word or an alias of the
//! word the project settled on, tests filed in a different domain from the code they test, and
//! vocabularies that contradict themselves.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const config_module = @import("config.zig");
const naming = @import("naming.zig");
const facts_module = @import("facts.zig");
const Config = config_module.Config;
const Anchor = config_module.Anchor;
const Term = config_module.Term;
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Definition = facts_module.Definition;

/// Words in a name the vocabulary checks look at; longer names are checked by their first ones.
const max_words = 16;

/// Records which domain or context each definition belongs to, so duplicate-name and the checks
/// here can tell bounded contexts apart.
pub fn assignScopes(anchor: Anchor, facts: *Facts) void {
    const settings = anchor.config;
    if (settings.dir.len == 0) assert.panic("assigning scopes with no zanity.toml; anchorOf() returns null without one", .{});
    const scopes = settings.domainsAndContexts();
    if (scopes.len == 0) return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (facts.definitions.items()) |*d| {
        const relative = anchor.relative(d.path, &buffer);
        if (relative.len == 0) continue;
        if (settings.scopeOf(relative)) |i| d.scope = scopes[i].name;
    }
    if (facts.definitions.len > facts.definitions.capacity()) assert.panic("{d} definitions in room for {d}; Bounded.add() refuses more", .{ facts.definitions.len, facts.definitions.capacity() });
}

/// The project the vocabulary checks read and what they report into.
pub const Run = struct { anchor: Anchor, text: *memory.Text, enabled: rules.Set, findings: *memory.Bounded(Finding) };

/// `files` are every source file checked, sorted, for their module and package names.
pub fn checkVocabulary(run: Run, facts: *Facts, files: []const []const u8) error{LimitExceeded}!void {
    const settings = run.anchor.config;
    const enabled = run.enabled;
    const findings = run.findings;
    if (settings.dir.len == 0) return;
    if (enabled.len == 0) assert.panic("vocabulary checks ran with no rules enabled; runCheck always enables at least one", .{});
    const before = findings.len;
    if (enabled.enabled("vocabulary-conflict")) try conflicts(run);
    if (settings.terms_len > 0) {
        for (facts.definitions.items()) |d| try checkName(run, .{ .name = d.name, .path = d.path, .line = d.line, .column = d.column, .scope = d.scope });
        try checkPaths(run, files);
    }
    if (enabled.enabled("misplaced-test") and settings.scopes_len > 0) try misplacedTests(facts, findings);
    if (findings.len < before) assert.panic("vocabulary checks dropped findings from {d} to {d}; they may only add", .{ before, findings.len });
}

/// A name the vocabulary checks read: a definition's, or a module's or package's, which a reader
/// meets in every import and which only a rename of the file or directory changes.
const Named = struct {
    name: []const u8,
    path: []const u8,
    line: u32 = 0,
    column: u32 = 0,
    scope: []const u8 = "",
    kind: enum { definition, module, package } = .definition,
};

/// Checks each file's module name, and each directory's package name once, on the first file in
/// it; `files` is sorted, so a directory's files are next to each other.
fn checkPaths(run: Run, files: []const []const u8) error{LimitExceeded}!void {
    const settings = run.anchor.config;
    var buffers: [2][std.fs.max_path_bytes]u8 = undefined;
    var previous: []const u8 = "";
    for (files, 0..) |path, i| {
        if (i > 0 and !std.mem.lessThan(u8, files[i - 1], path)) assert.panic("'{s}' comes after '{s}'; sort the files, so a directory's files are next to each other", .{ path, files[i - 1] });
        const relative = run.anchor.relative(path, &buffers[i % 2]);
        if (relative.len == 0) continue;
        const scope = if (settings.scopeOf(relative)) |s| settings.domainsAndContexts()[s].name else "";
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, relative, end, '/')) |slash| : (end = slash + 1) {
            const shared = previous.len > slash and std.mem.eql(u8, previous[0 .. slash + 1], relative[0 .. slash + 1]);
            if (!shared) try checkName(run, .{ .name = relative[end..slash], .path = path, .scope = scope, .kind = .package });
        }
        const stem = std.fs.path.stem(relative[end..]);
        if (stem.len > 0) try checkName(run, .{ .name = stem, .path = path, .scope = scope, .kind = .module });
        if (end > relative.len) assert.panic("'{s}' was split past its end at {d}", .{ relative, end });
        previous = relative;
    }
}

/// How strongly `term` applies to the definition: 0 when it doesn't, 1 for the whole project,
/// 2 for its domain and 3 for its context, so the most specific word wins.
fn reach(settings: *const Config, term: Term, scope: []const u8) u8 {
    if (term.word.len == 0) assert.panic("weighing an empty vocabulary word; TomlReader must reject an empty term, so check where it adds terms", .{});
    if (term.scope == 0) return 1;
    if (term.scope > settings.scopes_len) assert.panic("a term belongs to scope {d} of {d}; the reader numbers scopes from 1", .{ term.scope, settings.scopes_len });
    const owner = settings.scopes[term.scope - 1];
    if (!std.mem.eql(u8, owner.name, scope)) return 0;
    return if (owner.context) 3 else 2;
}

/// Reports each banned word in the name, and each alias with the canonical word.
fn checkName(run: Run, d: Named) error{LimitExceeded}!void {
    const findings = run.findings;
    const before = findings.len;
    if (d.name.len == 0) assert.panic("{s}:{d}: a definition has no name; the @name capture matched an empty node", .{ d.path, d.line + 1 });
    var words: naming.Words = .{ .text = d.name };
    for (0..max_words) |_| {
        const word = words.next() orelse break;
        if (strongest(run.anchor.config, word, d.scope)) |term| try reportTerm(run, d, word, term);
    }
    if (findings.len - before > max_words) assert.panic("'{s}' got {d} vocabulary findings; each of its {d} words gives at most one", .{ d.name, findings.len - before, max_words });
}

/// The vocabulary term for `word` that applies most specifically in `scope`, if any does.
fn strongest(settings: *const Config, word: []const u8, scope: []const u8) ?Term {
    if (word.len == 0) assert.panic("looking up an empty word; fix naming.Words to skip empty tokens", .{});
    var best: ?Term = null;
    var best_reach: u8 = 0;
    for (settings.vocabulary()) |t| {
        if (!std.ascii.eqlIgnoreCase(t.word, word)) continue;
        const r = reach(settings, t, scope);
        if (r > best_reach) {
            best = t;
            best_reach = r;
        }
    }
    if (best != null and best_reach == 0) assert.panic("'{s}' matched a term that doesn't reach scope '{s}'; fix strongest() to keep only positive reach", .{ word, scope });
    return best;
}

/// Reports `word` in the name as banned, or as an alias of the term's canonical word.
fn reportTerm(run: Run, d: Named, word: []const u8, term: Term) error{LimitExceeded}!void {
    const text = run.text;
    if (!std.ascii.eqlIgnoreCase(term.word, word)) assert.panic("reporting '{s}' in '{s}' under the term for '{s}'; strongest() matches by word", .{ word, d.name, term.word });
    if (@intFromPtr(word.ptr) < @intFromPtr(d.name.ptr)) assert.panic("the word '{s}' is not inside '{s}'; pass a slice of the name from Words", .{ word, d.name });
    const what = switch (d.kind) {
        .definition => "",
        .module => "The module ",
        .package => "The package ",
    };
    if (term.canonical.len == 0) {
        const settings = run.anchor.config;
        const where = if (term.scope == 0) "" else settings.scopes[term.scope - 1].name;
        if (run.enabled.enabled("forbidden-term")) try run.findings.add(.{ .path = d.path, .line = d.line, .column = d.column, .rule = "forbidden-term", .message = try text.format("{s}'{s}' uses '{s}', a word zanity.toml bans{s}{s}, so the name says less than it should.", .{ what, d.name, word, if (where.len > 0) " in " else "", where }) });
        return;
    }
    if (!run.enabled.enabled("non-canonical-term")) return;
    const renamed = try respelled(text, d.name, word, term.canonical);
    const thing = switch (d.kind) {
        .definition => "it",
        .module => "the file",
        .package => "the directory",
    };
    const extension = if (d.kind == .module) std.fs.path.extension(d.path) else "";
    if (std.ascii.eqlIgnoreCase(renamed, d.name)) assert.panic("renaming '{s}' gave the same name; the alias '{s}' and '{s}' must differ", .{ d.name, word, term.canonical });
    try run.findings.add(.{ .path = d.path, .line = d.line, .column = d.column, .rule = "non-canonical-term", .message = try text.format("{s}'{s}' says '{s}', but the project's word for it is '{s}', so a reader searching for '{s}' won't find it.", .{ what, d.name, word, term.canonical, term.canonical }), .fix = try text.format("Rename {s} to '{s}{s}'.", .{ thing, renamed, extension }) });
}

/// `name` with `word`, a slice of it, replaced by `canonical` in the same case: all capitals,
/// a leading capital, or lower case.
fn respelled(text: *memory.Text, name: []const u8, word: []const u8, canonical: []const u8) error{LimitExceeded}![]const u8 {
    const at = @intFromPtr(word.ptr) - @intFromPtr(name.ptr);
    if (at + word.len > name.len) assert.panic("the word '{s}' is not inside '{s}'; pass a slice of the name from Words", .{ word, name });
    const start = text.used;
    _ = try text.copy(name[0..at]);
    const upper = for (word) |c| {
        if (std.ascii.isLower(c)) break false;
    } else true;
    for (canonical, 0..) |c, i| {
        const cased = if (upper and word.len > 1) std.ascii.toUpper(c) else if (i == 0 and std.ascii.isUpper(word[0])) std.ascii.toUpper(c) else c;
        _ = try text.copy(&.{cased});
    }
    _ = try text.copy(name[at + word.len ..]);
    const renamed = text.buffer[start..text.used];
    if (renamed.len != name.len - word.len + canonical.len) assert.panic("respelling '{s}' came out as '{s}'; respelled() must copy the name around the replaced word", .{ name, renamed });
    return renamed;
}

/// A vocabulary that contradicts itself: a word both banned and canonical, an alias that maps to
/// different words in different places, or two domains or contexts whose names are nearly the same.
fn conflicts(run: Run) error{LimitExceeded}!void {
    const anchor = run.anchor;
    const text = run.text;
    const findings = run.findings;
    const before = findings.len;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try text.copy(anchor.configPath(&buffer) catch {
        memory.exceeded = "bytes in the path from here to zanity.toml";
        return error.LimitExceeded;
    });
    const settings = anchor.config;
    const terms = settings.vocabulary();
    for (terms, 0..) |a, i| for (terms[i + 1 ..]) |b| {
        const message = if ((a.canonical.len == 0 and std.ascii.eqlIgnoreCase(a.word, b.canonical)) or (b.canonical.len == 0 and std.ascii.eqlIgnoreCase(b.word, a.canonical)))
            try text.format("'{s}' is both banned and the canonical word for something, so every name that uses it is reported.", .{if (a.canonical.len == 0) a.word else b.word})
        else if (a.canonical.len > 0 and b.canonical.len > 0 and std.ascii.eqlIgnoreCase(a.word, b.word) and !std.ascii.eqlIgnoreCase(a.canonical, b.canonical))
            try text.format("'{s}' stands for '{s}' on line {d} but for '{s}' here, so the same name is told to become two different ones.", .{ b.word, a.canonical, a.line, b.canonical })
        else
            continue;
        try findings.add(.{ .path = path, .line = b.line - 1, .column = 0, .rule = "vocabulary-conflict", .message = message });
    };
    const scopes = settings.domainsAndContexts();
    for (scopes, 0..) |a, i| for (scopes[i + 1 ..]) |b| {
        if (similarity(a.name, b.name) < rules.min_scope_similarity) continue;
        try findings.add(.{ .path = path, .line = b.line - 1, .column = 0, .rule = "vocabulary-conflict", .message = try text.format("'{s}' and '{s}' are nearly the same name for two parts of the code, so one is probably a misspelling of the other.", .{ a.name, b.name }) });
    };
    if (findings.len - before > terms.len * terms.len + scopes.len * scopes.len) assert.panic("{d} vocabulary conflicts from {d} terms and {d} scopes; each pair gives at most one", .{ findings.len - before, terms.len, scopes.len });
    if (path.len == 0) assert.panic("reporting vocabulary conflicts at an empty path; configPath() always names the file", .{});
}

/// How alike two names are, from 0 to 1: one less the share of the longer that must change,
/// counting edits ignoring case.
fn similarity(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 or b.len == 0) assert.panic("comparing '{s}' with '{s}', and one is empty; TomlReader must reject an empty domain or context name, so check where it reads table headers", .{ a, b });
    if (a.len > 64 or b.len > 64) return if (std.ascii.eqlIgnoreCase(a, b)) 1 else 0;
    var row: [65]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var diagonal = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const above = row[j];
            const cost: usize = @intFromBool(std.ascii.toLower(ca) != std.ascii.toLower(cb));
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), diagonal + cost);
            diagonal = above;
        }
    }
    const longest = @max(a.len, b.len);
    if (row[b.len] > longest) assert.panic("'{s}' and '{s}' came out {d} edits apart, more than the longer's {d} bytes; an edit distance is at most the longer length, so check the row update in similarity()", .{ a, b, row[b.len], longest });
    return 1 - @as(f64, @floatFromInt(row[b.len])) / @as(f64, @floatFromInt(longest));
}

/// A test filed in one domain or context while the code it tests lives in exactly one other.
fn misplacedTests(facts: *Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const definitions = facts.definitions.items();
    var buffer: [max_words][]const u8 = undefined;
    for (definitions, 0..) |d, i| {
        if (d.scope.len == 0 or !naming.testNamed(d.name)) continue;
        const key = subjectKey(d.name, &buffer) orelse continue;
        var owner: ?[]const u8 = null;
        var owners: usize = 0;
        for (definitions) |other| {
            if (other.scope.len == 0 or naming.testNamed(other.name)) continue;
            if ((subjectKey(other.name, &buffer) orelse continue) != key) continue;
            if (owner) |o| if (std.mem.eql(u8, o, other.scope)) continue;
            owner = other.scope;
            owners += 1;
        }
        const home = owner orelse continue;
        if (owners != 1 or std.mem.eql(u8, home, d.scope)) continue;
        try findings.add(.{ .path = d.path, .line = d.line, .column = d.column, .rule = "misplaced-test", .message = try facts.text.format("'{s}' tests code that belongs to {s}, but lives in {s}, so the two drift apart unseen.", .{ d.name, home, d.scope }) });
        if (i >= definitions.len) assert.panic("definition {d} of {d}; the loop stays inside the list", .{ i, definitions.len });
    }
    if (findings.len - before > definitions.len) assert.panic("{d} misplaced tests among {d} definitions; each is reported at most once", .{ findings.len - before, definitions.len });
}

/// The words of a name, less any test word, lowercased and in order, as one hash: what a test is
/// about, and what code it would be testing.
fn subjectKey(name: []const u8, buffer: *[max_words][]const u8) ?u64 {
    if (name.len == 0) assert.panic("hashing the subject of an empty name; definitions always have names", .{});
    var words: naming.Words = .{ .text = name };
    var count: usize = 0;
    while (words.next()) |w| {
        if (std.ascii.eqlIgnoreCase(w, "test") or std.ascii.eqlIgnoreCase(w, "tests")) continue;
        if (count == max_words) break;
        buffer[count] = w;
        count += 1;
    }
    if (count == 0) return null;
    std.mem.sort([]const u8, buffer[0..count], {}, lessIgnoringCase);
    var hasher = std.hash.Wyhash.init(0);
    for (buffer[0..count]) |w| {
        for (w) |c| hasher.update(&.{std.ascii.toLower(c)});
        hasher.update(" ");
    }
    if (count > max_words) assert.panic("kept {d} words in room for {d}", .{ count, max_words });
    return hasher.final();
}

fn lessIgnoringCase(_: void, a: []const u8, b: []const u8) bool {
    if (a.len == 0) assert.panic("sorting an empty word against '{s}'; Words never returns one", .{b});
    if (b.len == 0) assert.panic("sorting '{s}' against an empty word; Words never returns one", .{a});
    return std.ascii.lessThanIgnoreCase(a, b);
}
