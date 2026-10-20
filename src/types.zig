//! Types evident in code, so a call can tell apart overloads that take as many parameters as it
//! passes arguments: the declared types of parameters and locals, and the types literals,
//! constructions and casts passed as arguments plainly have.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");
const hazards = @import("hazards.zig");
const facts = @import("facts.zig");
const File = check.File;
const Context = check.Context;

/// A parameter or local named `name` in function `owner`, with its declared type when the code
/// states one: `byte[] data` does, `var data = Load()` doesn't.
pub const Declared = struct { owner: u32, name: ts.Node, type: ?ts.Node = null };

/// The literal kinds a query captures as `@type.<kind>` on an argument, in the order of
/// `Tables.literal_types`' fields.
pub const literal_kinds = [_][]const u8{ "text", "letter", "whole", "fraction", "truth" };

/// The ids of the `@type.<kind>` captures for each of `literal_kinds` in `c`.
pub fn literalIds(c: captures.Compiled) [literal_kinds.len]?captures.Id {
    var ids: [literal_kinds.len]?captures.Id = undefined;
    inline for (literal_kinds, 0..) |kind, i| ids[i] = c.id("type." ++ kind);
    if (ids.len != literal_kinds.len) assert.panic("looked up {d} literal captures for {d} kinds; look up one per kind", .{ ids.len, literal_kinds.len });
    if (c.names.len == 0) assert.panic("looking up literal captures in a query with no captures; check the language's query files", .{});
    return ids;
}

const separator = facts.type_separator;
const agree = facts.typesAgree;

/// The longest list of types recorded for one call or function; longer lists record none.
const max_list = 512;

/// Records a `@type.declared` type or `@type.name` name. A type pairs with the name it declares
/// whichever comes first: `string text` declares its type before its name, and
/// `var text = new StringBuilder()` after it, inside the name's declarator.
pub fn capture(self: *File, part: []const u8, node: ts.Node) !void {
    if (part.len == 0) assert.panic("{s}: {f} is captured as @type with no part; write @type.declared, @type.name or a literal kind", .{ self.work.facts.path, node.where() });
    const function = self.innermost(.function) orelse return;
    const declared = &self.s.declared;
    if (std.mem.eql(u8, part, "declared")) {
        const last = if (declared.last()) |d| (if (d.owner == function.serial and d.type == null) d else null) else null;
        if (last) |d| if (d.name.parent()) |declarator| if (inside(node, declarator)) {
            d.type = node;
            return;
        };
        self.s.pending_type = node;
    } else if (std.mem.eql(u8, part, "name")) {
        const pending = self.s.pending_type;
        const typed = if (pending) |t| declares(t, node) else false;
        try declared.add(.{ .owner = function.serial, .name = node, .type = if (typed) pending else null });
    }
    if (declared.len > declared.capacity()) assert.panic("{s}: {d} declared names in room for {d}; raise memory.Limits.per_file", .{ self.work.facts.path, declared.len, declared.capacity() });
}

/// Whether the type `t` declares the name `name`: they share a declaration, as a parameter's type
/// and name do, or the type belongs to the declaration holding the name's declarator.
fn declares(t: ts.Node, name: ts.Node) bool {
    const owner = t.parent() orelse return false;
    const holder = name.parent() orelse return false;
    if (ts.ts_node_start_byte(t) >= ts.ts_node_start_byte(name)) assert.panic("pairing the type at {f} with the name at {f} before it; a pending type comes before the name", .{ t.where(), name.where() });
    if (inside(name, t)) assert.panic("the name at {f} lies inside the type at {f} said to declare it; capture the type and the name as separate nodes", .{ name.where(), t.where() });
    if (owner.eql(holder)) return true;
    const outer = holder.parent() orelse return false;
    return owner.eql(outer);
}

/// Whether `node` lies within `outer`'s bytes.
fn inside(node: ts.Node, outer: ts.Node) bool {
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    if (end < start) assert.panic("{f} ends at byte {d}, before it starts at {d}; tree-sitter returned a broken node", .{ node.where(), end, start });
    if (ts.ts_node_end_byte(outer) < ts.ts_node_start_byte(outer)) assert.panic("{f} ends before it starts; tree-sitter returned a broken node", .{outer.where()});
    return start >= ts.ts_node_start_byte(outer) and end <= ts.ts_node_end_byte(outer);
}

/// The types of `ctx`'s parameters, in order, when every one of them declares its type.
pub fn ofParameters(self: *File, ctx: Context) ![]const u8 {
    if (ctx.family != .function) assert.panic("{s}: listing parameter types of {f}, a {t}; call ofParameters() only for functions", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    var list: List = .{};
    var count: u32 = 0;
    for (ownedBy(self, ctx.node)) |d| {
        if (d.owner != ctx.serial or ts.ts_node_start_byte(d.name) >= ctx.body_start) continue;
        const t = d.type orelse return "";
        list.write(t.text(self.source), count);
        count += 1;
    }
    if (count != ctx.formal_parameters or list.overflowed) return "";
    if (std.mem.count(u8, list.text(), &.{separator}) + 1 != @max(count, 1)) assert.panic("{s}: {d} parameter types listed as '{s}'; write() separates each from the next", .{ self.work.facts.path, count, list.text() });
    return try self.work.text.copy(list.text());
}

/// The types `ctx`'s arguments plainly have, in order, empty where they don't show one; empty
/// when none do.
pub fn ofArguments(self: *File, ctx: *const Context) ![]const u8 {
    if (ctx.family != .call) assert.panic("{s}: listing argument types of {f}, a {t}; call ofArguments() only for calls", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (ctx.argument_count > ctx.arguments.len) return "";
    var list: List = .{};
    var known = false;
    for (ctx.arguments[0..ctx.argument_count], 0..) |slot, i| {
        const argument = slot orelse return "";
        const found = argumentType(self, argument);
        known = known or found.len > 0;
        list.write(found, @intCast(i));
    }
    if (!known or list.overflowed) return "";
    if (std.mem.count(u8, list.text(), &.{separator}) + 1 != ctx.argument_count) assert.panic("{s}: {d} argument types listed as '{s}'; write() separates each from the next", .{ self.work.facts.path, ctx.argument_count, list.text() });
    return try self.work.text.copy(list.text());
}

/// The type `argument` plainly has: a literal's, a construction's or cast's named type, or the
/// declared type of the parameter or local it names; empty when it shows none.
fn argumentType(self: *File, argument: ts.Node) []const u8 {
    const name = argument.text(self.source);
    if (name.len == 0) assert.panic("{s}: the argument at {f} has no text; @call.argument must capture an expression", .{ self.work.facts.path, argument.where() });
    inline for (literal_kinds, 0..) |kind, i| {
        if (self.index.marks(argument, self.v.type_literals[i])) return @field(self.tables.literal_types, kind);
    }
    if (self.v.type_of) |of| {
        const start = ts.ts_node_start_byte(argument);
        const end = ts.ts_node_end_byte(argument);
        const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, hazards.startsBefore);
        for (self.index.triples[first..]) |t| {
            if (t.key.start >= end) break;
            if (t.id != of) continue;
            const parent = t.node.parent() orelse continue;
            if (parent.eql(argument)) return t.node.text(self.source);
        }
    }
    const function = self.innermost(.function) orelse return "";
    if (!inside(argument, function.node)) assert.panic("{s}: the argument at {f} lies outside its function {f}; innermost() returns an enclosing function", .{ self.work.facts.path, argument.where(), function.node.where() });
    const declared = ownedBy(self, function.node);
    var i = declared.len;
    while (i > 0) {
        i -= 1;
        const d = declared[i];
        if (d.owner != function.serial or !std.mem.eql(u8, d.name.text(self.source), name)) continue;
        return if (d.type) |t| t.text(self.source) else "";
    }
    return "";
}

/// The names declared inside `function`, the last run of the file's list: names are recorded in
/// the order the walk reaches them, so those of earlier functions come first.
fn ownedBy(self: *File, function: ts.Node) []const Declared {
    const declared = self.s.declared.items();
    const start = ts.ts_node_start_byte(function);
    var first = declared.len;
    while (first > 0 and ts.ts_node_start_byte(declared[first - 1].name) >= start) first -= 1;
    if (first > declared.len) assert.panic("names inside {f} start at {d} of {d}; the scan only moves back", .{ function.where(), first, declared.len });
    if (first > 0 and ts.ts_node_start_byte(declared[first - 1].name) >= start) assert.panic("the name at {f}, inside {f}, was left out of its names; the scan stops at the first name before it", .{ declared[first - 1].name.where(), function.where() });
    return declared[first..];
}

/// A list of types joined by `separator`, each written in a form two spellings of one type share.
const List = struct {
    buffer: [max_list]u8 = undefined,
    len: usize = 0,
    overflowed: bool = false,

    /// Adds the `index`th type, after a separator unless it is the first.
    fn write(self: *List, type_text: []const u8, index: u32) void {
        if (index == 0 and self.len > 0) assert.panic("writing '{s}' as the first type of a list already holding {d} bytes; number the types from 0", .{ type_text, self.len });
        if (index > 0) self.place(separator);
        const start = self.len;
        normalise(self, type_text);
        if (self.len < start) assert.panic("normalising '{s}' shrank the list from {d} to {d} bytes; normalise() only adds", .{ type_text, start, self.len });
    }

    fn place(self: *List, c: u8) void {
        if (self.len > self.buffer.len) assert.panic("a list of types holds {d} bytes in room for {d}; place() stops at the end", .{ self.len, self.buffer.len });
        if (self.len == self.buffer.len) {
            self.overflowed = true;
            return;
        }
        self.buffer[self.len] = c;
        self.len += 1;
        if (self.buffer[self.len - 1] != c) assert.panic("placed '{c}' into a list of types but it holds '{c}'; write the byte at the end", .{ c, self.buffer[self.len - 1] });
    }

    fn text(self: *const List) []const u8 {
        if (self.overflowed) assert.panic("reading a list of types that overflowed its {d} bytes; check overflowed first", .{self.buffer.len});
        if (self.len > self.buffer.len) assert.panic("a list of types holds {d} bytes in room for {d}; place() stops at the end", .{ self.len, self.buffer.len });
        return self.buffer[0..self.len];
    }
};

/// Adds `type_text` to `list` without spaces, namespace or package qualifiers, array sizes or a
/// trailing nullable marker, so `System.String?` and `String`, or `byte[16]` and `byte[]`, agree.
fn normalise(list: *List, type_text: []const u8) void {
    const start = list.len;
    if (start > list.buffer.len) assert.panic("normalising '{s}' into a list of {d} bytes in room for {d}; place() stops at the end", .{ type_text, start, list.buffer.len });
    var nesting: Nesting = .{};
    for (type_text) |c| {
        if (std.ascii.isWhitespace(c) or c == separator) continue;
        nesting.track(c);
        if (nesting.square > 0 and c != '[' and c != ',') continue;
        if (c == '.' and nesting.angle == 0 and nesting.square == 0) {
            list.len = start;
            continue;
        }
        list.place(c);
    }
    if (list.len > start and list.buffer[list.len - 1] == '?') list.len -= 1;
    if (list.len < start) assert.panic("normalising '{s}' dropped bytes written before it; a qualifier resets only to where this type starts", .{type_text});
}

/// How deep a type's text is inside generic arguments and array brackets.
const Nesting = struct {
    angle: u32 = 0,
    square: u32 = 0,

    fn track(self: *Nesting, c: u8) void {
        const depth = self.angle + self.square;
        switch (c) {
            '<' => self.angle += 1,
            '>' => self.angle -|= 1,
            '[' => self.square += 1,
            ']' => self.square -|= 1,
            else => {},
        }
        if (self.angle + self.square > depth + 1) assert.panic("'{c}' deepened a type's nesting from {d} to {d}; one byte opens at most one level", .{ c, depth, self.angle + self.square });
        if (self.angle + self.square + 1 < depth) assert.panic("'{c}' closed a type's nesting from {d} to {d}; one byte closes at most one level", .{ c, depth, self.angle + self.square });
    }
};

test "spellings of one type agree, and an argument whose type doesn't show agrees with any parameter" {
    var list: List = .{};
    list.write("System.String?", 0);
    list.write("byte[16]", 1);
    list.write("Dictionary<string, int>", 2);
    try std.testing.expectEqualStrings("String;byte[];Dictionary<string,int>", list.text());
    try std.testing.expectEqual(true, agree("String;;int", "String;byte[];int"));
    try std.testing.expectEqual(false, agree("String;;int", "String;byte[];long"));
    try std.testing.expectEqual(false, agree("String", "String;int"));
    try std.testing.expectEqual(false, agree("", "String"));
}
