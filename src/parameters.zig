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
const strings = @import("strings.zig");

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
    if (contains(self.tables.fixed_signatures, name) or signatureFixedElsewhere(self, ctx, name)) return;
    const reference = self.checker.compiled.id("local.reference") orelse return;
    const field = self.checker.compiled.id("parameter.field");
    const header_start = ts.ts_node_end_byte(ctx.name orelse ctx.node);
    const signature = self.s.signature.items();
    if (ctx.parameter_start + ctx.parameter_count > signature.len) assert.panic("{s}: '{s}' owns parameters {d}..{d}, but only {d} are recorded; parameter() must add each parameter to the signature as it counts it", .{ self.work.facts.path, name, ctx.parameter_start, ctx.parameter_start + ctx.parameter_count, signature.len });
    for (signature[ctx.parameter_start..][0..ctx.parameter_count]) |parameter| {
        if (!checkable(self, ctx, parameter.name, .{ .header_start = header_start, .field = field })) continue;
        if (referenced(self, ctx, parameter.name, reference)) continue;
        try reportUnused(self, ctx, parameter.name, name);
    }
}

/// Where a function's own parameters can be: after its name, and not declaring a field.
const Header = struct { header_start: u32, field: ?captures.Id };

/// Whether `parameter` is one of the function's own parameters that a caller must pass a value
/// for: declared in its header, not a field, `self`, `this` or a name starting `_`.
fn checkable(self: *File, ctx: Context, parameter: ts.Node, header: Header) bool {
    const at = ts.ts_node_start_byte(parameter);
    if (at < header.header_start or at >= ctx.body_start or self.index.marks(parameter, header.field)) return false;
    if (!declaredBy(self, ctx.node, parameter)) return false;
    const text = parameter.text(self.source);
    if (text.len > 0 and at + text.len > ts.ts_node_end_byte(ctx.span)) assert.panic("{s}: the parameter '{s}' runs past its function {f}; capture parameters inside @function.outer", .{ self.work.facts.path, text, ctx.node.where() });
    if (header.header_start > ctx.body_start) assert.panic("{s}: the header of {f} starts at {d}, after its body at {d}; the name comes before the body", .{ self.work.facts.path, ctx.node.where(), header.header_start, ctx.body_start });
    return !(text.len == 0 or text[0] == '_' or contains(self.tables.self_receivers, text));
}

/// Reports `parameter` of `name` as unused, with how many calls in this file pass it.
fn reportUnused(self: *File, ctx: Context, parameter: ts.Node, name: []const u8) !void {
    const text = parameter.text(self.source);
    if (text.len == 0 or name.len == 0) assert.panic("{s}: reporting the parameter '{s}' of '{s}', and one is empty; checkUnusedParameters() skips unnamed ones", .{ self.work.facts.path, text, name });
    if (!try self.report(parameter, "dead-parameter", try self.say("'{s}' is a parameter of '{s}' that its body never uses, so every caller passes a value for nothing.", .{ text, name }))) return;
    const calls = callsIn(self.source, name, ts.ts_node_start_byte(ctx.name orelse ctx.node));
    const finding = self.s.diagnostics.last().?;
    finding.fix = if (calls == 0)
        try self.say("Remove '{s}' from '{s}', and its argument from the calls to '{s}' in other files; if the body was meant to use '{s}', that is the bug to fix instead.", .{ text, name, name, text })
    else
        try self.say("Remove '{s}' from '{s}' and its argument from the {d} {s} to '{s}' in this file, and from any in other files; if the body was meant to use '{s}', that is the bug to fix instead.", .{ text, name, calls, if (calls == 1) "call" else "calls", name, text });
    if (finding.fix.len == 0) assert.panic("{s}: the dead-parameter fix for '{s}' came out empty; say() always writes text", .{ self.work.facts.path, text });
}

/// Whether something other than the function's own body fixes its parameters: a decorator or
/// annotation that registers it, a base class it overrides a method of, or code in its file that
/// passes it as a value, as `FunctionModel(model_fn)` does, and so decides what it is called with.
fn signatureFixedElsewhere(self: *File, ctx: Context, name: []const u8) bool {
    if (name.len == 0) assert.panic("{s}: checking an unnamed function's signature; closeFunction() returns before unnamed ones", .{self.work.facts.path});
    if (strings.decoratedAt(self.source, ts.ts_node_start_byte(ctx.node))) return true;
    if (self.index.marks(ctx.node, self.checker.compiled.id("method.override"))) return true;
    const own = ts.ts_node_start_byte(ctx.name orelse ctx.node);
    if (own >= self.source.len) assert.panic("{s}: '{s}' is named at byte {d} of a {d}-byte file; pass a function from this file", .{ self.work.facts.path, name, own, self.source.len });
    return passedAsValue(self.source, name, own);
}

/// Whether `name` appears in `source` as a whole word that isn't called, at a place other than
/// `own`, the function's own name: passed to something, stored or returned.
fn passedAsValue(source: []const u8, name: []const u8, own: usize) bool {
    if (name.len == 0) assert.panic("searching for an empty name; skip unnamed functions first", .{});
    var from: usize = 0;
    for (0..source.len + 1) |_| {
        const at = std.mem.indexOfPos(u8, source, from, name) orelse return false;
        from = at + name.len;
        if (at == own) continue;
        const before_ok = at == 0 or std.mem.indexOfScalar(u8, word_bytes, source[at - 1]) == null;
        const after = std.mem.trimStart(u8, source[from..], " \t");
        const after_ok = from == source.len or std.mem.indexOfScalar(u8, word_bytes, source[from]) == null;
        if (!before_ok or !after_ok) continue;
        if (at > 0 and source[at - 1] == '.') continue;
        if (after.len > 0 and (after[0] == '(' or after[0] == '=')) continue;
        return true;
    }
    if (from <= source.len) assert.panic("searched '{s}' past every occurrence without finishing; each pass moves past one", .{name});
    return false;
}

/// How many times `name` is called in `source` as a whole word, other than at `own`.
fn callsIn(source: []const u8, name: []const u8, own: usize) usize {
    if (name.len == 0) assert.panic("counting calls to an empty name; skip unnamed functions first", .{});
    var count: usize = 0;
    var from: usize = 0;
    for (0..source.len + 1) |_| {
        const at = std.mem.indexOfPos(u8, source, from, name) orelse break;
        from = at + name.len;
        if (at == own or (at > 0 and std.mem.indexOfScalar(u8, word_bytes, source[at - 1]) != null) or (from < source.len and std.mem.indexOfScalar(u8, word_bytes, source[from]) != null)) continue;
        const after = std.mem.trimStart(u8, source[from..], " \t");
        if (after.len > 0 and after[0] == '(') count += 1;
    }
    if (count > source.len / (name.len + 2)) assert.panic("counted {d} calls to '{s}' in {d} bytes, more than fit; count each occurrence once", .{ count, name, source.len });
    return count;
}

/// Name bytes, which a whole-word match must not touch on either side.
const word_bytes = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";

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
