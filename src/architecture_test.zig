const std = @import("std");
const Io = std.Io;
const adapters = @import("adapters");
const ts = @import("ts.zig");
const language = @import("language.zig");
const captures = @import("captures.zig");

const Knowledge = struct {
    languages: std.StringHashMapUnmanaged(void) = .empty,
    kinds: std.StringHashMapUnmanaged(void) = .empty,
    vocabulary: std.StringHashMapUnmanaged(void) = .empty,
};

fn learn(arena: std.mem.Allocator) !Knowledge {
    var k: Knowledge = .{};
    for (adapters.all) |*adapter| {
        try k.languages.put(arena, adapter.name, {});
        const grammar: *const ts.Language = @ptrCast(adapter.grammar());
        for (0..ts.ts_language_symbol_count(grammar)) |i| {
            const symbol: u16 = @intCast(i);
            if (ts.ts_language_symbol_type(grammar, symbol) != .regular) continue;
            try k.kinds.put(arena, std.mem.span(ts.ts_language_symbol_name(grammar, symbol)), {});
        }
        const loaded = try language.load(adapter);
        defer ts.ts_query_delete(loaded.query);
        const compiled = try captures.Compiled.initCompiled(arena, loaded.query);
        for (compiled.names) |n| {
            try k.vocabulary.put(arena, try arena.dupe(u8, n.family), {});
            try k.vocabulary.put(arena, try arena.dupe(u8, n.part), {});
        }
    }
    if (k.languages.count() != adapters.all.len) std.debug.panic("learned {d} language names from {d} adapters; two adapters share a name in languages/manifest.zon", .{ k.languages.count(), adapters.all.len });
    if (k.kinds.count() == 0) @panic("learned no grammar node kinds, so the architecture test would pass vacuously; check the grammars load");
    return k;
}

fn violations(arena: std.mem.Allocator, checker: Probe, path: []const u8, source: []const u8) !usize {
    const k = checker.knowledge;
    if (path.len == 0) std.debug.panic("asked to scan a file with an empty path ({d} bytes); the walk must pass each file's path relative to its root", .{source.len});
    const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
    defer ts.ts_parser_delete(parser);
    _ = ts.ts_parser_set_language(parser, @ptrCast(checker.adapter.grammar()));
    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return error.ParseFailed;
    defer ts.ts_tree_delete(tree);
    var scratch = try captures.CaptureScratch.initCaptureScratch(arena, .{ .captures = 1 << 18, .per_file = 1 << 12 });
    const index = try captures.index(&scratch, checker.compiled, ts.ts_tree_root_node(tree), source);
    var found: usize = 0;
    for (index.triples, 0..) |entry, i| {
        if (i > 0 and index.triples[i - 1].key.start == entry.key.start and index.triples[i - 1].key.id == entry.key.id) continue;
        const text = entry.node.text(source);
        const is_string = index.marks(entry.node, checker.constant) and text.len >= 2 and text[0] == '"';
        const is_name = index.marks(entry.node, checker.path) and std.mem.indexOfScalar(u8, text, '.') == null;
        const word = if (is_string) text[1 .. text.len - 1] else if (is_name) text else continue;
        const names_language = k.languages.contains(word);
        const names_kind = is_string and k.kinds.contains(word) and !k.vocabulary.contains(word);
        if (!names_language and !names_kind) continue;
        found += 1;
        const at = ts.ts_node_start_point(entry.node);
        std.debug.print("\n{s}:{d}:{d}: '{s}' is {s}; move it into the language's queries or name tables", .{ path, at.row + 1, at.column + 1, word, if (names_language) "a language name" else "a grammar node kind" });
    }
    if (found > index.triples.len) std.debug.panic("{s}: reported {d} violations from {d} captured nodes; count at most one violation per captured node, so check the loop's continue", .{ path, found, index.triples.len });
    return found;
}

const Probe = struct {
    knowledge: Knowledge,
    adapter: *const language.Adapter,
    compiled: captures.Compiled,
    constant: ?captures.Id,
    path: ?captures.Id,
};

test "no Zig source names a language or a grammar node kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const k = try learn(arena);
    const adapter = language.forPath("build.zig") orelse return error.NoAdapterForZigSource;
    const loaded = try language.load(adapter);
    defer ts.ts_query_delete(loaded.query);
    const compiled = try captures.Compiled.initCompiled(arena, loaded.query);
    const probe: Probe = .{ .knowledge = k, .adapter = adapter, .compiled = compiled, .constant = compiled.id("literal.constant"), .path = compiled.id("expression.path") };
    var total: usize = 0;
    for ([_][]const u8{ "build.zig", "src", "languages" }) |root| {
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
            total += try violations(arena, probe, root, try Io.Dir.cwd().readFileAlloc(io, root, arena, .unlimited));
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const path = try std.fs.path.join(arena, &.{ root, entry.path });
            total += try violations(arena, probe, path, try dir.readFileAlloc(io, entry.path, arena, .unlimited));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), total);
}
