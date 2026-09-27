const std = @import("std");
const assert = std.debug.assert;
const manifest = @import("manifest.zig");

pub const Tables = manifest.Tables;

pub const Grammar = fn () callconv(.c) *const anyopaque;

pub const QueryFile = struct {
    name: []const u8,
    source: []const u8,
};

pub const Adapter = struct {
    name: []const u8,
    extensions: []const []const u8,
    ecosystem: []const u8,
    grammar: *const Grammar,
    tables: *const Tables,
    families: []const QueryFile,
    query: []const u8,
    not_applicable: []const []const u8,
};

fn families(comptime entry: manifest.Entry) []const QueryFile {
    comptime {
        assert(entry.queries.len > 0);
        var out: [entry.queries.len]QueryFile = undefined;
        for (entry.queries, 0..) |family, i| {
            out[i] = .{ .name = family, .source = @embedFile(entry.name ++ "/queries/" ++ family ++ ".scm") };
        }
        const final = out;
        assert(final.len == entry.queries.len);
        return &final;
    }
}

fn querySource(comptime entry: manifest.Entry) []const u8 {
    comptime {
        assert(entry.queries.len > 0);
        var source: []const u8 = "";
        for (entry.queries) |family| source = source ++ @embedFile(entry.name ++ "/queries/" ++ family ++ ".scm") ++ "\n";
        assert(source.len > 0);
        return source;
    }
}

fn tablesFor(comptime ecosystem: []const u8) *const Tables {
    assert(ecosystem.len > 0);
    assert(manifest.tables.len > 0);
    for (manifest.tables) |*t| if (std.mem.eql(u8, t.ecosystem, ecosystem)) return t;
    @compileError("no name tables for ecosystem " ++ ecosystem);
}

pub const all: []const Adapter = blk: {
    var out: [manifest.entries.len]Adapter = undefined;
    for (manifest.entries, 0..) |entry, i| {
        out[i] = .{
            .name = entry.name,
            .extensions = entry.extensions,
            .ecosystem = entry.ecosystem,
            .grammar = @extern(*const Grammar, .{ .name = "tree_sitter_" ++ entry.name }),
            .families = families(entry),
            .query = querySource(entry),
            .tables = tablesFor(entry.ecosystem),
            .not_applicable = entry.not_applicable,
        };
    }
    const final = out;
    break :blk &final;
};
