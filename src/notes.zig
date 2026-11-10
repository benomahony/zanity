//! Captures that note something about the code for a check that runs later: member accesses for
//! message-chain, expressions and writes for duplicated-expression, and names for the cross-file
//! checks of dead symbols and abstractions.
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");
const chains = @import("chains.zig");
const repeats = @import("repeats.zig");
const facts_module = @import("facts.zig");
const types = @import("types.zig");
const File = check.File;

/// Handles `id` when it is one of the noting captures; returns whether it was.
pub fn note(self: *File, node: ts.Node, id: captures.Id) !bool {
    const v = self.v;
    const enabled = self.checker.enabled;
    const facts = self.work.facts;
    const text = node.text(self.source);
    if (text.len == 0) assert.panic("{s}: capture {d} matched the empty {f}; capture a node with text", .{ facts.path, id, node.where() });
    if (v.chain_link == id) {
        try chains.checkChain(self, node);
    } else if (v.expression_repeatable == id) {
        try repeats.noteRepeatable(self, node);
    } else if (v.write_target == id) {
        try repeats.noteWrite(self, node, text);
    } else if (v.reference_name == id) {
        if (enabled.enabled("dead-symbol") and !self.index.marks(node, self.checker.compiled.id("reference.field"))) {
            const hash = facts_module.nameHash(text);
            try self.s.names.tally(hash, 1);
            try self.s.names.hold(hash, holderOf(self, node));
        }
    } else if (v.abstraction_name == id) {
        const at = ts.ts_node_start_point(node);
        if (enabled.enabled("single-impl-abstraction")) try facts.abstraction(text, .{ at.row, at.column });
    } else if (v.implementation_base == id) {
        if (enabled.enabled("single-impl-abstraction")) try facts.implemented.add(facts_module.typeHash(facts.language, text));
    } else if (v.reference_passed == id) {
        if (enabled.enabled("dead-parameter")) try facts.passed.add(facts_module.nameHash(text));
    } else return false;
    const names = &self.s.names;
    if (names.distinct() > names.room()) assert.panic("{s}: {d} names in room for {d}; Bounded.add() must refuse to grow past its buffer", .{ facts.path, names.distinct(), names.room() });
    return true;
}

/// The hash of what holds a reference at `node`: the name itself where it names the construct it
/// belongs to (@reference.self), the construct's own name where only it keeps the name alive
/// (@reference.held), or else the outermost named function, class or definition open around it;
/// 0 at module level.
fn holderOf(self: *File, node: ts.Node) u64 {
    const compiled = self.checker.compiled;
    if (self.index.marks(node, compiled.id("reference.self"))) return facts_module.nameHash(node.text(self.source));
    if (self.index.marks(node, compiled.id("reference.held"))) if (heldBy(self, node)) |owner| return facts_module.nameHash(owner.text(self.source));
    const items = self.s.contexts.items();
    if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
    if (self.source.len == 0 and items.len > 0) assert.panic("{s}: {d} constructs open in an empty file", .{ self.work.facts.path, items.len });
    for (items) |ctx| {
        if (ctx.family != .function and ctx.family != .class and ctx.family != .definition) continue;
        const name = ctx.name orelse continue;
        const text = name.text(self.source);
        if (text.len > 0) return facts_module.nameHash(text);
    }
    return 0;
}

/// The @reference.self name of the construct `node` sits in, such as the type of an impl block:
/// a child of an enclosing node, or a child of that child, as in `impl Trait for Type<T>`.
fn heldBy(self: *File, node: ts.Node) ?ts.Node {
    const self_id = self.checker.compiled.id("reference.self") orelse return null;
    if (!self.index.marks(node, self.checker.compiled.id("reference.held"))) assert.panic("{s}: looking for what holds {f}, which isn't a @reference.held name; call heldBy() only for @reference.held captures", .{ self.work.facts.path, node.where() });
    var current = node.parent();
    for (0..max_holder_steps) |_| {
        const construct = current orelse return null;
        for (0..@min(ts.ts_node_named_child_count(construct), max_holder_children)) |i| {
            const child = ts.ts_node_named_child(construct, @intCast(i));
            if (self.index.marks(child, self_id)) return child;
            for (0..@min(ts.ts_node_named_child_count(child), max_holder_children)) |k| {
                const grandchild = ts.ts_node_named_child(child, @intCast(k));
                if (self.index.marks(grandchild, self_id)) return grandchild;
            }
        }
        current = construct.parent();
    }
    if (current == null) assert.panic("{s}: the walk up from {f} ran off the root without returning; return from the walk when it reaches the root", .{ self.work.facts.path, node.where() });
    return null;
}

/// Enclosing nodes heldBy() climbs, and children it looks through at each level.
const max_holder_steps = 8;
const max_holder_children = 16;

/// Records the calls `ctx` makes by bare name, other than to its own locals, and how many
/// parameters it declares, for the cross-file call graph.
pub fn resolveBareCalls(self: *File, ctx: check.Context) !void {
    const caller = ctx.fact orelse return;
    try self.work.facts.arity(caller, ctx.formal_parameters, try types.ofParameters(self, ctx));
    if (ctx.family != .function) assert.panic("{s}: resolving the calls of {f}, which is a {t}, not a function; call resolveBareCalls() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const reach: facts_module.Reach = if (self.tables.methods_need_receiver) .functions else .any;
    const locals = self.s.locals.items();
    const calls = self.s.bare_calls.items();
    if (ctx.owned_start > calls.len or ctx.owned_start > locals.len) assert.panic("{s}: {f} owns calls and locals from {d}, but only {d} calls and {d} locals are recorded; open() must set owned_start from those lists' lengths when the function opens", .{ self.work.facts.path, ctx.node.where(), ctx.owned_start, calls.len, locals.len });
    outer: for (calls[ctx.owned_start..]) |call| {
        if (call.owner != ctx.serial) continue;
        for (locals[ctx.owned_start..]) |local| {
            if (local.owner == ctx.serial and check.sameText(local.text, call.text)) continue :outer;
        }
        try self.work.facts.call(.{ .caller = caller, .callee = call.text, .reach = reach, .arguments = call.arguments, .types = call.types });
    }
}
