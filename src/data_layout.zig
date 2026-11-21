//! The data layout checks: work a loop repeats on every pass that it could do once, such as
//! allocating or computing the same value, and reading out of each element into another object.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const rules = @import("rules.zig");
const repeats = @import("repeats.zig");
const captures = @import("captures.zig");
const scope = @import("scope.zig");
const File = check.File;
const Context = check.Context;

/// The loop that runs `call` on every pass: the innermost loop inside `function`, unless `call`
/// sits in that loop's iterable, which runs once.
fn passLoop(self: *File, call: ts.Node, function: *const Context) ?*Context {
    const loop = self.innermost(.loop) orelse return null;
    if (ts.ts_node_start_byte(loop.node) < ts.ts_node_start_byte(function.node)) return null;
    if (ts.ts_node_start_byte(call) < ts.ts_node_start_byte(loop.node)) assert.panic("{s}: the call {f} starts before its loop {f}; innermost() must return a loop still open around it", .{ self.work.facts.path, call.where(), loop.node.where() });
    if (ts.ts_node_end_byte(call) > ts.ts_node_end_byte(loop.node)) assert.panic("{s}: the call {f} ends after its loop {f}; innermost() must return a loop still open around it", .{ self.work.facts.path, call.where(), loop.node.where() });
    const iterable = loop.iterable orelse return loop;
    if (ts.ts_node_start_byte(call) >= ts.ts_node_start_byte(iterable) and ts.ts_node_end_byte(call) <= ts.ts_node_end_byte(iterable)) return null;
    return loop;
}

/// An allocating call on every pass of a loop. Growth calls such as `push` are left out: growing
/// a collection costs little once spread over its elements.
pub fn checkAllocationInLoop(self: *File, ctx: Context, function: *const Context, shown: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking the allocation in {f}, which is a {t}, not a call; call checkAllocationInLoop() only for calls", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (function.family != .function) assert.panic("{s}: the allocation {f} belongs to a {t}, not a function; pass enclosingFunction()", .{ self.work.facts.path, ctx.node.where(), function.family });
    const loop = passLoop(self, ctx.node, function) orelse return;
    const owner = function.name.?.text(self.source);
    _ = try self.report(ctx.node, "allocation-in-loop", try self.say("'{s}' allocates on every pass of the loop on line {d} of '{s}', so its cost grows with the data and the allocations scatter it across memory.", .{ shown, ts.ts_node_start_point(loop.node).row + 1, owner }));
}

/// A computed expression on every pass of a loop that reads nothing the loop changes and calls
/// only what the language's tables list as pure, such as `len(items)` or `word.toLowerCase()` in
/// a loop over lines, so each pass computes the same value again. Only the largest such
/// expression is reported, not each part of it.
pub fn checkInvariant(self: *File, node: ts.Node) !void {
    if (!self.checker.enabled.enabled("invariant-in-loop")) return;
    if (ts.ts_node_end_byte(node) <= ts.ts_node_start_byte(node)) assert.panic("{s}: the expression {f} covers no text; put @expression.repeatable on the whole expression in the language's zanity.scm", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: the expression {f} ends past the {d}-byte file; pass a node from this file's tree", .{ self.work.facts.path, node.where(), self.source.len });
    const function = self.enclosingFunction() orelse return;
    const loop = passLoop(self, node, function) orelse return;
    if (loop.condition) |condition| if (ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(condition) and ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(condition)) return;
    if (!hoistable(self, node, loop)) return;
    var up = node.parent();
    while (up) |outer| : (up = outer.parent()) {
        if (outer.eql(loop.node)) break;
        if (self.index.marks(outer, self.v.expression_repeatable) and hoistable(self, outer, loop)) return;
    }
    _ = try self.report(node, "invariant-in-loop", try self.say("'{s}' is computed on every pass of the loop on line {d}, but nothing it reads changes in the loop, so every pass gets the same value.", .{ check.header(node.text(self.source)), ts.ts_node_start_point(loop.node).row + 1 }));
}

/// Whether `node` is a call whose every call is pure and whose every name the loop leaves alone.
fn hoistable(self: *File, node: ts.Node, loop: *const Context) bool {
    if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(loop.node)) assert.panic("{s}: the expression {f} starts before its loop {f}; pass the loop around it", .{ self.work.facts.path, node.where(), loop.node.where() });
    if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(loop.node)) assert.panic("{s}: the expression {f} ends after its loop {f}; pass the loop around it", .{ self.work.facts.path, node.where(), loop.node.where() });
    const text = node.text(self.source);
    if (text[text.len - 1] != ')' or !allPure(self, text) or !repeats.candidate(self, node)) return false;
    var reads: Reads = .{ .file = self, .text = text };
    var read: u32 = 0;
    while (reads.next()) |word| {
        read += 1;
        if (changesElsewhere(self, loop, word, node)) return false;
    }
    return read > 0;
}

/// Whether every call in `text` is one of the language's pure calls, and there is at least one.
fn allPure(self: *File, text: []const u8) bool {
    if (text.len == 0) assert.panic("{s}: asked whether an empty expression is pure; the @expression.repeatable capture matched no text", .{self.work.facts.path});
    if (self.tables.pure_calls.len == 0) return false;
    var calls: u32 = 0;
    for (text, 0..) |c, open| {
        if (c != '(') continue;
        var start = open;
        while (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or std.mem.indexOfScalar(u8, "_.:", text[start - 1]) != null)) start -= 1;
        const callee = std.mem.trimStart(u8, text[start..open], ".:");
        if (callee.len == 0) continue;
        if (!pure(self, callee)) return false;
        calls += 1;
    }
    if (calls > text.len) assert.panic("{s}: counted {d} calls in the {d}-byte '{s}'; allPure() counts at most one per parenthesis", .{ self.work.facts.path, calls, text.len, text });
    return calls > 0;
}

/// Whether `callee` is a pure call: one written with its module, such as `re.compile`, by its
/// whole name, and a method, such as `toLowerCase`, by its last.
fn pure(self: *File, callee: []const u8) bool {
    if (callee.len == 0) assert.panic("{s}: asked whether an empty callee is pure; allPure() skips parentheses with no callee", .{self.work.facts.path});
    const last = callee[if (std.mem.lastIndexOfAny(u8, callee, ".:")) |at| at + 1 else 0..];
    if (last.len > callee.len) assert.panic("{s}: the called name '{s}' is longer than its callee '{s}'", .{ self.work.facts.path, last, callee });
    for (self.tables.pure_calls) |entry| {
        const qualified = std.mem.indexOfAny(u8, entry, ".:") != null;
        if (std.mem.eql(u8, entry, if (qualified) callee else last)) return true;
    }
    return false;
}

/// The names an expression reads, in order: each identifier outside a string that isn't a member
/// after `.`, a callee before `(`, a keyword, or a capitalised constant or type. A self receiver
/// reads its first member, as `self.limit` does.
const Reads = struct {
    file: *File,
    text: []const u8,
    at: usize = 0,
    quote: u8 = 0,

    fn next(r: *Reads) ?[]const u8 {
        if (r.at > r.text.len) assert.panic("reading names at {d} of the {d}-byte '{s}'; next() must stop at the end", .{ r.at, r.text.len, r.text });
        while (r.at < r.text.len) {
            const c = r.text[r.at];
            if (r.quote != 0 or c == '"' or c == '\'' or c == '`') {
                r.quote = if (r.quote == 0) c else if (c == r.quote) 0 else r.quote;
                r.at += 1;
                continue;
            }
            if (!(std.ascii.isAlphabetic(c) or c == '_')) {
                r.at += 1;
                continue;
            }
            const from = r.at;
            while (r.at < r.text.len and (std.ascii.isAlphanumeric(r.text[r.at]) or r.text[r.at] == '_')) r.at += 1;
            if (readName(r.file, r.text, from, r.at)) |word| {
                r.at = from + word.len;
                return word;
            }
        }
        if (r.quote > 0x7f) assert.panic("'{s}' left a quote of byte {d} open; next() only opens ASCII quotes", .{ r.text, r.quote });
        return null;
    }
};

/// The name the identifier at `text[from..to]` reads, or null when it reads none of its own.
fn readName(self: *File, text: []const u8, from: usize, to: usize) ?[]const u8 {
    if (to <= from or to > text.len) assert.panic("{s}: the identifier at {d}..{d} is outside the {d}-byte expression '{s}'", .{ self.work.facts.path, from, to, text.len, text });
    if (!(std.ascii.isAlphabetic(text[from]) or text[from] == '_')) assert.panic("{s}: the identifier at {d} of '{s}' starts with '{c}'; Reads must start names at a letter or _", .{ self.work.facts.path, from, text, text[from] });
    const word = text[from..to];
    if (isMember(text[0..from])) return null;
    const after = std.mem.trimStart(u8, text[to..], " ");
    if (after.len > 0 and after[0] == '(') return null;
    const receiver = check.contains(self.tables.self_receivers, word);
    if (!receiver and (std.ascii.isUpper(word[0]) or check.contains(self.tables.reserved_words, word))) return null;
    if (!receiver) return word;
    if (after.len < 2 or after[0] != '.') return null;
    var member_end = to + 1;
    while (member_end < text.len and (std.ascii.isAlphanumeric(text[member_end]) or text[member_end] == '_')) member_end += 1;
    return text[from..member_end];
}

/// Whether a name after `before` is a member, as `len` is in `items.len` or `Path::new`, rather
/// than the end of a range, as `len` is in `0..len`.
fn isMember(before: []const u8) bool {
    if (before.len == 0) return false;
    if (before.len > 1 and before[before.len - 1] == '.' and before[before.len - 2] == '.') return false;
    if (std.mem.indexOfScalar(u8, before, '\n') != null) assert.panic("'{s}' spans lines; candidate() keeps only expressions on one line", .{before});
    if (std.mem.indexOfScalar(u8, before, 0) != null) assert.panic("'{s}' holds a NUL byte; pass the text of an expression", .{before});
    return std.mem.indexOfScalar(u8, ".:>", before[before.len - 1]) != null;
}

/// Where a loop's header ends: after its iterable or condition, or else at the end of its first
/// line. Bindings after it, such as Zig's `|item|`, are found by binds().
fn bodyStart(self: *File, loop: *const Context) u32 {
    const start = ts.ts_node_start_byte(loop.node);
    if (start >= ts.ts_node_end_byte(loop.node)) assert.panic("{s}: the loop {f} covers no text; capture the whole loop as @loop.outer", .{ self.work.facts.path, loop.node.where() });
    if (loop.iterable orelse loop.condition) |header| return ts.ts_node_end_byte(header);
    const line = std.mem.indexOfScalar(u8, self.source[start..ts.ts_node_end_byte(loop.node)], '\n') orelse return ts.ts_node_end_byte(loop.node);
    if (start + line > ts.ts_node_end_byte(loop.node)) assert.panic("{s}: the first line of {f} ends past the loop; bodyStart() must search within it", .{ self.work.facts.path, loop.node.where() });
    return @intCast(start + line);
}

/// Whether the loop changes `word` outside `expression`, which reads it: binds it in its header,
/// takes its address, assigns it, or calls a mutating method on it.
fn changesElsewhere(self: *File, loop: *const Context, word: []const u8, expression: ts.Node) bool {
    const loop_start = ts.ts_node_start_byte(loop.node);
    const text = self.source[loop_start..ts.ts_node_end_byte(loop.node)];
    if (word.len == 0) assert.panic("looked for an empty name in a loop; readName() returns only identifiers", .{});
    if (ts.ts_node_start_byte(expression) < loop_start) assert.panic("{s}: the expression {f} starts before the loop {f}; pass the loop around it", .{ self.work.facts.path, expression.where(), loop.node.where() });
    const header_end = bodyStart(self, loop);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |at| : (from = at + 1) {
        const before = if (at > 0) text[at - 1] else ' ';
        const after = at + word.len;
        if (std.ascii.isAlphanumeric(before) or before == '_' or before == '.') continue;
        if (after < text.len and (std.ascii.isAlphanumeric(text[after]) or text[after] == '_')) continue;
        const where = loop_start + at;
        if (where >= ts.ts_node_start_byte(expression) and where < ts.ts_node_end_byte(expression)) continue;
        if (where < header_end or before == '&' or binds(text[0..at], text[after..]) or writes(self, text[after..])) return true;
    }
    return assignedIn(self, loop.node, word, expression);
}

/// Whether a loop's assignments, as its `@write.target` captures name them, write `word` outside
/// `expression`, as `fired, answered = having(rule)` writes `fired`.
fn assignedIn(self: *File, loop: ts.Node, word: []const u8, expression: ts.Node) bool {
    const start = ts.ts_node_start_byte(loop);
    const end = ts.ts_node_end_byte(loop);
    if (end > self.source.len) assert.panic("{s}: the loop {f} ends past the {d}-byte file; pass a node from this file's tree", .{ self.work.facts.path, loop.where(), self.source.len });
    if (ts.ts_node_start_byte(expression) < start) assert.panic("{s}: the expression {f} starts before the loop {f}; pass the loop around it", .{ self.work.facts.path, expression.where(), loop.where() });
    const target = self.v.write_target orelse return false;
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, captures.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != target or t.key.start >= ts.ts_node_start_byte(expression) and t.key.start < ts.ts_node_end_byte(expression)) continue;
        if (scope.containsWord(t.node.text(self.source), word)) return true;
    }
    return false;
}

/// Whether a name between `before` and `after` is being bound rather than read: declared, as in
/// `const stop` or `local line`, or bound by a loop, as in `|entry|`, `for name in` or
/// `for (String line : lines)`.
fn binds(before: []const u8, after: []const u8) bool {
    const left = std.mem.trimEnd(u8, before, " \t\r\n*");
    const right = std.mem.trimStart(u8, after, " \t\r\n");
    if (left.len > before.len) assert.panic("trimming '{s}' before a name gave the longer '{s}'; binds() must only trim", .{ before, left });
    if (right.len > after.len) assert.panic("trimming '{s}' after a name gave the longer '{s}'; binds() must only trim", .{ after, right });
    if (payload(left, right) or std.mem.startsWith(u8, right, "in ")) return true;
    if (std.mem.startsWith(u8, right, ":") and !std.mem.startsWith(u8, right, "::")) return true;
    return declared(left);
}

/// Whether a name sits in a capture list between pipes, as `item` does in `|item|` or `|i, item|`.
fn payload(left: []const u8, right: []const u8) bool {
    if (left.len > 0 and std.ascii.isWhitespace(left[left.len - 1])) assert.panic("'{s}' ends with whitespace; trim it before calling payload()", .{left});
    if (right.len > 0 and std.ascii.isWhitespace(right[0])) assert.panic("'{s}' starts with whitespace; trim it before calling payload()", .{right});
    const opening = if (left.len > 0) left[left.len - 1] else ' ';
    const closing = if (right.len > 0) right[0] else ' ';
    const separators = (opening == '|' or opening == ',') and (closing == '|' or closing == ',');
    return separators and (opening == '|' or closing == '|');
}

/// Whether `left`, the text before a name, ends with a declaration keyword, as `const stop` does.
fn declared(left: []const u8) bool {
    if (declarations.len == 0) assert.panic("no declaration keywords to compare '{s}' with; list them in declarations", .{left});
    if (left.len > 0 and std.ascii.isWhitespace(left[left.len - 1])) assert.panic("'{s}' ends with whitespace; trim it before calling declared()", .{left});
    for (declarations) |keyword| {
        if (left.len < keyword.len or !std.mem.endsWith(u8, left, keyword)) continue;
        const start = left.len - keyword.len;
        if (start == 0 or !(std.ascii.isAlphanumeric(left[start - 1]) or left[start - 1] == '_')) return true;
    }
    return false;
}

const declarations = [_][]const u8{ "let", "const", "var", "local", "mut", "val", "auto" };

/// Whether the text after a name changes it: a call of one of the language's mutating methods
/// through any members, as `items.pop()` or `self.seen.add(x)` are, or an assignment.
fn writes(self: *File, rest: []const u8) bool {
    if (rest.len > self.source.len) assert.panic("{s}: the text after a name is {d} bytes, more than the {d}-byte file; pass a slice of the loop", .{ self.work.facts.path, rest.len, self.source.len });
    var at: usize = 0;
    while (at < rest.len and rest[at] == '.') {
        const member_start = at + 1;
        at = member_start;
        while (at < rest.len and (std.ascii.isAlphanumeric(rest[at]) or rest[at] == '_')) at += 1;
        const after = std.mem.trimStart(u8, rest[at..], " ");
        if (after.len > 0 and after[0] == '(' and at > member_start and check.contains(self.tables.mutating_calls, rest[member_start..at])) return true;
    }
    if (at > rest.len) assert.panic("{s}: read members to byte {d} of the {d} after a name; writes() must stop at the end", .{ self.work.facts.path, at, rest.len });
    return assigns(std.mem.trimStart(u8, rest[at..], " \t\r\n"));
}

/// Whether `rest` starts with an assignment or increment, such as `=`, `+=`, `:=` or `++`.
fn assigns(rest: []const u8) bool {
    if (rest.len > 0 and std.ascii.isWhitespace(rest[0])) assert.panic("'{s}' starts with whitespace; trim it before calling assigns()", .{rest});
    for (assignments) |op| if (std.mem.startsWith(u8, rest, op)) return true;
    if (assignments.len == 0) assert.panic("no assignment operators to compare '{s}' with; list them in assignments", .{rest});
    return rest.len > 0 and rest[0] == '=' and (rest.len == 1 or rest[1] != '=');
}

const assignments = [_][]const u8{ "+=", "-=", "*=", "/=", "%=", "|=", "&=", "^=", "<<=", ">>=", ":=", "++", "--" };

/// A chain of two member reads from a loop's element, as `row.customer.name` is, on every pass,
/// so each pass follows a pointer out of the element to another object. Longer chains are
/// message-chain's.
pub fn checkFieldChain(self: *File, node: ts.Node, links: u32, root: []const u8) !void {
    if (root.len == 0) assert.panic("{s}: the chain {f} starts from no name; checkChain() skips those", .{ self.work.facts.path, node.where() });
    if (!std.mem.startsWith(u8, node.text(self.source), root)) assert.panic("{s}: the chain {f} doesn't start with its root '{s}'; checkChain() passes the text of the chain's first object", .{ self.work.facts.path, node.where(), root });
    if (links + 1 != rules.min_chain_links or !self.checker.enabled.enabled("field-chain-in-loop")) return;
    if (check.contains(self.tables.self_receivers, root)) return;
    const function = self.enclosingFunction() orelse return;
    const loop = passLoop(self, node, function) orelse return;
    if (!boundByLoop(self, loop, root)) return;
    _ = try self.report(node, "field-chain-in-loop", try self.say("'{s}' reaches from each element of the loop on line {d} into another object, so every pass follows a pointer to memory that sits somewhere else.", .{ check.header(node.text(self.source)), ts.ts_node_start_point(loop.node).row + 1 }));
}

/// Whether `name` is what the loop binds on each pass: written in its header outside its
/// iterable, as `o` is in `for o in orders`, or bound on the header's line, as `|item|` is.
fn boundByLoop(self: *File, loop: *const Context, name: []const u8) bool {
    const start = ts.ts_node_start_byte(loop.node);
    const header_end = bodyStart(self, loop);
    if (name.len == 0) assert.panic("{s}: asked whether the loop {f} binds an empty name", .{ self.work.facts.path, loop.node.where() });
    if (header_end < start) assert.panic("{s}: the header of {f} ends at {d}, before the loop starts at {d}", .{ self.work.facts.path, loop.node.where(), header_end, start });
    const line_end = std.mem.indexOfScalarPos(u8, self.source, header_end, '\n') orelse self.source.len;
    const text = self.source[start..@min(line_end, ts.ts_node_end_byte(loop.node))];
    const iterable = loop.iterable orelse return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, name)) |at| : (from = at + 1) {
        const before = if (at > 0) text[at - 1] else ' ';
        const after = at + name.len;
        if (std.ascii.isAlphanumeric(before) or before == '_' or before == '.') continue;
        if (after < text.len and (std.ascii.isAlphanumeric(text[after]) or text[after] == '_')) continue;
        const where = start + at;
        const in_iterable = where >= ts.ts_node_start_byte(iterable) and where < ts.ts_node_end_byte(iterable);
        if (in_iterable and assigns(std.mem.trimStart(u8, text[after..], " \t"))) return true;
        if (in_iterable) continue;
        if (where < header_end or binds(text[0..at], text[after..])) return true;
    }
    return false;
}
