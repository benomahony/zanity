//! Content-addressed deterministic analysis cached as queryable JSON in the SQLite store.
//! A row holds one source file's local findings and all facts needed to recompute project-wide
//! rules, so changing one file never makes facts from the unchanged files disappear.

const std = @import("std");
const assert = @import("assert.zig");
const check = @import("check.zig");
const facts_module = @import("facts.zig");
const Definition = facts_module.Definition;
const Diagnostic = check.Diagnostic;
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Function = facts_module.Function;
const Edge = facts_module.Edge;
const Shape = facts_module.Shape;
const Unit = facts_module.Unit;
const language = @import("language.zig");
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const store = @import("store.zig");
/// Bytes of the analyzer's revision kept in each cache key.
const revision_bytes = 8;
/// Comptime branches allowed for hashing every source file of the analyzer into its revision.
const analyzer_hash_quota = 10_000_000;

const cache_format = "source-analysis-4";

/// The source code that produces local findings and facts. Its compile-time digest makes a rebuilt
/// zanity miss old rows automatically when checker logic, name tables or parser revisions change.
const analyzer_revision = revisionOfAnalyzer();

/// Every file the analysis of one source file and its encoding reach through @import, from
/// analysis.zig and this file. A test fails when an import reaches a file missing here, since
/// a change to it would otherwise replay findings cached by the build before.
pub const analyzer_sources = [_][]const u8{
    "analysis.zig",            "assert.zig",       "cache.zig",     "capture_ids.zig",     "captures.zig",
    "catalogue_questions.zig", "chains.zig",       "check.zig",     "checker.zig",         "closing.zig",
    "code_lines.zig",          "constructs.zig",   "crypto.zig",    "documentation.zig",   "extract.zig",
    "facts.zig",               "file_scratch.zig", "hazards.zig",   "import_notes.zig",    "isolation.zig",
    "language.zig",            "loops.zig",        "memory.zig",    "messages.zig",        "name_counts.zig",
    "name_words.zig",          "naming.zig",       "notes.zig",     "parameter_sinks.zig", "parameters.zig",
    "parser_hazards.zig",      "passthrough.zig",  "repeats.zig",   "rewrite.zig",         "rule.zig",
    "rules.zig",               "scope.zig",        "secrets.zig",   "shapes.zig",          "spans.zig",
    "sqlite.zig",              "store.zig",        "store_sql.zig", "strings.zig",         "suppress.zig",
    "test_quality.zig",        "tracing.zig",      "ts.zig",        "types.zig",           "unread.zig",
    "walk.zig",                "weak.zig",         "words.zig",
};

fn revisionOfAnalyzer() [revision_bytes]u8 {
    @setEvalBranchQuota(analyzer_hash_quota);
    var hash = std.hash.Wyhash.init(0);
    hash.update(cache_format);
    hash.update("\x00");
    if (analyzer_sources.len == 0) assert.panic("fingerprinting no analyzer source; list the code that produces cached facts and findings", .{});
    var bytes: usize = 0;
    inline for (analyzer_sources) |name| {
        const source = @embedFile(name);
        hash.update(name);
        hash.update("\x00");
        hash.update(source);
        hash.update("\x00");
        bytes += source.len;
    }
    if (bytes == 0) assert.panic("fingerprinting {d} empty analyzer sources; embed their contents, not empty paths", .{analyzer_sources.len});
    var revision: [revision_bytes]u8 = undefined;
    std.mem.writeInt(u64, &revision, hash.final(), .little);
    return revision;
}

pub const AnalysisContext = struct {
    language: []const u8,
    query: []const u8,
    revision: []const u8,
    enabled: rules.Set,
    collect_units: bool,
};

pub const Snapshot = struct {
    format: []const u8,
    path: []const u8,
    language: []const u8,
    rules: []const []const u8,
    collect_units: bool,
    findings: []const Diagnostic,
    definitions: []const Definition,
    functions: []const Function,
    calls: []const Edge,
    units: []const Unit,
    references: []facts_module.Reference,
    shapes: []const Shape,
    abstractions: []const Definition,
    imports: []const facts_module.Import,
    implemented: []const u64,
    passed: []const u64,
};

/// The context every row a checker caches shares: this analyzer, the language's queries and
/// grammar, the enabled rules and whether units are kept. The store keeps the most recently used
/// contexts, so a new zanity or rule selection drops the rows of the old one in time.
pub fn contextOf(context: AnalysisContext) store.Digest {
    if (context.language.len == 0 or context.query.len == 0 or context.revision.len == 0) assert.panic("caching a language without a name, query or revision; adapters provide all three", .{});
    if (context.enabled.len == 0) assert.panic("caching {s} with no rules enabled; a check enables at least one", .{context.language});
    var parts: [rules.all.len + 5][]const u8 = undefined;
    parts[0] = &analyzer_revision;
    parts[1] = context.language;
    parts[2] = context.query;
    parts[3] = if (context.collect_units) "units" else "no-units";
    parts[4] = context.revision;
    var count: usize = 5;
    for (context.enabled.names()) |name| {
        parts[count] = name;
        count += 1;
    }
    if (count > parts.len) assert.panic("{d} cache-key parts in room for {d}; size parts for every selected rule", .{ count, parts.len });
    return store.digest(parts[0..count]);
}

/// The row for `path` in `context`. The store matches the source digest separately, so an edit
/// replaces the row.
pub fn key(context: store.Digest, path: []const u8) store.Digest {
    if (path.len == 0) assert.panic("caching an empty path; Batch only caches named files", .{});
    if (std.mem.indexOfNone(u8, &context, "0123456789abcdef") != null) assert.panic("keying {s} by context '{s}', which is not a digest; pass contextOf()'s", .{ path, &context });
    return store.digest(&.{ &context, path });
}

/// Encodes exactly what one language checker produced into memory reserved at startup. Cross-file
/// findings are absent: they are recomputed after cached and fresh facts have been merged.
pub fn encode(buffer: []u8, context: AnalysisContext, facts: *const Facts, findings: []const Diagnostic) ![]const u8 {
    if (buffer.len == 0) assert.panic("encoding a cached analysis into no memory; reserve memory.Limits.analysis_bytes", .{});
    if (!std.mem.eql(u8, facts.language, context.language)) assert.panic("encoding {s} facts with the {s} checker; cache the checker that produced them", .{ facts.language, context.language });
    const snapshot: Snapshot = .{
        .format = cache_format,
        .path = facts.path,
        .language = facts.language,
        .rules = context.enabled.names(),
        .collect_units = facts.collect_units,
        .findings = findings,
        .definitions = facts.definitions.items(),
        .functions = facts.functions.items(),
        .calls = facts.calls.items(),
        .units = facts.units.items(),
        .references = facts.references.items(),
        .shapes = facts.shapes.items(),
        .abstractions = facts.abstractions.items(),
        .imports = facts.imports.items(),
        .implemented = facts.implemented.items(),
        .passed = facts.passed.items(),
    };
    var out: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(snapshot, .{}, &out);
    const result = out.buffered();
    if (result.len == 0) assert.panic("encoded an empty analysis for {s}; JSON always contains the snapshot's fields", .{facts.path});
    return result;
}

pub const ReplayError = error{InvalidCache};

pub const Replay = struct {
    payload: []const u8,
    scratch: []u8,
    path: []const u8,
    language: []const u8,
    text: *memory.Text,
    facts: *Facts,
    findings: *memory.Bounded(Finding),
};

/// Adds a cached file to the run exactly as Batch.commit adds a freshly checked one.
pub fn replay(run: Replay) (ReplayError || error{ OutOfMemory, LimitExceeded })!void {
    if (run.payload.len == 0 or run.scratch.len == 0) assert.panic("replaying a cache row without its JSON or parsing memory; split memory.Limits.analysis_bytes between both", .{});
    if (run.path.len == 0 or run.language.len == 0) assert.panic("replaying a cache row without a path or language; Batch passes both from the collected file", .{});
    var fixed = std.heap.FixedBufferAllocator.init(run.scratch);
    var parsed = std.json.parseFromSlice(Snapshot, fixed.allocator(), run.payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCache,
    };
    defer parsed.deinit();
    const snapshot = parsed.value;
    try validateHeader(snapshot, run);
    try validateDefinitions(snapshot, run);
    try validateGraph(snapshot);
    try validateUnits(snapshot, run);
    try validateFindings(snapshot);
    try commitFacts(snapshot, run);
    try commitFindings(snapshot, run);
}

fn validateHeader(snapshot: Snapshot, run: Replay) ReplayError!void {
    if (run.path.len == 0) assert.panic("validating a cache row against an empty path; Batch collects only named files", .{});
    if (run.language.len == 0) assert.panic("validating a cache row against an unnamed language; adapters always have names", .{});
    if (!std.mem.eql(u8, snapshot.format, cache_format) or !std.mem.eql(u8, snapshot.path, run.path)) return error.InvalidCache;
    if (!std.mem.eql(u8, snapshot.language, run.language) or snapshot.collect_units != run.facts.collect_units) return error.InvalidCache;
}

fn validateDefinitions(snapshot: Snapshot, run: Replay) ReplayError!void {
    if (run.path.len == 0) assert.panic("validating definitions without their path; facts always belong to a file", .{});
    if (run.language.len == 0) assert.panic("validating definitions without their language; facts always belong to an adapter", .{});
    for (snapshot.definitions) |definition| {
        if (!std.mem.eql(u8, definition.path, run.path) or !std.mem.eql(u8, definition.language, run.language)) return error.InvalidCache;
        if (definition.name.len == 0 or definition.unmarked.len == 0) return error.InvalidCache;
        if (definition.delete_end < definition.delete_start) return error.InvalidCache;
    }
    for (snapshot.imports) |i| {
        if (!std.mem.eql(u8, i.path, run.path) or i.spec.len == 0) return error.InvalidCache;
    }
    for (snapshot.abstractions) |abstraction| {
        if (!std.mem.eql(u8, abstraction.path, run.path) or !std.mem.eql(u8, abstraction.language, run.language)) return error.InvalidCache;
    }
}

fn validateGraph(snapshot: Snapshot) ReplayError!void {
    if (snapshot.functions.len > std.math.maxInt(u32)) assert.panic("a cache row has {d} functions, too many for call indexes", .{snapshot.functions.len});
    if (snapshot.calls.len > std.math.maxInt(u32)) assert.panic("a cache row has {d} calls, too many for bounded facts", .{snapshot.calls.len});
    for (snapshot.functions) |function| if (function.name.len == 0 or !std.mem.eql(u8, function.path, snapshot.path)) return error.InvalidCache;
    for (snapshot.calls) |call| if (call.caller >= snapshot.functions.len or call.callee.len == 0) return error.InvalidCache;
    for (snapshot.shapes) |shape| if (shape.function >= snapshot.functions.len) return error.InvalidCache;
}

fn validateUnits(snapshot: Snapshot, run: Replay) ReplayError!void {
    if (run.path.len == 0) assert.panic("validating units without their path; units always belong to a file", .{});
    if (run.language.len == 0) assert.panic("validating units without their language; units always belong to an adapter", .{});
    for (snapshot.units) |unit| {
        if (!std.mem.eql(u8, unit.path, run.path) or !std.mem.eql(u8, unit.language, run.language)) return error.InvalidCache;
        if (unit.name.len == 0 or unit.end_line < unit.line) return error.InvalidCache;
    }
}

fn validateFindings(snapshot: Snapshot) ReplayError!void {
    if (snapshot.format.len == 0) assert.panic("validating findings from a snapshot without a format; decode Snapshot before validating it", .{});
    if (snapshot.path.len == 0) assert.panic("validating findings from a snapshot without a path; every cached analysis names its file", .{});
    for (snapshot.findings) |diagnostic| {
        if (rules.find(diagnostic.rule) == null or diagnostic.message.len == 0) return error.InvalidCache;
        if (diagnostic.edit) |edit| if (edit.end < edit.start) return error.InvalidCache;
    }
}

fn commitFacts(snapshot: Snapshot, run: Replay) error{LimitExceeded}!void {
    if (snapshot.path.len == 0 or snapshot.language.len == 0) assert.panic("committing cached facts without their file identity; validateHeader must run first", .{});
    const facts = run.facts;
    const first = facts.functions.len;
    for (snapshot.definitions) |definition| try facts.definitions.add(.{
        .path = run.path,
        .language = run.language,
        .name = try run.text.copy(definition.name),
        .kind = try run.text.copy(definition.kind),
        .line = definition.line,
        .column = definition.column,
        .public = definition.public,
        .scope = try run.text.copy(definition.scope),
        .member = definition.member,
        .importable = definition.importable,
        .unmarked = try run.text.copy(definition.unmarked),
        .local = definition.local,
        .delete_start = definition.delete_start,
        .delete_end = definition.delete_end,
    });
    for (snapshot.functions) |function| try facts.functions.add(.{ .path = run.path, .name = try run.text.copy(function.name), .method = function.method, .line = function.line, .column = function.column, .parameters = function.parameters, .types = try run.text.copy(function.types) });
    for (snapshot.calls) |call| try facts.calls.add(.{ .caller = @intCast(first + call.caller), .callee = try run.text.copy(call.callee), .reach = call.reach, .arguments = call.arguments, .types = try run.text.copy(call.types) });
    for (snapshot.shapes) |shape| {
        var kept = shape;
        kept.function = @intCast(first + shape.function);
        try facts.shapes.add(kept);
    }
    for (snapshot.abstractions) |abstraction| try facts.abstractions.add(.{
        .path = run.path,
        .language = run.language,
        .name = try run.text.copy(abstraction.name),
        .kind = try run.text.copy(abstraction.kind),
        .line = abstraction.line,
        .column = abstraction.column,
        .public = abstraction.public,
        .scope = try run.text.copy(abstraction.scope),
        .member = abstraction.member,
        .importable = abstraction.importable,
        .unmarked = try run.text.copy(abstraction.unmarked),
    });
    for (snapshot.imports) |i| try facts.imports.add(.{ .path = run.path, .language = run.language, .spec = try run.text.copy(i.spec), .line = i.line, .column = i.column, .names = i.names, .shown = try run.text.copy(i.shown), .submodule = i.submodule });
    for (snapshot.implemented) |hash| try facts.implemented.add(hash);
    for (snapshot.passed) |hash| try facts.passed.add(hash);
    try facts.addReferences(snapshot.references);
    for (snapshot.units) |unit| try facts.units.add(.{ .kind = unit.kind, .reports_error = unit.reports_error, .path = run.path, .language = run.language, .name = try run.text.copy(unit.name), .line = unit.line, .column = unit.column, .end_line = unit.end_line, .source = try run.text.copy(unit.source), .fix = try run.text.copy(unit.fix) });
    if (facts.functions.len != first + snapshot.functions.len) assert.panic("replayed {d} functions from a cache row holding {d}; commitFacts must add each once", .{ facts.functions.len - first, snapshot.functions.len });
}

fn commitFindings(snapshot: Snapshot, run: Replay) (ReplayError || error{LimitExceeded})!void {
    if (snapshot.path.len == 0) assert.panic("committing cached findings without a path; validateHeader must run first", .{});
    const before = run.findings.len;
    for (snapshot.findings) |diagnostic| {
        const rule = rules.find(diagnostic.rule) orelse return error.InvalidCache;
        const edit: ?facts_module.Edit = if (diagnostic.edit) |change| .{ .start = change.start, .end = change.end, .replacement = try run.text.copy(change.replacement) } else null;
        try run.findings.add(.{ .path = run.path, .line = diagnostic.line, .column = diagnostic.column, .rule = rule.name, .message = try run.text.copy(diagnostic.message), .fix = try run.text.copy(diagnostic.fix), .edit = edit, .subject = diagnostic.subject });
    }
    if (run.findings.len != before + snapshot.findings.len) assert.panic("replayed {d} findings from a cache row holding {d}; commitFindings must add each once", .{ run.findings.len - before, snapshot.findings.len });
}

test "the analyzer's revision covers every file its analysis imports, so a changed file misses old rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each listed file as built into this test, so the walk reads what the revision hashes.
    const embedded = comptime embedded: {
        var all: [analyzer_sources.len][]const u8 = undefined;
        for (analyzer_sources, 0..) |name, i| all[i] = @embedFile(name);
        break :embedded all;
    };
    var reached: std.StringArrayHashMapUnmanaged(void) = .empty;
    try reached.put(arena, "analysis.zig", {});
    try reached.put(arena, "cache.zig", {});
    var next: usize = 0;
    while (next < reached.count()) : (next += 1) {
        const name = reached.keys()[next];
        const index = for (analyzer_sources, 0..) |s, i| {
            if (std.mem.eql(u8, s, name)) break i;
        } else {
            std.debug.print("src/{s} is reached from analysis.zig or cache.zig but is not in analyzer_sources; add it, or a change to it replays old cached findings\n", .{name});
            return error.TestUnexpectedResult;
        };
        const source = embedded[index];
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            // Code ends at a `//` outside a string, so an import a comment quotes is not followed.
            var code = line;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, line, from, "//")) |slash| : (from = slash + 2) {
                if (std.mem.count(u8, line[0..slash], "\"") % 2 == 0) {
                    code = line[0..slash];
                    break;
                }
            }
            var rest = code;
            while (std.mem.indexOf(u8, rest, "@import(\"")) |at| {
                rest = rest[at + "@import(\"".len ..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                const imported = rest[0..end];
                if (std.mem.endsWith(u8, imported, ".zig") and std.mem.indexOfScalar(u8, imported, '/') == null) try reached.put(arena, imported, {});
            }
        }
    }
    for (analyzer_sources) |name| if (!reached.contains(name)) {
        std.debug.print("analyzer_sources lists {s}, which analysis.zig and cache.zig no longer reach; remove it\n", .{name});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(analyzer_sources.len, reached.count());
}

test "a cached analysis replays local findings and cross-file facts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source_text = try memory.Text.initText(arena, 4096);
    var source_facts = try Facts.initFacts(arena, .{ .definitions = 8, .functions = 8, .calls = 8, .references = 8, .text_bytes = 4096 }, &source_text);
    const loaded = try language.loadedOnce(language.forPath("a.py").?);
    source_facts.path = "src/a.py";
    source_facts.language = loaded.adapter.name;
    try source_facts.define("answer", "function", .{ .at = .{ 2, 4 }, .public = true, .unmarked = "answer" });
    const function = try source_facts.function("answer", .{ 2, 4 }, false);
    try source_facts.call(.{ .caller = function, .callee = "helper", .reach = .functions });
    try source_facts.references.add(.{ .name = 7 });
    try source_facts.references.add(.{ .name = 7 });
    const checker = try check.Checker.initChecker(arena, loaded, rules.Set.defaults());
    const context: AnalysisContext = .{ .language = loaded.adapter.name, .query = loaded.adapter.query, .revision = loaded.adapter.revision, .enabled = checker.enabled, .collect_units = false };
    const diagnostic: Diagnostic = .{ .line = 2, .column = 4, .rule = "long-function", .message = "too long" };
    var encoded: [8192]u8 = undefined;
    const payload = try encode(&encoded, context, &source_facts, &.{diagnostic});

    var target_text = try memory.Text.initText(arena, 4096);
    var target_facts = try Facts.initFacts(arena, .{ .definitions = 8, .functions = 8, .calls = 8, .references = 8, .text_bytes = 4096 }, &target_text);
    var findings = try memory.Bounded(Finding).initBounded(arena, 8, "test findings");
    var scratch: [64 * 1024]u8 = undefined;
    try replay(.{ .payload = payload, .scratch = &scratch, .path = "src/a.py", .language = loaded.adapter.name, .text = &target_text, .facts = &target_facts, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), target_facts.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), target_facts.functions.len);
    try std.testing.expectEqual(@as(usize, 1), target_facts.calls.len);
    try std.testing.expectEqual(@as(usize, 1), target_facts.references.len);
    try std.testing.expectEqualStrings("answer", target_facts.definitions.items()[0].unmarked);
    try std.testing.expectEqualStrings("answer", target_facts.functions.items()[0].name);
    try std.testing.expectEqualStrings("too long", findings.items()[0].message);
}
