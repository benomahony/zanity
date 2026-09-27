const std = @import("std");
const assert = std.debug.assert;

pub const Language = opaque {};
pub const Parser = opaque {};
pub const Tree = opaque {};
pub const Query = opaque {};
pub const QueryCursor = opaque {};

pub const Point = extern struct { row: u32, column: u32 };

pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,

    pub const Key = struct { id: usize, start: u32 };

    pub fn key(n: Node) Key {
        assert(n.id != null);
        assert(n.tree != null);
        return .{ .id = @intFromPtr(n.id), .start = ts_node_start_byte(n) };
    }
    pub fn text(n: Node, source: []const u8) []const u8 {
        const start = ts_node_start_byte(n);
        const end = ts_node_end_byte(n);
        assert(start <= end);
        assert(end <= source.len);
        return source[start..end];
    }
    pub fn parent(n: Node) ?Node {
        assert(!ts_node_is_null(n));
        const found = ts_node_parent(n);
        if (ts_node_is_null(found)) return null;
        assert(ts_node_start_byte(found) <= ts_node_start_byte(n));
        return found;
    }
    pub fn eql(a: Node, b: Node) bool {
        assert(a.tree != null);
        assert(b.tree != null);
        return a.id == b.id and ts_node_start_byte(a) == ts_node_start_byte(b);
    }
};

pub const TreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,
};

pub const QueryCapture = extern struct { node: Node, index: u32 };

pub const QueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*]const QueryCapture,
};

pub const PredicateStepType = enum(c_uint) { done = 0, capture = 1, string = 2 };
pub const PredicateStep = extern struct { type: PredicateStepType, value_id: u32 };

pub const QueryError = enum(c_uint) { none = 0, syntax, node_type, field, capture, structure, language };

pub const SymbolType = enum(c_uint) { regular = 0, anonymous, supertype, auxiliary };

pub extern fn ts_language_symbol_count(language: *const Language) u32;
pub extern fn ts_language_symbol_name(language: *const Language, symbol: u16) [*:0]const u8;
pub extern fn ts_language_symbol_type(language: *const Language, symbol: u16) SymbolType;
pub extern fn ts_parser_new() ?*Parser;
pub extern fn ts_parser_delete(parser: *Parser) void;
pub extern fn ts_parser_set_language(parser: *Parser, language: *const Language) bool;
pub extern fn ts_parser_parse_string(parser: *Parser, old_tree: ?*const Tree, string: [*]const u8, length: u32) ?*Tree;
pub extern fn ts_tree_delete(tree: *Tree) void;
pub extern fn ts_tree_root_node(tree: *const Tree) Node;

pub extern fn ts_node_type(node: Node) [*:0]const u8;
pub extern fn ts_node_start_byte(node: Node) u32;
pub extern fn ts_node_end_byte(node: Node) u32;
pub extern fn ts_node_start_point(node: Node) Point;
pub extern fn ts_node_end_point(node: Node) Point;
pub extern fn ts_node_is_named(node: Node) bool;
pub extern fn ts_node_has_error(node: Node) bool;
pub extern fn ts_node_parent(node: Node) Node;
pub extern fn ts_node_descendant_count(node: Node) u32;
pub extern fn ts_node_named_child_count(node: Node) u32;
pub extern fn ts_node_named_child(node: Node, index: u32) Node;
pub extern fn ts_node_is_null(node: Node) bool;

pub extern fn ts_tree_cursor_new(node: Node) TreeCursor;
pub extern fn ts_tree_cursor_delete(cursor: *TreeCursor) void;
pub extern fn ts_tree_cursor_current_node(cursor: *const TreeCursor) Node;
pub extern fn ts_tree_cursor_goto_first_child(cursor: *TreeCursor) bool;
pub extern fn ts_tree_cursor_goto_next_sibling(cursor: *TreeCursor) bool;
pub extern fn ts_tree_cursor_goto_parent(cursor: *TreeCursor) bool;

pub extern fn ts_query_new(language: *const Language, source: [*]const u8, length: u32, error_offset: *u32, error_type: *QueryError) ?*Query;
pub extern fn ts_query_delete(query: *Query) void;
pub extern fn ts_query_pattern_count(query: *const Query) u32;
pub extern fn ts_query_capture_count(query: *const Query) u32;
pub extern fn ts_query_string_count(query: *const Query) u32;
pub extern fn ts_query_capture_name_for_id(query: *const Query, index: u32, length: *u32) [*]const u8;
pub extern fn ts_query_string_value_for_id(query: *const Query, index: u32, length: *u32) [*]const u8;
pub extern fn ts_query_predicates_for_pattern(query: *const Query, pattern_index: u32, step_count: *u32) [*]const PredicateStep;

pub extern fn ts_query_cursor_new() ?*QueryCursor;
pub extern fn ts_query_cursor_delete(cursor: *QueryCursor) void;
pub extern fn ts_query_cursor_exec(cursor: *QueryCursor, query: *const Query, node: Node) void;
pub extern fn ts_query_cursor_next_match(cursor: *QueryCursor, match: *QueryMatch) bool;
pub extern fn ts_query_cursor_set_match_limit(cursor: *QueryCursor, limit: u32) void;

pub fn captureName(query: *const Query, id: u32) []const u8 {
    assert(id < ts_query_capture_count(query));
    var len: u32 = 0;
    const ptr = ts_query_capture_name_for_id(query, id, &len);
    assert(len > 0);
    return ptr[0..len];
}

pub fn stringValue(query: *const Query, id: u32) []const u8 {
    assert(id < ts_query_string_count(query));
    var len: u32 = 0;
    const ptr = ts_query_string_value_for_id(query, id, &len);
    assert(len < std.math.maxInt(u16));
    return ptr[0..len];
}
