//! Tests of the capture index's predicates that need a real grammar to parse with.
const std = @import("std");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const language = @import("language.zig");

test "ancestor predicates reach the root of deeply nested single-line source" {
    const nesting = 4100;
    const source = try std.testing.allocator.alloc(u8, nesting * 2 + 1);
    defer std.testing.allocator.free(source);
    @memset(source[0..nesting], '(');
    source[nesting] = 'x';
    @memset(source[nesting + 1 ..], ')');
    const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
    defer ts.ts_parser_delete(parser);
    _ = ts.ts_parser_set_language(parser, @ptrCast(language.forPath("a.py").?.grammar()));
    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return error.ParseFailed;
    defer ts.ts_tree_delete(tree);
    const root = ts.ts_tree_root_node(tree);
    var leaf = root;
    for (0..ts.ts_node_descendant_count(root)) |_| {
        if (ts.ts_node_named_child_count(leaf) == 0) break;
        leaf = ts.ts_node_named_child(leaf, 0);
    }
    try std.testing.expectEqualStrings("x", source[ts.ts_node_start_byte(leaf)..ts.ts_node_end_byte(leaf)]);
    const root_kind = std.mem.span(ts.ts_node_type(root));
    try std.testing.expect(captures.hasAnyAncestorKind(leaf, &.{root_kind}));
    try std.testing.expect(!captures.hasAnyAncestorKind(leaf, &.{"absent_kind"}));
}
