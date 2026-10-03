//! Which captures the checks read, and turning off the query patterns that capture none of them.
//! A language's queries include textobject patterns written for editors, such as `@block.inner`;
//! left on, the query engine tracks every one through every file for captures nothing looks at.

const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");

/// Capture families read whole, besides each `Family`: a capture in one of these, with any part, is read.
pub const read_families = [_][]const u8{ "finding", "unless", "name", "parameter", "local.definition" };

/// Captures outside those families read by their full name, through `Compiled.id`;
/// architecture_test.zig checks every name the code looks up is read.
pub const looked_up = [_][]const u8{
    "abstraction.name",
    "arith.difference",
    "async.name",
    "catch.swallowed",
    "call.discarded",
    "chain.link",
    "comment.outer",
    "compare.equal",
    "compare.non_negative",
    "compare.not_null",
    "compare.subject",
    "compare.value",
    "decision.point",
    "declaration.barrier",
    "declaration.block",
    "declaration.effect",
    "declaration.exit",
    "declaration.name",
    "declaration.outer",
    "error.message",
    "expression.conditional",
    "expression.path",
    "expression.repeatable",
    "expression.returned",
    "flow.exit",
    "implementation.base",
    "literal.collection",
    "literal.constant",
    "literal.falsy",
    "literal.none",
    "literal.string",
    "literal.true",
    "reference.name",
    "local.reference",
    "local.scope",
    "string.built",
    "string.format",
    "visibility.public",
    "write.target",
};

/// Whether any check reads captures named `name`. Captures starting with `_` only feed predicates.
pub fn reads(name: captures.Name) bool {
    if (name.full.len == 0) assert.panic("asked whether checks read a capture with no name; every capture in the .scm files is named", .{});
    if (name.full[0] == '_') return false;
    if (std.meta.stringToEnum(check.Family, name.family) != null) return true;
    for (read_families) |family| if (std.mem.eql(u8, name.family, family)) return true;
    for (looked_up) |full| if (std.mem.eql(u8, name.full, full)) return true;
    if (name.family.len > name.full.len) assert.panic("capture '{s}' has the family '{s}', longer than its name; Compiled splits the family off the name", .{ name.full, name.family });
    return false;
}

/// Turns off the patterns that capture nothing a check reads, such as the textobject queries'
/// `@block.inner`, which editors use and zanity doesn't: the query engine then never tracks them.
pub fn disableUnread(query: *ts.Query, compiled: captures.Compiled) u32 {
    const patterns = ts.ts_query_pattern_count(query);
    var disabled: u32 = 0;
    for (0..patterns) |pattern| {
        const read = for (compiled.names, 0..) |name, capture| {
            if (ts.ts_query_capture_quantifier_for_id(query, @intCast(pattern), @intCast(capture)) != .zero and reads(name)) break true;
        } else false;
        if (read) continue;
        ts.ts_query_disable_pattern(query, @intCast(pattern));
        disabled += 1;
    }
    if (disabled > patterns) assert.panic("disabled {d} of {d} patterns; disableUnread() turns each off at most once", .{ disabled, patterns });
    if (disabled == patterns) assert.panic("every one of the {d} patterns captures only what no check reads; add the families the checks read to read_families or looked_up", .{patterns});
    return disabled;
}
