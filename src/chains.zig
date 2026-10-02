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
/// `xml.etree.ElementTree` or `std.mem`, is a module path.
pub fn checkChain(self: *File, node: ts.Node) !void {
    const link = self.v.chain_link orelse assert.panic("{s}: {f} was entered as a chain link, but the query has no @chain.link; checkChain() runs only for that capture", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(node) <= ts.ts_node_start_byte(node)) assert.panic("{s}: the member access {f} covers no text; put @chain.link on the whole access in the language's zanity.scm", .{ self.work.facts.path, node.where() });
    if (self.parentOf(node)) |parent| {
        if (self.index.marks(parent, link) and objectOf(parent).eql(node)) return;
    }
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
    _ = try self.report(node, "message-chain", try self.say("'{s}' reaches through {d} objects, so this code breaks when any of them changes shape.", .{ header(node.text(self.source)), links - 1 }));
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
