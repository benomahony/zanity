const std = @import("std");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const ts = @import("ts.zig");
const memory = @import("memory.zig");

pub const Id = u16;

pub const Name = struct {
    full: []const u8,
    family: []const u8,
    part: []const u8,
};

pub const Predicate = union(enum) {
    eq_capture: struct { a: u32, b: u32, positive: bool, any: bool },
    eq_string: struct { capture: u32, value: []const u8, positive: bool, any: bool },
    any_of: struct { capture: u32, values: []const []const u8, positive: bool },
    ancestor: struct { capture: u32, kinds: []const []const u8, positive: bool },
    /// `#kind-eq? @x kind...`: `@x` is one of these node kinds. A wildcard child with this costs
    /// the query engine far less than an alternation of kinds, which it tracks one state per kind.
    kind: struct { capture: u32, kinds: []const []const u8, positive: bool },
    /// zanity's own `#empty? @x`: `@x` has no named children, not even a comment.
    empty: struct { capture: u32, positive: bool },
};

/// Splits `literal.true` into the family `literal` and the part `true`; a name with no dot is all family.
pub fn nameOf(full: []const u8) Name {
    if (full.len == 0) assert.panic("splitting an empty capture name; every capture in the .scm files is named", .{});
    const dot = std.mem.lastIndexOfScalar(u8, full, '.');
    const name: Name = .{
        .full = full,
        .family = if (dot) |d| full[0..d] else full,
        .part = if (dot) |d| full[d + 1 ..] else "",
    };
    if (name.family.len + name.part.len + @intFromBool(dot != null) != full.len) assert.panic("split '{s}' into '{s}' and '{s}', which don't add back up to it; split at the last dot", .{ full, name.family, name.part });
    return name;
}

pub const Compiled = struct {
    query: *const ts.Query,
    names: []const Name,
    predicates: []const []const Predicate,

    pub fn initCompiled(arena: Allocator, query: *const ts.Query) !Compiled {
        const count = ts.ts_query_capture_count(query);
        if (count > std.math.maxInt(Id)) assert.panic("the query has {d} capture names, more than a capture Id ({d}) can number; widen captures.Id", .{ count, std.math.maxInt(Id) });
        const names = try arena.alloc(Name, count);
        for (names, 0..) |*n, i| {
            n.* = nameOf(ts.captureName(query, @intCast(i)));
        }
        const patterns = ts.ts_query_pattern_count(query);
        const predicates = try arena.alloc([]const Predicate, patterns);
        for (predicates, 0..) |*p, i| p.* = try initPredicates(arena, query, @intCast(i));
        if (predicates.len != patterns) assert.panic("compiled predicates for {d} of {d} query patterns; initCompiled() must compile one predicate list per pattern", .{ predicates.len, patterns });
        return .{ .query = query, .names = names, .predicates = predicates };
    }

    pub fn has(self: Compiled, full: []const u8) bool {
        if (full.len == 0) assert.panic("asked whether the query has a capture with an empty name; pass a name such as 'call.name'", .{});
        if (self.names.len > std.math.maxInt(Id)) assert.panic("the query has {d} capture names, more than a capture Id can number; widen captures.Id, or split the language's queries", .{self.names.len});
        return self.id(full) != null;
    }

    pub fn id(self: Compiled, full: []const u8) ?Id {
        if (full.len == 0) assert.panic("looked up a capture with an empty name; pass a name such as 'call.name'", .{});
        if (std.mem.indexOfScalar(u8, full, '@') != null) assert.panic("looked up capture '{s}'; capture names are written without the '@'", .{full});
        for (self.names, 0..) |n, i| if (std.mem.eql(u8, n.full, full)) return @intCast(i);
        return null;
    }
};

pub const Triple = struct { key: ts.Node.Key, node: ts.Node, id: Id };

pub const CaptureScratch = struct {
    triples: memory.Bounded(Triple),
    first: memory.Bounded(ts.Node),
    second: memory.Bounded(ts.Node),

    pub fn initCaptureScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!CaptureScratch {
        if (limits.captures == 0) assert.panic("memory.Limits.captures is 0, so no query capture could be recorded", .{});
        if (limits.per_file == 0) assert.panic("memory.Limits.per_file is 0, so no query match could be checked", .{});
        return .{
            .triples = try .initBounded(gpa, limits.captures, "captured nodes in one file"),
            .first = try .initBounded(gpa, limits.per_file, "captures in one query match"),
            .second = try .initBounded(gpa, limits.per_file, "captures in one query match"),
        };
    }
};

pub const Index = struct {
    triples: []const Triple,

    pub fn of(self: *const Index, node: ts.Node) []const Triple {
        const key = node.key();
        const lo = std.sort.lowerBound(Triple, self.triples, key, compareKey);
        var hi = lo;
        while (hi < self.triples.len and keyEql(self.triples[hi].key, key)) hi += 1;
        if (hi < lo) assert.panic("the captures of the node at byte {d} run backwards ({d}..{d}); index() must sort the triples by node key before lookups", .{ key.start, lo, hi });
        if (hi > self.triples.len) assert.panic("the captures of the node at byte {d} end at {d}, past the {d} recorded; of() must stop at the recorded triples, so check its upper bound", .{ key.start, hi, self.triples.len });
        return self.triples[lo..hi];
    }

    pub fn marks(self: *const Index, node: ts.Node, capture: ?Id) bool {
        const c = capture orelse return false;
        if (c >= std.math.maxInt(Id)) assert.panic("capture id {d} is out of range; pass an id from Compiled.id() on this language's query, not another's", .{c});
        const found = self.of(node);
        if (found.len > self.triples.len) assert.panic("found {d} captures on one node, more than the {d} recorded; of() must slice within the recorded triples, so check its bounds", .{ found.len, self.triples.len });
        for (found) |t| if (t.id == c) return true;
        return false;
    }
};

fn keyEql(a: ts.Node.Key, b: ts.Node.Key) bool {
    if (a.id == 0 and a.start != 0) assert.panic("a node at byte {d} has no id; it came from a null node; check ts_node_is_null before taking a node's key", .{a.start});
    if (b.id == 0 and b.start != 0) assert.panic("a node at byte {d} has no id; it came from a null node; check ts_node_is_null before taking a node's key", .{b.start});
    return a.start == b.start and a.id == b.id;
}

fn compareKey(key: ts.Node.Key, t: Triple) std.math.Order {
    if (t.key.id == 0) assert.panic("a recorded capture at byte {d} has no node id; index() must skip null nodes when it records captures", .{t.key.start});
    if (key.id == 0) assert.panic("looked up the captures of a null node (byte {d}); check ts_node_is_null before calling of() or marks()", .{key.start});
    if (key.start != t.key.start) return std.math.order(key.start, t.key.start);
    return std.math.order(key.id, t.key.id);
}

fn tripleOrder(_: void, a: Triple, b: Triple) bool {
    if (a.key.id == 0) assert.panic("a recorded capture at byte {d} has no node id; index() must skip null nodes when it records captures", .{a.key.start});
    if (b.key.id == 0) assert.panic("a recorded capture at byte {d} has no node id; index() must skip null nodes when it records captures", .{b.key.start});
    if (a.key.start != b.key.start) return a.key.start < b.key.start;
    if (a.key.id != b.key.id) return a.key.id < b.key.id;
    return a.id < b.id;
}

pub fn index(scratch: *CaptureScratch, compiled: Compiled, root: ts.Node, source: []const u8) !Index {
    const query = compiled.query;
    if (compiled.predicates.len != ts.ts_query_pattern_count(query)) assert.panic("the query has {d} patterns but predicates were compiled for {d}; compile predicates from this query", .{ ts.ts_query_pattern_count(query), compiled.predicates.len });
    if (ts.ts_node_end_byte(root) > source.len) assert.panic("the tree ends at byte {d} but the source has {d}; it was parsed from different text", .{ ts.ts_node_end_byte(root), source.len });
    scratch.triples.clear();
    const cursor = ts.ts_query_cursor_new() orelse return error.OutOfMemory;
    defer ts.ts_query_cursor_delete(cursor);
    ts.ts_query_cursor_set_match_limit(cursor, std.math.maxInt(u32));
    ts.ts_query_cursor_exec(cursor, query, root);
    var match: ts.QueryMatch = undefined;
    while (ts.ts_query_cursor_next_match(cursor, &match)) {
        if (!try satisfies(scratch, compiled.predicates[match.pattern_index], match, source)) continue;
        for (match.captures[0..match.capture_count]) |c| {
            if (std.mem.startsWith(u8, compiled.names[c.index].full, "_")) continue;
            if (ts.ts_node_start_byte(c.node) == ts.ts_node_end_byte(c.node)) continue;
            try scratch.triples.add(.{ .key = c.node.key(), .node = c.node, .id = @intCast(c.index) });
        }
    }
    const all = scratch.triples.items();
    std.mem.sort(Triple, all, {}, tripleOrder);
    var kept: usize = 0;
    for (all) |t| {
        if (kept > 0 and keyEql(all[kept - 1].key, t.key) and all[kept - 1].id == t.id) continue;
        all[kept] = t;
        kept += 1;
    }
    scratch.triples.len = kept;
    if (kept > all.len) assert.panic("removing duplicate captures kept {d} of {d}; the de-duplication must keep at least one of each node, so check its comparison", .{ kept, all.len });
    return .{ .triples = scratch.triples.items() };
}

fn initPredicates(arena: Allocator, query: *const ts.Query, pattern: u32) ![]const Predicate {
    if (pattern >= ts.ts_query_pattern_count(query)) assert.panic("asked for the predicates of pattern {d}, but the query has {d}; loop only over the ts_query_pattern_count patterns", .{ pattern, ts.ts_query_pattern_count(query) });
    var count: u32 = 0;
    const steps = ts.ts_query_predicates_for_pattern(query, pattern, &count);
    if (count != 0 and steps[count - 1].type != .done) assert.panic("pattern {d}'s {d} predicate steps do not end with a terminator; tree-sitter's predicate list is malformed, so check that the grammar and vendor/tree-sitter/REVISION are versions that work together", .{ pattern, count });
    var out: std.ArrayList(Predicate) = .empty;
    var i: u32 = 0;
    while (i < count) {
        var len: u32 = 0;
        while (steps[i + len].type != .done) len += 1;
        const args = steps[i .. i + len];
        i += len + 1;
        if (try initPredicate(arena, query, args)) |predicate| try out.append(arena, predicate);
    }
    return out.items;
}

/// One predicate from its steps, `#name? @capture args...`; null for directives such as `#set!`.
fn initPredicate(arena: Allocator, query: *const ts.Query, args: []const ts.PredicateStep) !?Predicate {
    if (args.len > 64) assert.panic("a query predicate has {d} arguments; no predicate takes that many, so the step list is corrupt, so check that the grammar and vendor/tree-sitter/REVISION are versions that work together", .{args.len});
    if (args.len == 0 or args[0].type != .string) return null;
    const name = ts.stringValue(query, args[0].value_id);
    if (oneOf(name, &.{ "set!", "offset!", "strip!", "set-adjacent!", "select-adjacent!" })) return null;
    if (args.len < 2 or args[1].type != .capture) {
        std.log.err("#{s} needs a @capture as its first argument", .{name});
        return error.InvalidQuery;
    }
    const capture = args[1].value_id;
    if (capture >= ts.ts_query_capture_count(query)) assert.panic("#{s} names capture {d}, but the query has {d}; a predicate must name a capture in its own pattern, so fix it in the language's .scm files", .{ name, capture, ts.ts_query_capture_count(query) });
    if (oneOf(name, &.{ "eq?", "not-eq?", "any-eq?", "any-not-eq?" })) {
        if (args.len != 3) return error.InvalidQuery;
        const positive = oneOf(name, &.{ "eq?", "any-eq?" });
        const any = std.mem.startsWith(u8, name, "any");
        if (args[2].type == .capture) return .{ .eq_capture = .{ .a = capture, .b = args[2].value_id, .positive = positive, .any = any } };
        return .{ .eq_string = .{ .capture = capture, .value = ts.stringValue(query, args[2].value_id), .positive = positive, .any = any } };
    }
    if (oneOf(name, &.{ "any-of?", "not-any-of?", "has-ancestor?", "not-has-ancestor?", "kind-eq?", "not-kind-eq?" })) {
        if (args.len < 3) return error.InvalidQuery;
        const values = try arena.alloc([]const u8, args.len - 2);
        for (args[2..], values) |arg, *v| v.* = ts.stringValue(query, arg.value_id);
        if (std.mem.endsWith(u8, name, "any-of?")) return .{ .any_of = .{ .capture = capture, .values = values, .positive = name[0] != 'n' } };
        if (std.mem.endsWith(u8, name, "kind-eq?")) return .{ .kind = .{ .capture = capture, .kinds = values, .positive = name[0] != 'n' } };
        return .{ .ancestor = .{ .capture = capture, .kinds = values, .positive = name[0] != 'n' } };
    }
    if (oneOf(name, &.{ "empty?", "not-empty?" })) return .{ .empty = .{ .capture = capture, .positive = name[0] != 'n' } };
    std.log.err("zanity does not evaluate the query predicate #{s}; rewrite the pattern with #eq?, #any-of?, #kind-eq?, #has-ancestor? or #empty?, or capture the construct structurally", .{name});
    return error.InvalidQuery;
}

fn oneOf(name: []const u8, candidates: []const []const u8) bool {
    if (name.len == 0) assert.panic("a query predicate has an empty name; predicates look like #eq?", .{});
    if (candidates.len == 0) assert.panic("checked predicate #{s} against no known predicate names; add the predicate to the switch in initPredicate(), or remove it from the language's .scm files", .{name});
    for (candidates) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

fn hasAncestor(node: ts.Node, kinds: []const []const u8) bool {
    if (kinds.len == 0) assert.panic("#has-ancestor? names no node kinds; list at least one after the capture", .{});
    var current = node.parent();
    for (0..ts.ts_node_start_point(node).row + 4096) |_| {
        const ancestor = current orelse return false;
        const kind = std.mem.span(ts.ts_node_type(ancestor));
        for (kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
        current = ancestor.parent();
    }
    if (current == null) assert.panic("the ancestor walk from {s} at byte {d} ran out of steps on a null node instead of returning; the walk must stop at the root, so check its loop condition", .{ ts.ts_node_type(node), ts.ts_node_start_byte(node) });
    return false;
}

fn capturesOf(match: ts.QueryMatch, id: u32, buf: []ts.Node) []ts.Node {
    if (buf.len < match.capture_count) assert.panic("room for {d} captures but the match has {d}; raise memory.Limits.per_file", .{ buf.len, match.capture_count });
    var n: usize = 0;
    for (match.captures[0..match.capture_count]) |c| {
        if (c.index == id and n < buf.len) {
            buf[n] = c.node;
            n += 1;
        }
    }
    if (n > match.capture_count) assert.panic("found {d} nodes for capture {d} in a match of {d} captures; capturesOf() must stop at the match's capture count", .{ n, id, match.capture_count });
    return buf[0..n];
}

fn satisfies(scratch: *CaptureScratch, predicates: []const Predicate, match: ts.QueryMatch, text: []const u8) error{LimitExceeded}!bool {
    if (predicates.len == 0) return true;
    if (match.capture_count > scratch.first.buffer.len) {
        memory.exceeded = scratch.first.what;
        return error.LimitExceeded;
    }
    const buffers: Buffers = .{ .a = scratch.first.buffer[0..match.capture_count], .b = scratch.second.buffer[0..match.capture_count] };
    if (buffers.a.len != match.capture_count or buffers.b.len != match.capture_count) assert.panic("predicate buffers hold {d} and {d} nodes for a match of {d}; raise the predicate buffers in satisfies() to the largest match", .{ buffers.a.len, buffers.b.len, match.capture_count });
    if (match.capture_count > 0 and ts.ts_node_end_byte(match.captures[0].node) > text.len) assert.panic("a match ends at byte {d} but the source has {d}; the tree was parsed from different text", .{ ts.ts_node_end_byte(match.captures[0].node), text.len });
    for (predicates) |p| if (!holds(p, match, buffers, text)) return false;
    return true;
}

const Buffers = struct { a: []ts.Node, b: []ts.Node };

fn holds(predicate: Predicate, match: ts.QueryMatch, buffers: Buffers, text: []const u8) bool {
    if (buffers.a.len < match.capture_count) assert.panic("room for {d} captures but the match has {d}; raise the capture buffer in holds(), or split the pattern into smaller ones", .{ buffers.a.len, match.capture_count });
    const result = switch (predicate) {
        .any_of => |q| for (capturesOf(match, q.capture, buffers.a)) |node| {
            if (oneOfText(node.text(text), q.values) != q.positive) break false;
        } else true,
        .ancestor => |q| for (capturesOf(match, q.capture, buffers.a)) |node| {
            if (hasAncestor(node, q.kinds) != q.positive) break false;
        } else true,
        .kind => |q| for (capturesOf(match, q.capture, buffers.a)) |node| {
            if (oneOfText(std.mem.span(ts.ts_node_type(node)), q.kinds) != q.positive) break false;
        } else true,
        .empty => |q| for (capturesOf(match, q.capture, buffers.a)) |node| {
            if ((ts.ts_node_named_child_count(node) == 0) != q.positive) break false;
        } else true,
        .eq_capture => |q| equalTexts(capturesOf(match, q.a, buffers.a), capturesOf(match, q.b, buffers.b), .{ .positive = q.positive, .any = q.any }, text),
        .eq_string => |q| equalToString(capturesOf(match, q.capture, buffers.a), q.value, .{ .positive = q.positive, .any = q.any }, text),
    };
    if (buffers.b.len < match.capture_count) assert.panic("room for {d} second captures but the match has {d}; raise the capture buffer in holds(), or split the pattern into smaller ones", .{ buffers.b.len, match.capture_count });
    return result;
}

const Sense = struct { positive: bool, any: bool };

fn oneOfText(text: []const u8, values: []const []const u8) bool {
    if (values.len == 0) assert.panic("#any-of? lists no values to compare '{s}' with; give #any-of? at least one value in the language's .scm files", .{text});
    for (values) |v| {
        if (v.len == 0) assert.panic("#any-of? lists an empty value alongside '{s}'; remove it from the query", .{values[0]});
        if (std.mem.eql(u8, text, v)) return true;
    }
    return false;
}

/// `#eq? @a @b`: pairs of captures have equal text; with `any`, at least one pair does.
fn equalTexts(a: []const ts.Node, b: []const ts.Node, sense: Sense, text: []const u8) bool {
    const n = @min(a.len, b.len);
    if (n > a.len or n > b.len) assert.panic("compared {d} pairs of {d} and {d} captures; equalTexts() must compare pairs up to the shorter list, so check its loop", .{ n, a.len, b.len });
    var result = true;
    for (a[0..n], b[0..n]) |x, y| {
        result = std.mem.eql(u8, x.text(text), y.text(text)) == sense.positive;
        if (result == sense.any) break;
    }
    if (n > 0 and ts.ts_node_end_byte(a[0]) > text.len) assert.panic("compared a capture ending at byte {d} of a {d}-byte source; pass the source the tree was parsed from", .{ ts.ts_node_end_byte(a[0]), text.len });
    return result;
}

/// `#eq? @a "text"`: each capture's text is `value`; with `any`, at least one is.
fn equalToString(nodes: []const ts.Node, value: []const u8, sense: Sense, text: []const u8) bool {
    if (nodes.len > 0 and ts.ts_node_end_byte(nodes[0]) > text.len) assert.panic("comparing a capture that ends at byte {d} of a {d}-byte source; pass the source the tree was parsed from", .{ ts.ts_node_end_byte(nodes[0]), text.len });
    var result = true;
    for (nodes) |x| {
        result = std.mem.eql(u8, x.text(text), value) == sense.positive;
        if (result == sense.any) break;
    }
    if (nodes.len == 0 and !result) assert.panic("#eq? with '{s}' failed with no captures to compare; the predicate's capture must be in the same pattern, so fix it in the language's .scm files", .{value});
    return result;
}
