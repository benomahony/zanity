//! Message chains: code that reaches through one object to another and another, as in
//! `order.customer.address.city`, so it depends on the shape of every object along the way.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const rules = @import("rules.zig");
const File = check.File;
const contains = check.contains;
const header = check.header;

/// Reports the outermost link of a chain of member accesses at least `rules.min_chain_links` long
/// that starts from one of the enclosing function's own locals or parameters, or from a field of
/// `self` or `this`, which an object may use as its own. A chain from anything else, such as
/// `xml.etree.ElementTree` or `std.mem`, is a module path. Tests are left out: configuring a mock
/// or checking a result reaches into objects by design.
pub fn checkChain(self: *File, node: ts.Node) !void {
    const link = self.v.chain_link orelse assert.panic("{s}: {f} was entered as a chain link, but the query has no @chain.link; checkChain() runs only for that capture", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(node) <= ts.ts_node_start_byte(node)) assert.panic("{s}: the member access {f} covers no text; put @chain.link on the whole access in the language's zanity.scm", .{ self.work.facts.path, node.where() });
    if (self.parentOf(node)) |parent| {
        if (self.index.marks(parent, link) and objectOf(parent).eql(node)) return;
    }
    if (self.inTest() or self.inTestFile()) return;
    var links: u32 = 1;
    var root = objectOf(node);
    for (0..64) |_| {
        if (!self.index.marks(root, link)) break;
        links += 1;
        root = objectOf(root);
    }
    const start = root.text(self.source);
    if (start.len == 0) return;
    // An object's own fields are its to use, so a chain from `self` starts at `self.field`.
    const own = contains(self.tables.self_receivers, start);
    if (own) links -|= 1;
    if (links < rules.min_chain_links) return;
    if (!own and !ownName(self, start)) return;
    if (links > 64) assert.panic("{s}: counted {d} links in the chain at {f}, past the 64 the loop allows; checkChain() must stop counting at its loop bound", .{ self.work.facts.path, links, node.where() });
    try reportChain(self, node, links, if (own) ownField(header(node.text(self.source)), start) else start);
}

/// Reports the chain at `node`, of `links` links from `first`, with what to ask `first` for.
fn reportChain(self: *File, node: ts.Node, links: u32, first: []const u8) !void {
    if (links < rules.min_chain_links) assert.panic("{s}: reporting a chain of {d} links, under the {d} reported; checkChain() returns before short ones", .{ self.work.facts.path, links, rules.min_chain_links });
    const chain = header(node.text(self.source));
    if (!try self.report(node, "message-chain", try self.say("'{s}' reaches through {d} objects, so this code breaks when any of them changes shape.", .{ chain, links - 1 }))) return;
    self.s.diagnostics.last().?.fix = try askInstead(self, if (calledAt(self, node)) callTarget(chain) else chain, first);
    if (self.s.diagnostics.last().?.fix.len == 0) assert.panic("{s}: the message-chain fix for '{s}' came out empty; say() always writes text", .{ self.work.facts.path, chain });
}

/// The field of `self` or `this` a chain starts from, such as `self.provider` in
/// `self.provider.client.base_url`.
fn ownField(chain: []const u8, receiver: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, chain, receiver)) assert.panic("the chain '{s}' doesn't start with its receiver '{s}'; checkChain() takes the receiver from the chain's root", .{ chain, receiver });
    const rest = chain[receiver.len..];
    if (rest.len < 2) return chain;
    const end = std.mem.indexOfAnyPos(u8, rest, 1, ".([") orelse rest.len;
    if (receiver.len + end > chain.len) assert.panic("the field of '{s}' ran past it, to {d}", .{ chain, receiver.len + end });
    return chain[0 .. receiver.len + end];
}

/// What to do about a chain: ask the object it starts from for the last thing it reaches, or pass
/// that thing in, so the code no longer knows the objects in between.
fn askInstead(self: *File, chain: []const u8, first: []const u8) ![]const u8 {
    if (first.len == 0 or first.len > chain.len) assert.panic("{s}: the chain '{s}' starts from '{s}'; checkChain() passes a prefix of the chain", .{ self.work.facts.path, chain, first });
    if (!std.mem.startsWith(u8, chain, first)) assert.panic("{s}: the chain '{s}' doesn't start with '{s}'; pass the chain's own start", .{ self.work.facts.path, chain, first });
    const last_dot = std.mem.lastIndexOfScalar(u8, chain, '.') orelse return self.say("Ask '{s}' for what you need with a method of its own, or pass that value in.", .{first});
    const wanted = memberName(chain[last_dot + 1 ..]);
    const between = std.mem.trim(u8, chain[first.len..last_dot], ".");
    if (between.len == 0 or wanted.len == 0) return self.say("Ask '{s}' for what you need with a method of its own, or pass that value in.", .{first});
    return self.say("Ask '{s}' for '{s}' with a method of its own, or pass '{s}' in, so this code stops depending on '{s}'.", .{ first, wanted, wanted, between });
}

/// Whether the chain at `node` is called, as `a.b.c()` is: an opening parenthesis right after it.
fn calledAt(self: *File, node: ts.Node) bool {
    const end = ts.ts_node_end_byte(node);
    if (end > self.source.len) assert.panic("{s}: the chain {f} ends past the {d}-byte file; pass a node from this file's tree", .{ self.work.facts.path, node.where(), self.source.len });
    if (end <= ts.ts_node_start_byte(node)) assert.panic("{s}: the chain {f} covers no text; put @chain.link on the whole access in the language's zanity.scm", .{ self.work.facts.path, node.where() });
    return end < self.source.len and self.source[end] == '(';
}

/// A called chain without the method it calls, which only works on the value the chain reached:
/// `event.assignee.login` for `event.assignee.login.casefold()`.
fn callTarget(chain: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, chain, '.') orelse return chain;
    if (dot == 0) assert.panic("the chain '{s}' starts with a dot; a chain starts from a name", .{chain});
    const target = chain[0..dot];
    if (target.len >= chain.len) assert.panic("dropping the method from '{s}' kept all of it", .{chain});
    return target;
}

/// The name of a member access's last link, without a call's arguments: `edit` in `edit(x)`.
fn memberName(link: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, link, '.') != null) assert.panic("'{s}' is more than one link; pass what follows the last dot", .{link});
    const end = std.mem.indexOfAny(u8, link, "([ ") orelse link.len;
    const name = link[0..end];
    if (name.len > link.len) assert.panic("the name of '{s}' came out longer than it; slicing only shortens", .{link});
    return name;
}

/// The object a member access reads from: its first named child in every grammar.
fn objectOf(access: ts.Node) ts.Node {
    if (ts.ts_node_named_child_count(access) == 0) assert.panic("the member access {f} has no named children, so the query marked a leaf as @chain.link; capture the whole access in the language's zanity.scm", .{access.where()});
    const object = ts.ts_node_named_child(access, 0);
    if (ts.ts_node_end_byte(object) > ts.ts_node_end_byte(access)) assert.panic("the first child {f} of the member access {f} ends after it; tree-sitter returned a child from another tree", .{ object.where(), access.where() });
    if (ts.ts_node_start_byte(object) != ts.ts_node_start_byte(access)) return access;
    return object;
}

/// Whether `name` is a local or a parameter of a function the walk is inside.
fn ownName(self: *File, name: []const u8) bool {
    if (name.len == 0) assert.panic("{s}: asked whether an empty name is the function's own; checkChain() must skip a chain whose start has no text", .{self.work.facts.path});
    const contexts = self.s.contexts.items();
    for (contexts) |ctx| {
        if (ctx.family != .function) continue;
        for (self.s.locals.items()) |local| if (local.owner == ctx.serial and std.mem.eql(u8, local.text, name)) return true;
        const signature = self.s.signature.items();
        if (ctx.parameter_start > signature.len) assert.panic("{s}: a function's parameters start at {d}, past the {d} recorded; open() must take parameter_start from the signature's length", .{ self.work.facts.path, ctx.parameter_start, signature.len });
        for (signature[ctx.parameter_start..]) |parameter| if (std.mem.eql(u8, parameter.name.text(self.source), name)) return true;
    }
    return false;
}
