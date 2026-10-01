const std = @import("std");
const assert = @import("assert.zig");
const adapters = @import("adapters");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");

pub const Adapter = adapters.Adapter;
pub const Tables = adapters.Tables;
/// How many languages zanity checks.
pub const count = adapters.all.len;

pub const Loaded = struct {
    adapter: *const Adapter,
    query: *ts.Query,
};

pub const LoadError = error{ OutOfMemory, InvalidQuery };

pub fn load(adapter: *const Adapter) LoadError!Loaded {
    const source = adapter.query;
    if (source.len == 0 or source.len >= std.math.maxInt(u32)) assert.panic("{s} has {d} bytes of queries; it needs some, and fewer than 4 GiB", .{ adapter.name, source.len });
    var offset: u32 = 0;
    var err: ts.QueryError = .none;
    const language: *const ts.Language = @ptrCast(adapter.grammar());
    const query = ts.ts_query_new(language, source.ptr, @intCast(source.len), &offset, &err) orelse {
        std.log.err("{s} queries do not compile: {t} at byte {d}", .{ adapter.name, err, offset });
        return error.InvalidQuery;
    };
    if (ts.ts_query_pattern_count(query) == 0) assert.panic("{s} queries compiled to no patterns; check the query files listed in languages/manifest.zon", .{adapter.name});
    return .{ .adapter = adapter, .query = query };
}

pub fn applies(adapter: *const Adapter, name: []const u8) bool {
    const rule = rules.find(name) orelse unreachable;
    if (adapter.name.len == 0) assert.panic("an adapter has no name; check languages/manifest.zon", .{});
    if (adapter.not_applicable.len >= rules.all.len) assert.panic("{s} lists {d} rules as not applicable out of {d}; drop the language instead", .{ adapter.name, adapter.not_applicable.len, rules.all.len });
    for (adapter.not_applicable) |na| if (rule.answers(na)) return false;
    return true;
}

/// Where `adapter` sits in adapters.all, for arrays with one slot per language.
pub fn indexOf(adapter: *const Adapter) usize {
    const index = (@intFromPtr(adapter) - @intFromPtr(adapters.all.ptr)) / @sizeOf(Adapter);
    if (index >= adapters.all.len) assert.panic("adapter {s} is at index {d}, past the {d} languages; it is not from adapters.all", .{ adapter.name, index, adapters.all.len });
    if (&adapters.all[index] != adapter) assert.panic("adapter {s} is not adapters.all[{d}] ({s}); pass a pointer into adapters.all", .{ adapter.name, index, adapters.all[index].name });
    return index;
}

pub fn forPath(path: []const u8) ?*const Adapter {
    if (path.len == 0) assert.panic("asked which language an empty path is written in; skip empty paths before calling forPath()", .{});
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return null;
    if (ext[0] != '.') assert.panic("the extension of '{s}' is '{s}', which does not start with '.'; std.fs.path.extension() must return the dot with the extension", .{ path, ext });
    for (adapters.all) |*adapter| {
        for (adapter.extensions) |e| if (std.mem.eql(u8, e, ext[1..])) return adapter;
    }
    return null;
}

test "every adapter's queries compile against its grammar" {
    for (adapters.all) |*adapter| {
        const loaded = try load(adapter);
        ts.ts_query_delete(loaded.query);
    }
}

test "every @finding capture names a rule with a pattern message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var wrong: usize = 0;
    for (adapters.all) |*adapter| {
        const loaded = try load(adapter);
        defer ts.ts_query_delete(loaded.query);
        const compiled = try captures.Compiled.initCompiled(arena, loaded.query);
        for (compiled.names) |n| {
            if (!std.mem.eql(u8, n.family, "finding")) continue;
            const rule = rules.find(n.part) orelse {
                std.debug.print("\n{s} captures @finding.{s}, but there is no rule {s}", .{ adapter.name, n.part, n.part });
                wrong += 1;
                continue;
            };
            if (rule.pattern.len > 0 and applies(adapter, rule.name)) continue;
            std.debug.print("\n{s} captures @finding.{s}; give the rule a pattern message and do not list it under not_applicable", .{ adapter.name, n.part });
            wrong += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

test "every node kind a predicate names is a kind in its grammar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var unknown: usize = 0;
    for (adapters.all) |*adapter| {
        const loaded = try load(adapter);
        defer ts.ts_query_delete(loaded.query);
        const compiled = try captures.Compiled.initCompiled(arena_state.allocator(), loaded.query);
        const grammar: *const ts.Language = @ptrCast(adapter.grammar());
        for (compiled.predicates) |predicates| for (predicates) |predicate| {
            const kinds = switch (predicate) {
                .kind => |q| q.kinds,
                .ancestor => |q| q.kinds,
                else => continue,
            };
            for (kinds) |kind| {
                if (ts.ts_language_symbol_for_name(grammar, kind.ptr, @intCast(kind.len), true) != 0) continue;
                std.debug.print("\n{s}'s queries name the node kind '{s}', which its grammar doesn't have", .{ adapter.name, kind });
                unknown += 1;
            }
        };
    }
    try std.testing.expectEqual(@as(usize, 0), unknown);
}

test "every adapter supplies the captures of every rule that applies to its language" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var incomplete: usize = 0;
    for (adapters.all) |*adapter| {
        const loaded = try load(adapter);
        defer ts.ts_query_delete(loaded.query);
        const compiled = try captures.Compiled.initCompiled(arena, loaded.query);
        for (rules.all) |rule| {
            if (applies(adapter, rule.name) == false) continue;
            var buffer: [rules.max_needs][]const u8 = undefined;
            const missing = rules.missing(rule, compiled, &buffer);
            if (missing.len == 0) continue;
            incomplete += 1;
            std.debug.print("\n{s} cannot run {s}; add these captures to its queries or list the rule under not_applicable:", .{ adapter.name, rule.name });
            for (missing) |m| std.debug.print(" @{s}", .{m});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), incomplete);
}
