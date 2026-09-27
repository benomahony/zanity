const std = @import("std");
const assert = std.debug.assert;
const adapters = @import("adapters");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");

pub const Adapter = adapters.Adapter;
pub const Tables = adapters.Tables;

pub const Loaded = struct {
    adapter: *const Adapter,
    query: *ts.Query,
};

pub const LoadError = error{ OutOfMemory, InvalidQuery };

pub fn load(adapter: *const Adapter) LoadError!Loaded {
    const source = adapter.query;
    assert(source.len > 0 and source.len < std.math.maxInt(u32));
    var offset: u32 = 0;
    var err: ts.QueryError = .none;
    const language: *const ts.Language = @ptrCast(adapter.grammar());
    const query = ts.ts_query_new(language, source.ptr, @intCast(source.len), &offset, &err) orelse {
        std.log.err("{s} queries do not compile: {t} at byte {d}", .{ adapter.name, err, offset });
        return error.InvalidQuery;
    };
    assert(ts.ts_query_pattern_count(query) > 0);
    return .{ .adapter = adapter, .query = query };
}

pub fn applies(adapter: *const Adapter, name: []const u8) bool {
    const rule = rules.find(name) orelse unreachable;
    assert(adapter.name.len > 0);
    assert(adapter.not_applicable.len < rules.all.len);
    for (adapter.not_applicable) |na| if (rule.answers(na)) return false;
    return true;
}

pub fn forPath(path: []const u8) ?*const Adapter {
    assert(path.len > 0);
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return null;
    assert(ext[0] == '.');
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
