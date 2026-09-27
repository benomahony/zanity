const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ts = @import("ts.zig");
const memory = @import("memory.zig");

pub const Id = u16;

pub const Name = struct {
    full: []const u8,
    family: []const u8,
    part: []const u8,
};

const Predicate = union(enum) {
    eq_capture: struct { a: u32, b: u32, positive: bool, any: bool },
    eq_string: struct { capture: u32, value: []const u8, positive: bool, any: bool },
    any_of: struct { capture: u32, values: []const []const u8, positive: bool },
    ancestor: struct { capture: u32, kinds: []const []const u8, positive: bool },
};

pub const Compiled = struct {
    query: *const ts.Query,
    names: []const Name,
    predicates: []const []const Predicate,

    pub fn initCompiled(arena: Allocator, query: *const ts.Query) !Compiled {
        const count = ts.ts_query_capture_count(query);
        assert(count <= std.math.maxInt(Id));
        const names = try arena.alloc(Name, count);
        for (names, 0..) |*n, i| {
            const full = ts.captureName(query, @intCast(i));
            const dot = std.mem.lastIndexOfScalar(u8, full, '.');
            n.* = .{
                .full = full,
                .family = if (dot) |d| full[0..d] else full,
                .part = if (dot) |d| full[d + 1 ..] else "",
            };
        }
        const patterns = ts.ts_query_pattern_count(query);
        const predicates = try arena.alloc([]const Predicate, patterns);
        for (predicates, 0..) |*p, i| p.* = try initPredicates(arena, query, @intCast(i));
        assert(predicates.len == patterns);
        return .{ .query = query, .names = names, .predicates = predicates };
    }

    pub fn has(self: Compiled, full: []const u8) bool {
        assert(full.len > 0);
        assert(self.names.len <= std.math.maxInt(Id));
        return self.id(full) != null;
    }

    pub fn id(self: Compiled, full: []const u8) ?Id {
        assert(full.len > 0);
        assert(std.mem.indexOfScalar(u8, full, '@') == null);
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
        assert(limits.captures > 0);
        assert(limits.per_file > 0);
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
        assert(hi >= lo);
        assert(hi <= self.triples.len);
        return self.triples[lo..hi];
    }

    pub fn marks(self: *const Index, node: ts.Node, capture: ?Id) bool {
        const c = capture orelse return false;
        assert(c < std.math.maxInt(Id));
        const found = self.of(node);
        assert(found.len <= self.triples.len);
        for (found) |t| if (t.id == c) return true;
        return false;
    }
};

fn keyEql(a: ts.Node.Key, b: ts.Node.Key) bool {
    assert(a.id != 0 or a.start == 0);
    assert(b.id != 0 or b.start == 0);
    return a.start == b.start and a.id == b.id;
}

fn compareKey(key: ts.Node.Key, t: Triple) std.math.Order {
    assert(t.key.id != 0);
    assert(key.id != 0);
    if (key.start != t.key.start) return std.math.order(key.start, t.key.start);
    return std.math.order(key.id, t.key.id);
}

fn tripleOrder(_: void, a: Triple, b: Triple) bool {
    assert(a.key.id != 0);
    assert(b.key.id != 0);
    if (a.key.start != b.key.start) return a.key.start < b.key.start;
    if (a.key.id != b.key.id) return a.key.id < b.key.id;
    return a.id < b.id;
}

pub fn index(scratch: *CaptureScratch, compiled: Compiled, root: ts.Node, source: []const u8) !Index {
    const query = compiled.query;
    assert(compiled.predicates.len == ts.ts_query_pattern_count(query));
    assert(ts.ts_node_end_byte(root) <= source.len);
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
    assert(kept <= all.len);
    return .{ .triples = scratch.triples.items() };
}

fn initPredicates(arena: Allocator, query: *const ts.Query, pattern: u32) ![]const Predicate {
    assert(pattern < ts.ts_query_pattern_count(query));
    var count: u32 = 0;
    const steps = ts.ts_query_predicates_for_pattern(query, pattern, &count);
    assert(count == 0 or steps[count - 1].type == .done);
    var out: std.ArrayList(Predicate) = .empty;
    var i: u32 = 0;
    while (i < count) {
        var len: u32 = 0;
        while (steps[i + len].type != .done) len += 1;
        const args = steps[i .. i + len];
        i += len + 1;
        if (args.len == 0 or args[0].type != .string) continue;
        const name = ts.stringValue(query, args[0].value_id);
        if (oneOf(name, &.{ "eq?", "not-eq?", "any-eq?", "any-not-eq?" })) {
            if (args.len != 3 or args[1].type != .capture) return error.InvalidQuery;
            const positive = oneOf(name, &.{ "eq?", "any-eq?" });
            const any = std.mem.startsWith(u8, name, "any");
            if (args[2].type == .capture) {
                try out.append(arena, .{ .eq_capture = .{ .a = args[1].value_id, .b = args[2].value_id, .positive = positive, .any = any } });
            } else {
                try out.append(arena, .{ .eq_string = .{ .capture = args[1].value_id, .value = ts.stringValue(query, args[2].value_id), .positive = positive, .any = any } });
            }
        } else if (oneOf(name, &.{ "any-of?", "not-any-of?" })) {
            if (args.len < 3 or args[1].type != .capture) return error.InvalidQuery;
            const values = try arena.alloc([]const u8, args.len - 2);
            for (args[2..], values) |arg, *v| v.* = ts.stringValue(query, arg.value_id);
            try out.append(arena, .{ .any_of = .{ .capture = args[1].value_id, .values = values, .positive = std.mem.eql(u8, name, "any-of?") } });
        } else if (oneOf(name, &.{ "has-ancestor?", "not-has-ancestor?" })) {
            if (args.len < 3 or args[1].type != .capture) return error.InvalidQuery;
            const kinds = try arena.alloc([]const u8, args.len - 2);
            for (args[2..], kinds) |arg, *k| k.* = ts.stringValue(query, arg.value_id);
            try out.append(arena, .{ .ancestor = .{ .capture = args[1].value_id, .kinds = kinds, .positive = std.mem.eql(u8, name, "has-ancestor?") } });
        } else if (!oneOf(name, &.{ "set!", "offset!", "strip!", "set-adjacent!", "select-adjacent!" })) {
            std.log.err("zanity does not evaluate the query predicate #{s}; rewrite the pattern with #eq? or #any-of?, or capture the construct structurally", .{name});
            return error.InvalidQuery;
        }
    }
    return out.items;
}

fn oneOf(name: []const u8, candidates: []const []const u8) bool {
    assert(name.len > 0);
    assert(candidates.len > 0);
    for (candidates) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

fn hasAncestor(node: ts.Node, kinds: []const []const u8) bool {
    assert(kinds.len > 0);
    var current = node.parent();
    for (0..ts.ts_node_start_point(node).row + 4096) |_| {
        const ancestor = current orelse return false;
        const kind = std.mem.span(ts.ts_node_type(ancestor));
        for (kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
        current = ancestor.parent();
    }
    assert(current != null);
    return false;
}

fn capturesOf(match: ts.QueryMatch, id: u32, buf: []ts.Node) []ts.Node {
    assert(buf.len >= match.capture_count);
    var n: usize = 0;
    for (match.captures[0..match.capture_count]) |c| {
        if (c.index == id and n < buf.len) {
            buf[n] = c.node;
            n += 1;
        }
    }
    assert(n <= match.capture_count);
    return buf[0..n];
}

fn satisfies(scratch: *CaptureScratch, predicates: []const Predicate, match: ts.QueryMatch, text: []const u8) error{LimitExceeded}!bool {
    if (predicates.len == 0) return true;
    if (match.capture_count > scratch.first.buffer.len) {
        memory.exceeded = scratch.first.what;
        return error.LimitExceeded;
    }
    const buf_a = scratch.first.buffer[0..match.capture_count];
    const buf_b = scratch.second.buffer[0..match.capture_count];
    assert(buf_a.len == match.capture_count and buf_b.len == match.capture_count);
    assert(match.capture_count == 0 or ts.ts_node_end_byte(match.captures[0].node) <= text.len);
    for (predicates) |p| {
        const ok = switch (p) {
            .any_of => |q| blk: {
                for (capturesOf(match, q.capture, buf_a)) |node| {
                    const t = node.text(text);
                    var found = false;
                    for (q.values) |v| if (std.mem.eql(u8, t, v)) {
                        found = true;
                        break;
                    };
                    if (found != q.positive) break :blk false;
                }
                break :blk true;
            },
            .ancestor => |q| blk: {
                for (capturesOf(match, q.capture, buf_a)) |node| {
                    if (hasAncestor(node, q.kinds) != q.positive) break :blk false;
                }
                break :blk true;
            },
            .eq_capture => |q| blk: {
                const a = capturesOf(match, q.a, buf_a);
                const b = capturesOf(match, q.b, buf_b);
                var result = true;
                for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
                    result = std.mem.eql(u8, x.text(text), y.text(text)) == q.positive;
                    if ((!result and !q.any) or (result and q.any)) break;
                }
                break :blk result;
            },
            .eq_string => |q| blk: {
                var result = true;
                for (capturesOf(match, q.capture, buf_a)) |x| {
                    result = std.mem.eql(u8, x.text(text), q.value) == q.positive;
                    if ((!result and !q.any) or (result and q.any)) break;
                }
                break :blk result;
            },
        };
        if (!ok) return false;
    }
    return true;
}
