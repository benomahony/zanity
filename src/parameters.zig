//! Parameters a function takes but never reads, so every caller passes a value for nothing.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");
const hazards = @import("hazards.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;

/// Reports each parameter of `ctx` that nothing in its body refers to. Only names declared between
/// the function's name and its body count, so not a Go receiver or a caught exception. A function
/// whose signature something else fixes is left alone: one without a body, a one-line stub such as
/// `pass`, a test, whose parameters can be fixtures it asks for only for their effect, and a
/// method an interface or protocol fixes, such as `__exit__` or `ServeHTTP`; so are `self`, `this`, names starting `_`, and parameters that
/// declare a field, as TypeScript's `constructor(private ttl: number)` does.
pub fn checkUnusedParameters(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .function) assert.panic("{s}: checking the parameters of {f}, which is a {t}, not a function; call checkUnusedParameters() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (!self.checker.enabled.enabled("dead-parameter")) return;
    if (!ctx.body or ctx.is_test or self.codeLinesIn(ctx.span) <= 2) return;
    if (contains(self.tables.fixed_signatures, name)) return;
    const reference = self.checker.compiled.id("local.reference") orelse return;
    const field = self.checker.compiled.id("parameter.field");
    const header_start = ts.ts_node_end_byte(ctx.name orelse ctx.node);
    const signature = self.s.signature.items();
    if (ctx.parameter_start + ctx.parameter_count > signature.len) assert.panic("{s}: '{s}' owns parameters {d}..{d}, but only {d} are recorded; parameter() must add each parameter to the signature as it counts it", .{ self.work.facts.path, name, ctx.parameter_start, ctx.parameter_start + ctx.parameter_count, signature.len });
    for (signature[ctx.parameter_start..][0..ctx.parameter_count]) |parameter| {
        const at = ts.ts_node_start_byte(parameter.name);
        if (at < header_start or at >= ctx.body_start or self.index.marks(parameter.name, field)) continue;
        if (!declaredBy(self, ctx.node, parameter.name)) continue;
        const text = parameter.name.text(self.source);
        if (text.len == 0 or text[0] == '_' or contains(self.tables.self_receivers, text)) continue;
        if (referenced(self, ctx, parameter.name, reference)) continue;
        _ = try self.report(parameter.name, "dead-parameter", try self.say("'{s}' is a parameter of '{s}' that its body never uses, so every caller passes a value for nothing.", .{ text, name }));
    }
}

/// Whether anything in the function, besides the parameter's own name, refers to it.
fn referenced(self: *File, ctx: Context, parameter: ts.Node, reference: captures.Id) bool {
    const text = parameter.text(self.source);
    const start = ts.ts_node_start_byte(ctx.node);
    const end = ts.ts_node_end_byte(ctx.span);
    if (ts.ts_node_start_byte(parameter) < start or ts.ts_node_end_byte(parameter) > end) assert.panic("{s}: the parameter '{s}' at {f} lies outside its function {f}; capture parameters inside @function.outer", .{ self.work.facts.path, text, parameter.where(), ctx.node.where() });
    if (text.len == 0) assert.panic("{s}: the parameter at {f} has no name; @parameter.name must capture the identifier", .{ self.work.facts.path, parameter.where() });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, hazards.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != reference or t.node.eql(parameter)) continue;
        if (ts.ts_node_start_byte(t.node) == ts.ts_node_start_byte(parameter)) continue;
        if (std.mem.eql(u8, t.node.text(self.source), text)) return true;
    }
    return false;
}

/// Whether `name` is one of the function's own parameters rather than one inside a parameter's type,
/// such as `msg` in `logger: (msg: string) => void`: in every grammar a parameter's name sits at
/// most three levels below its function (name, parameter, parameter list, function).
fn declaredBy(self: *File, function: ts.Node, name: ts.Node) bool {
    if (ts.ts_node_start_byte(name) < ts.ts_node_start_byte(function)) assert.panic("{s}: the parameter {f} starts before its function {f}; capture parameters inside @function.outer", .{ self.work.facts.path, name.where(), function.where() });
    var current = name;
    for (0..3) |_| {
        current = current.parent() orelse return false;
        if (current.eql(function)) return true;
    }
    if (current.eql(name)) assert.panic("{s}: climbing from {f} stayed on it; parent() must return the enclosing node", .{ self.work.facts.path, name.where() });
    return false;
}
