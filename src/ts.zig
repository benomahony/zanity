const std = @import("std");
const assert = @import("assert.zig");

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
        if (n.id == null) assert.panic("a null tree-sitter node has no key; check ts_node_is_null before indexing it", .{});
        if (n.tree == null) assert.panic("node at byte {d} belongs to no tree; the tree was deleted while its nodes were still in use", .{ts_node_start_byte(n)});
        return .{ .id = @intFromPtr(n.id), .start = ts_node_start_byte(n) };
    }
    pub fn text(n: Node, source: []const u8) []const u8 {
        const start = ts_node_start_byte(n);
        const end = ts_node_end_byte(n);
        if (start > end) assert.panic("node spans bytes {d}..{d}, which run backwards; the tree is corrupt, so check the tree was parsed from this source and not freed", .{ start, end });
        if (end > source.len) assert.panic("node ends at byte {d} but the source has {d}; it was parsed from different text than this, so pass the source the tree was parsed from", .{ end, source.len });
        return source[start..end];
    }
    pub fn parent(n: Node) ?Node {
        if (n.id == null) assert.panic("asked for the parent of a null node; check ts_node_is_null first", .{});
        const found = ts_node_parent(n);
        if (ts_node_is_null(found)) return null;
        if (ts_node_start_byte(found) > ts_node_start_byte(n)) assert.panic("parent {s} starts at byte {d}, after its child {s} at {d}; the tree is corrupt", .{ ts_node_type(found), ts_node_start_byte(found), ts_node_type(n), ts_node_start_byte(n) });
        return found;
    }
    /// Formats as `kind at line:column` with `{f}`, so a failure names the syntax it is about.
    pub fn where(n: Node) Where {
        if (n.tree == null) assert.panic("describing a node whose tree was deleted; describe it while the tree is alive", .{});
        const at = ts_node_start_point(n);
        if (at.row == std.math.maxInt(u32)) assert.panic("a {s} node reports row {d}, which no file has; pass a node from a live tree", .{ ts_node_type(n), at.row });
        return .{ .kind = std.mem.span(ts_node_type(n)), .line = at.row + 1, .column = at.column + 1 };
    }

    pub const Where = struct {
        kind: []const u8,
        line: u32,
        column: u32,

        pub fn format(w: Where, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (w.kind.len == 0) assert.panic("a node at {d}:{d} has an empty kind name; pass a node from a live tree", .{ w.line, w.column });
            if (w.line == 0 or w.column == 0) assert.panic("{s} is at {d}:{d}; lines and columns count from 1", .{ w.kind, w.line, w.column });
            try writer.print("{s} at {d}:{d}", .{ w.kind, w.line, w.column });
        }
    };

    pub fn eql(a: Node, b: Node) bool {
        if (a.tree == null) assert.panic("compared a node from no tree (its tree was deleted) with {s} at byte {d}; compare nodes only while their tree is alive", .{ ts_node_type(b), ts_node_start_byte(b) });
        if (b.tree == null) assert.panic("compared {s} at byte {d} with a node from no tree (its tree was deleted); compare nodes only while their tree is alive", .{ ts_node_type(a), ts_node_start_byte(a) });
        return a.id == b.id and ts_node_start_byte(a) == ts_node_start_byte(b);
    }
};

pub const TreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,
};

pub const QueryCapture = extern struct { node: Node, index: u32 };

pub const Quantifier = enum(c_int) { zero, zero_or_one, zero_or_more, one, one_or_more, _ };

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
pub extern fn ts_language_symbol_for_name(language: *const Language, name: [*]const u8, length: u32, is_named: bool) u16;
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
pub extern fn ts_query_disable_pattern(query: *Query, pattern_index: u32) void;
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
    if (id >= ts_query_capture_count(query)) assert.panic("capture id {d} is out of range; the query has {d} captures", .{ id, ts_query_capture_count(query) });
    var len: u32 = 0;
    const ptr = ts_query_capture_name_for_id(query, id, &len);
    if (len == 0) assert.panic("capture {d} has an empty name; every @capture in a query needs one", .{id});
    return ptr[0..len];
}

pub fn stringValue(query: *const Query, id: u32) []const u8 {
    if (id >= ts_query_string_count(query)) assert.panic("string id {d} is out of range; the query has {d} strings; pass an id from this query's predicate steps", .{ id, ts_query_string_count(query) });
    var len: u32 = 0;
    const ptr = ts_query_string_value_for_id(query, id, &len);
    if (len >= std.math.maxInt(u16)) assert.panic("query string {d} is {d} bytes long; a predicate argument that long is a broken query, so fix the predicate in the language's .scm files", .{ id, len });
    return ptr[0..len];
}
pub extern fn ts_query_capture_quantifier_for_id(query: *const Query, pattern_index: u32, capture_index: u32) Quantifier;
