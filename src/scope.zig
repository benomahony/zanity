//! NASA rule 6: a local declared in a wider block than the one it is used in.
const std = @import("std");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");
const hazards = @import("hazards.zig");
const File = check.File;
const Edit = @import("facts.zig").Edit;

/// Names declared by one statement, such as `x, err := f()`, which can only move together.
const max_group = 8;

const Ids = struct {
    outer: captures.Id,
    name: captures.Id,
    block: captures.Id,
    scope: captures.Id,
    reference: captures.Id,
    exit: ?captures.Id,
    /// Something in an initializer besides computing a value, such as a call, so --fix won't move it.
    effect: ?captures.Id,
    string: ?captures.Id,
    /// Code that runs once per iteration, or later, so a local moved into it is made at a different time.
    barriers: [3]?captures.Id,

    fn fromQuery(c: captures.Compiled) ?Ids {
        if (c.names.len == 0) std.debug.panic("looking up the wide-scope captures in a query with no captures; compile the language's query before building its checker", .{});
        const ids: Ids = .{
            .outer = c.id("declaration.outer") orelse return null,
            .name = c.id("declaration.name") orelse return null,
            .block = c.id("declaration.block") orelse return null,
            .scope = c.id("local.scope") orelse return null,
            .reference = c.id("local.reference") orelse return null,
            .exit = c.id("declaration.exit"),
            .effect = c.id("declaration.effect"),
            .string = c.id("literal.string"),
            .barriers = .{ c.id("loop.outer"), c.id("function.outer"), c.id("declaration.barrier") },
        };
        if (ids.outer == ids.name or ids.name == ids.block) std.debug.panic("expected distinct wide-scope captures, got @declaration.outer {d}, .name {d}, .block {d}; give each its own capture name in the language's zanity.scm", .{ ids.outer, ids.name, ids.block });
        return ids;
    }
};

const Group = struct {
    statement: ts.Node,
    names: [max_group]ts.Node = undefined,
    len: usize = 0,

    fn declared(self: *const Group) []const ts.Node {
        if (self.len > max_group) std.debug.panic("a declaration group holds {d} names in room for {d}; gather() must stop adding at max_group", .{ self.len, max_group });
        if (self.len == 0) std.debug.panic("the declaration {f} declares no names; gather() must return null for a statement without names", .{self.statement.where()});
        return self.names[0..self.len];
    }

    /// Where the uses can start: the end of the declaration statement.
    fn after(self: *const Group) u32 {
        const end = ts.ts_node_end_byte(self.statement);
        if (end < ts.ts_node_end_byte(self.names[self.len - 1])) std.debug.panic("the declaration {f} ends before the last name it declares, so the query matched only part of the statement; in that language's zanity.scm, put @declaration.outer on the whole declaration statement", .{self.statement.where()});
        if (end <= ts.ts_node_start_byte(self.statement)) std.debug.panic("the declaration {f} covers no text, so the query matched an empty node; in that language's zanity.scm, put @declaration.outer on the declaration statement itself", .{self.statement.where()});
        return end;
    }
};

/// Where the uses of a group lie: the first one, and the end of the last.
const Uses = struct { first: ?ts.Node = null, end: u32 = 0 };

/// Reports each local whose uses all sit inside one nested block that runs when the declaration
/// would, so the declaration can move into that block.
pub fn checkWideScope(self: *File) !void {
    if (!self.checker.enabled.enabled("wide-scope")) return;
    const ids = Ids.fromQuery(self.checker.compiled) orelse std.debug.panic("{s}: wide-scope is enabled but the query lacks its captures; the language test should have caught this", .{self.work.facts.path});
    if (ids.outer >= self.checker.compiled.names.len) std.debug.panic("{s}: @declaration.outer has id {d}, but the query has {d} captures; pass the checker's own compiled query", .{ self.work.facts.path, ids.outer, self.checker.compiled.names.len });
    var checked: usize = 0;
    for (self.index.triples) |t| {
        if (t.id != ids.outer) continue;
        checked += 1;
        const group = gather(self, ids, t.node) orelse continue;
        try checkGroup(self, ids, &group);
    }
    if (checked > self.index.triples.len) std.debug.panic("{s}: checked {d} declarations among {d} captures; count one declaration per captured statement", .{ self.work.facts.path, checked, self.index.triples.len });
}

/// The names `statement` declares itself, not those declared inside its initializer; null when
/// there are none, too many, or the initializer can leave the block.
fn gather(self: *File, ids: Ids, statement: ts.Node) ?Group {
    const end = ts.ts_node_end_byte(statement);
    if (end <= ts.ts_node_start_byte(statement)) std.debug.panic("{s}: @declaration.outer matched the empty {f}; capture the declaration statement", .{ self.work.facts.path, statement.where() });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, ts.ts_node_start_byte(statement), hazards.startsBefore);
    var group: Group = .{ .statement = statement };
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id == ids.exit) return null;
        if (t.id != ids.name) continue;
        const owner = enclosing(self, t.node, ids.outer) orelse continue;
        if (!owner.eql(statement)) continue;
        if (group.len == max_group) return null;
        group.names[group.len] = t.node;
        group.len += 1;
    }
    if (group.len > max_group) std.debug.panic("{s}: gathered {d} names in room for {d}; gather() must stop adding at max_group", .{ self.work.facts.path, group.len, max_group });
    if (group.len == 0) return null;
    return group;
}

fn checkGroup(self: *File, ids: Ids, group: *const Group) !void {
    const declared = group.declared()[0];
    const home = enclosing(self, group.statement, ids.block) orelse return;
    const uses = findUses(self, ids, group, home);
    const target = innermostBlock(self, ids, uses, home) orelse return;
    if (crossesBarrier(self, ids, target, home)) return;
    if (ts.ts_node_start_byte(target) < group.after()) std.debug.panic("{s}: the block {f} that '{s}' would move into starts before the declaration ends; findUses() must start after the declaration ends", .{ self.work.facts.path, target.where(), declared.text(self.source) });
    const line = ts.ts_node_start_point(target).row + 1;
    if (!try self.report(declared, "wide-scope", try wideScopeMessage(self, group, line))) return;
    const diagnostic = self.s.diagnostics.last().?;
    diagnostic.edit = try moveEdit(self, ids, group, target);
    diagnostic.fix = if (diagnostic.edit == null)
        try self.say("Move this declaration to the top of the block on line {d}, unless its initializer has to run before the code in between.", .{line})
    else
        try self.say("Move this declaration to the top of the block on line {d}.", .{line});
    if (diagnostic.fix.len == 0) std.debug.panic("{s}: the wide-scope fix for '{s}' came out empty; checkGroup() must write the fix with say()", .{ self.work.facts.path, declared.text(self.source) });
}

/// The edit that moves the declaration to the top of `target`: it takes the declaration's line
/// out and writes it after the line that opens `target`, at the indentation of the line after.
/// Null when moving it could change what it computes, or the layout isn't one line per statement.
fn moveEdit(self: *File, ids: Ids, group: *const Group, target: ts.Node) !?Edit {
    const line = lineAlone(self, group.statement) orelse return null;
    if (!pureInitializer(self, ids, group, target)) return null;
    const open = ts.ts_node_start_byte(target);
    if (self.source[open] != '{') return null;
    const open_end = std.mem.indexOfScalarPos(u8, self.source, open, '\n') orelse return null;
    if (std.mem.trim(u8, self.source[open + 1 .. open_end], " \t\r").len != 0) return null;
    const insert: u32 = @intCast(open_end + 1);
    const next_end = std.mem.indexOfScalarPos(u8, self.source, insert, '\n') orelse return null;
    const next = self.source[insert..next_end];
    const code = std.mem.trimStart(u8, next, " \t");
    if (code.len == 0 or code[0] == '}') return null;
    if (insert <= line.end) std.debug.panic("{s}: the block {f} opens before the declaration {f} ends; innermostBlock() must return a block that starts after the declaration", .{ self.work.facts.path, target.where(), group.statement.where() });
    const replacement = try self.work.text.format("{s}{s}{s}\n", .{ self.source[line.end + 1 .. insert], next[0 .. next.len - code.len], group.statement.text(self.source) });
    if (!std.mem.endsWith(u8, replacement, "\n")) std.debug.panic("{s}: the moved declaration '{s}' does not end its line; moveEdit() must end the replacement with a newline", .{ self.work.facts.path, replacement });
    return .{ .start = line.start, .end = insert, .replacement = replacement };
}

const Line = struct { start: u32, end: u32 };

/// The line `node` is on, when it is on one line with nothing else on it but whitespace.
fn lineAlone(self: *File, node: ts.Node) ?Line {
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    if (end <= start) std.debug.panic("{s}: the declaration {f} covers no text, so the query matched an empty node; in that language's zanity.scm, put @declaration.outer on the declaration statement itself", .{ self.work.facts.path, node.where() });
    if (std.mem.indexOfScalar(u8, self.source[start..end], '\n') != null) return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, self.source[0..start], '\n')) |newline| newline + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, self.source, end, '\n') orelse return null;
    if (std.mem.trim(u8, self.source[line_start..start], " \t").len != 0) return null;
    if (std.mem.trim(u8, self.source[end..line_end], " \t\r").len != 0) return null;
    if (line_end < end) std.debug.panic("{s}: the line of {f} ends at byte {d}, before the declaration does; lineAlone() must search for the newline from the declaration's end", .{ self.work.facts.path, node.where(), line_end });
    return .{ .start = @intCast(line_start), .end = @intCast(line_end) };
}

/// Whether the initializer only computes a value from names that nothing between the declaration
/// and `target` mentions, so computing it later gives the same value.
fn pureInitializer(self: *File, ids: Ids, group: *const Group, target: ts.Node) bool {
    const statement = group.statement;
    const end = ts.ts_node_end_byte(statement);
    const between = self.source[group.after()..ts.ts_node_start_byte(target)];
    if (between.len > self.source.len) std.debug.panic("{s}: {d} bytes lie between {f} and {f}, more than the file holds; the target block must start after the declaration ends, as checkGroup() asserts", .{ self.work.facts.path, between.len, statement.where(), target.where() });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, ts.ts_node_start_byte(statement), hazards.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id == ids.effect) return false;
        if (t.id != ids.reference or isDefinition(self, t.node)) continue;
        if (containsWord(between, t.node.text(self.source))) return false;
    }
    if (first > self.index.triples.len) std.debug.panic("{s}: the captures of {f} start at {d}, past the {d} recorded; take the start from lowerBound over the recorded captures", .{ self.work.facts.path, statement.where(), first, self.index.triples.len });
    return true;
}

fn wideScopeMessage(self: *File, group: *const Group, line: u32) ![]const u8 {
    if (line == 0) std.debug.panic("{s}: the block to move into is on line 0; lines count from 1", .{self.work.facts.path});
    const text = self.work.text;
    const start = text.used;
    for (group.declared(), 0..) |name, i| {
        const separator = if (i == 0) "" else if (i + 1 == group.len) " and " else ", ";
        _ = try text.format("{s}'{s}'", .{ separator, name.text(self.source) });
    }
    const verb = if (group.len == 1) "is" else "are";
    _ = try text.format(" {s} only used inside the block on line {d}, yet in scope before it, where a reader has to track it and code can misuse it.", .{ verb, line });
    const message = text.buffer[start..text.used];
    if (message[0] != '\'') std.debug.panic("{s}: the wide-scope message does not start with a quoted name: '{s}'; wideScopeMessage() must start with the first name in quotes", .{ self.work.facts.path, message });
    return message;
}

/// The uses of the group's names after the declaration and before `home` ends. A reference that
/// an inner definition of the same name shadows is not a use; a string that mentions a name is.
fn findUses(self: *File, ids: Ids, group: *const Group, home: ts.Node) Uses {
    const end = ts.ts_node_end_byte(home);
    if (group.after() > end) std.debug.panic("{s}: the declaration {f} ends after its block {f}; pass the block that encloses the declaration, from enclosing()", .{ self.work.facts.path, group.statement.where(), home.where() });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, group.after(), hazards.startsBefore);
    var uses: Uses = .{};
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        const used = if (t.id == ids.reference)
            referencesGroup(self, ids, group, t.node)
        else if (t.id == ids.string)
            mentionsGroup(self, group, t.node)
        else
            false;
        if (!used) continue;
        if (uses.first == null) uses.first = t.node;
        uses.end = @max(uses.end, ts.ts_node_end_byte(t.node));
    }
    if (uses.end > end) std.debug.panic("{s}: a use ends at byte {d}, after its block {f}; findUses() must stop at the block's end, so check its loop", .{ self.work.facts.path, uses.end, home.where() });
    return uses;
}

/// Whether `reference` uses one of the group's names: it spells one, it defines nothing itself
/// (a parameter or an inner declaration of the same name), and no inner definition shadows it.
fn referencesGroup(self: *File, ids: Ids, group: *const Group, reference: ts.Node) bool {
    const text = reference.text(self.source);
    if (text.len == 0) std.debug.panic("{s}: @local.reference matched the empty {f}; capture a named node as @local.reference in the language's locals.scm", .{ self.work.facts.path, reference.where() });
    if (isDefinition(self, reference)) return false;
    for (group.declared()) |name| {
        if (!std.mem.eql(u8, name.text(self.source), text)) continue;
        return !shadowed(self, ids, group.after(), reference);
    }
    if (ts.ts_node_start_byte(reference) < group.after()) std.debug.panic("{s}: the reference {f} precedes the declaration it was checked against; findUses() must start after the declaration", .{ self.work.facts.path, reference.where() });
    return false;
}

fn mentionsGroup(self: *File, group: *const Group, string: ts.Node) bool {
    const text = string.text(self.source);
    if (ts.ts_node_start_byte(string) < group.after()) std.debug.panic("{s}: the string {f} precedes the declaration it was checked against; findUses() must start after the declaration", .{ self.work.facts.path, string.where() });
    for (group.declared()) |name| {
        if (containsWord(text, name.text(self.source))) return true;
    }
    if (text.len == 0) std.debug.panic("{s}: @literal.string matched the empty {f}; capture a named node as @literal.string in the language's zanity.scm", .{ self.work.facts.path, string.where() });
    return false;
}

fn isDefinition(self: *File, node: ts.Node) bool {
    const names = self.checker.compiled.names;
    const found = self.index.of(node);
    if (found.len == 0) std.debug.panic("{s}: {f} was captured but carries no captures; call isDefinition() only with a node from a recorded capture", .{ self.work.facts.path, node.where() });
    for (found) |t| {
        if (std.mem.eql(u8, names[t.id].family, "local.definition")) return true;
    }
    if (found.len > self.index.triples.len) std.debug.panic("{s}: {d} captures on {f}, more than the {d} in the file; of() must slice within the recorded captures", .{ self.work.facts.path, found.len, node.where(), self.index.triples.len });
    return false;
}

/// Whether a definition of the same name, made after `after`, holds `reference` in its scope.
fn shadowed(self: *File, ids: Ids, after: u32, reference: ts.Node) bool {
    const text = reference.text(self.source);
    const at = ts.ts_node_start_byte(reference);
    if (at < after) std.debug.panic("{s}: the reference {f} comes before the declaration it might use ends at byte {d}; findUses() must start after the declaration", .{ self.work.facts.path, reference.where(), after });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, after, hazards.startsBefore);
    const names = self.checker.compiled.names;
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= at) break;
        if (!std.mem.eql(u8, names[t.id].family, "local.definition")) continue;
        if (!std.mem.eql(u8, t.node.text(self.source), text)) continue;
        const scope = enclosing(self, t.node, ids.scope) orelse continue;
        if (ts.ts_node_end_byte(scope) >= ts.ts_node_end_byte(reference)) return true;
    }
    if (first > self.index.triples.len) std.debug.panic("{s}: the captures after byte {d} start at {d}, past the {d} recorded; take the start from lowerBound over the recorded captures", .{ self.work.facts.path, after, first, self.index.triples.len });
    return false;
}

/// The innermost block strictly inside `home` that holds every use.
fn innermostBlock(self: *File, ids: Ids, uses: Uses, home: ts.Node) ?ts.Node {
    const first = uses.first orelse return null;
    const start = ts.ts_node_start_byte(first);
    if (uses.end > ts.ts_node_end_byte(home)) std.debug.panic("{s}: the uses end at byte {d}, after their declaration's block {f}; findUses() must stop at the block's end", .{ self.work.facts.path, uses.end, home.where() });
    if (uses.end < start) std.debug.panic("{s}: the uses end at byte {d}, before the first one {f}; findUses() must track the furthest end of any use", .{ self.work.facts.path, uses.end, first.where() });
    var current = first.parent();
    while (current) |node| : (current = node.parent()) {
        if (node.eql(home)) return null;
        if (!self.index.marks(node, ids.block)) continue;
        if (ts.ts_node_start_byte(node) <= start and ts.ts_node_end_byte(node) >= uses.end) return node;
    }
    std.debug.panic("{s}: walked up from the use {f} without reaching its declaration's block {f}; findUses() must collect only uses inside the block", .{ self.work.facts.path, first.where(), home.where() });
}

/// Whether a loop, function or closure sits between `target` and `home`, so a declaration moved
/// into `target` would run on every iteration, or at a later time.
fn crossesBarrier(self: *File, ids: Ids, target: ts.Node, home: ts.Node) bool {
    if (target.eql(home)) std.debug.panic("{s}: the block {f} to move into is the one the declaration is already in; innermostBlock() must return a block inside the declaration's own", .{ self.work.facts.path, home.where() });
    if (ts.ts_node_end_byte(target) > ts.ts_node_end_byte(home)) std.debug.panic("{s}: the block {f} ends after {f}, which should hold it; innermostBlock() must return a block inside the declaration's own", .{ self.work.facts.path, target.where(), home.where() });
    var current: ?ts.Node = target;
    while (current) |node| : (current = node.parent()) {
        if (node.eql(home)) return false;
        for (ids.barriers) |id| if (self.index.marks(node, id)) return true;
    }
    std.debug.panic("{s}: walked up from the block {f} without reaching {f}; innermostBlock() must return a block inside the declaration's own", .{ self.work.facts.path, target.where(), home.where() });
}

/// The nearest ancestor of `node` that carries capture `id`.
fn enclosing(self: *File, node: ts.Node, id: captures.Id) ?ts.Node {
    if (id >= self.checker.compiled.names.len) std.debug.panic("{s}: capture id {d} is out of range; the query has {d} captures; pass an id from Ids.fromQuery() on this language's query", .{ self.work.facts.path, id, self.checker.compiled.names.len });
    if (node.id == null) std.debug.panic("{s}: looked for an enclosing capture of a null node; check ts_node_is_null before calling enclosing()", .{self.work.facts.path});
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        if (self.index.marks(ancestor, id)) return ancestor;
    }
    return null;
}

/// Whether `word` appears in `text` with no identifier character on either side.
pub fn containsWord(text: []const u8, word: []const u8) bool {
    if (word.len == 0) std.debug.panic("looked for an empty name in '{s}'; skip empty names before calling containsWord()", .{text});
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |at| {
        const end = at + word.len;
        const before = at > 0 and identifier_bytes.isSet(text[at - 1]);
        const after = end < text.len and identifier_bytes.isSet(text[end]);
        if (!before and !after) return true;
        from = at + 1;
    }
    if (from > text.len) std.debug.panic("searching '{s}' for '{s}' ran past its end at {d}; the loop in containsWord() must stop at the end of the text", .{ text, word, from });
    return false;
}

const identifier_bytes = blk: {
    var set: std.StaticBitSet(256) = .empty;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') set.set(c);
    }
    break :blk set;
};

test "a name counts as mentioned only as a whole word" {
    try std.testing.expect(containsWord("{x}", "x"));
    try std.testing.expect(containsWord("total: {total}", "total"));
    try std.testing.expect(!containsWord("subtotal", "total"));
    try std.testing.expect(!containsWord("total_count", "total"));
}
