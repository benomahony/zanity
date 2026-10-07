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
const memory = @import("memory.zig");
const strings = @import("strings.zig");
const rules = @import("rules.zig");
const naming = @import("naming.zig");

/// Parameters a long list is read with when advising how to group them.
const max_listed = 32;
/// Names a piece of grouping advice shows; the rest are counted.
const max_named = 4;

/// Reports a function that takes more than `rules.max_parameters` parameters, unless it is a test,
/// whose parameters are fixtures it asks for, or something else fixes its signature. The fix says
/// which parameters to group: those whose names share a word, and those with defaults.
pub fn checkParameterCount(self: *File, ctx: Context, name_node: ts.Node, name: []const u8) !void {
    if (ctx.family != .function) assert.panic("{s}: counting the parameters of the {t} '{s}'; only functions have them", .{ self.work.facts.path, ctx.family, name });
    if (ctx.formal_parameters <= rules.max_parameters or ctx.is_test) return;
    if (ctx.parameter_start + ctx.parameter_count > self.s.signature.len) assert.panic("{s}: '{s}' owns parameters {d}..{d}, but only {d} are recorded; parameter() adds each to the signature", .{ self.work.facts.path, name, ctx.parameter_start, ctx.parameter_start + ctx.parameter_count, self.s.signature.len });
    if (signatureFixedElsewhere(self, ctx, name)) return;
    if (!try self.report(name_node, "long-parameter-list", try self.say("'{s}' takes {d} parameters; functions should take at most {d}.", .{ name, ctx.formal_parameters, rules.max_parameters }))) return;
    self.s.diagnostics.last().?.fix = try groupingFix(self, ctx, name);
}

/// Which of `ctx`'s parameters to pass as one value: the most that share a word of their names,
/// and those with a default, which can go in an options value.
fn groupingFix(self: *File, ctx: Context, name: []const u8) ![]const u8 {
    if (ctx.formal_parameters <= rules.max_parameters) assert.panic("{s}: advising how to group the {d} parameters of '{s}', no more than the {d} allowed; checkParameterCount() returns before short lists", .{ self.work.facts.path, ctx.formal_parameters, name, rules.max_parameters });
    var names: [max_listed][]const u8 = undefined;
    var defaulted: [max_listed][]const u8 = undefined;
    var count: usize = 0;
    var defaults: usize = 0;
    const signature = self.s.signature.items()[ctx.parameter_start..][0..ctx.parameter_count];
    for (signature) |parameter| {
        const text = parameter.name.text(self.source);
        if (text.len == 0 or contains(self.tables.self_receivers, text) or count == max_listed) continue;
        names[count] = text;
        count += 1;
        const declaration = parameter.name.parent() orelse continue;
        const whole = declaration.text(self.source);
        if (std.mem.indexOfScalar(u8, whole, '=') != null or std.mem.indexOf(u8, whole, "?:") != null) {
            defaulted[defaults] = text;
            defaults += 1;
        }
    }
    const text = self.work.text;
    const start = text.used;
    const group = sharedWord(names[0..count]);
    if (group) |shared| {
        _ = try text.copy("Pass ");
        try list(text, names[0..count], shared);
        _ = try text.format(" as one '{s}' value", .{shared.word});
        defaults = outside(defaulted[0..defaults], shared);
    }
    if (defaults >= 2) {
        _ = try text.copy(if (text.used > start) ", and move " else "Move ");
        try list(text, defaulted[0..defaults], null);
        _ = try text.copy(", which have defaults, into one options value");
    }
    if (text.used == start) return self.say("Split '{s}' by what each part needs, or pass the parameters that always travel together as one value.", .{name});
    _ = try text.copy(".");
    if (defaults > count) assert.panic("{s}: '{s}' has {d} parameters with defaults among {d}; each is counted once", .{ self.work.facts.path, name, defaults, count });
    return text.buffer[start..text.used];
}

/// The first or last word most parameter names share in that place, such as `tokens` in
/// `input_tokens` and `output_tokens`, when at least two share one.
fn sharedWord(names: []const []const u8) ?Shared {
    if (names.len > max_listed) assert.panic("looking for a shared word among {d} names, more than the {d} groupingFix() collects", .{ names.len, max_listed });
    var best: ?Shared = null;
    var best_count: usize = 1;
    for (names) |candidate| {
        for ([_]Place{ .first, .last }) |place| {
            const word = wordAt(candidate, place) orelse continue;
            if (word.len < 3) continue;
            var sharing: usize = 0;
            for (names) |other| sharing += @intFromBool(sameWordAt(other, word, place));
            if (sharing > best_count) {
                best = .{ .word = word, .place = place };
                best_count = sharing;
            }
        }
    }
    if (best != null and best_count < 2) assert.panic("chose the word '{s}' shared by {d} names; a shared word needs two", .{ best.?.word, best_count });
    return best;
}

const Place = enum { first, last };
const Shared = struct { word: []const u8, place: Place };

/// Keeps the names of `names` that don't share `shared`'s word, in order, and returns how many.
fn outside(names: [][]const u8, shared: Shared) usize {
    if (shared.word.len == 0) assert.panic("filtering names by an empty word; sharedWord() skips short words", .{});
    var kept: usize = 0;
    for (names) |n| {
        if (sameWordAt(n, shared.word, shared.place)) continue;
        names[kept] = n;
        kept += 1;
    }
    if (kept > names.len) assert.panic("kept {d} of {d} names; filtering only removes", .{ kept, names.len });
    return kept;
}

/// The first or last word of a name with at least two words.
fn wordAt(name: []const u8, place: Place) ?[]const u8 {
    if (name.len == 0) assert.panic("reading the words of an empty name; skip unnamed parameters first", .{});
    var words: naming.Words = .{ .text = name };
    const first = words.next() orelse return null;
    var last = first;
    var count: usize = 1;
    for (0..name.len) |_| {
        last = words.next() orelse break;
        count += 1;
    }
    if (count < 2) return null;
    if (last.len == 0) assert.panic("the last word of '{s}' is empty; Words never returns one", .{name});
    return if (place == .first) first else last;
}

fn sameWordAt(name: []const u8, word: []const u8, place: Place) bool {
    if (word.len == 0) assert.panic("comparing '{s}' with an empty word; sharedWord() skips short words", .{name});
    if (name.len == 0) assert.panic("comparing an empty name with '{s}'; skip unnamed parameters first", .{word});
    const own = wordAt(name, place) orelse return false;
    return std.ascii.eqlIgnoreCase(own, word);
}

/// Writes `names`, or only those sharing `shared`'s word in its place, quoted, with the rest counted.
fn list(text: *memory.Text, names: []const []const u8, shared: ?Shared) !void {
    if (names.len < 2) assert.panic("listing {d} names to group; a group needs two", .{names.len});
    var picked: [max_named][]const u8 = undefined;
    var shown: usize = 0;
    var rest: usize = 0;
    for (names) |n| {
        if (shared) |sh| if (!sameWordAt(n, sh.word, sh.place)) continue;
        if (shown == max_named) {
            rest += 1;
            continue;
        }
        picked[shown] = n;
        shown += 1;
    }
    if (shown < 2) assert.panic("listing {d} parameters to group; a group needs two", .{shown});
    for (picked[0..shown], 0..) |n, i| {
        const separator = if (i == 0) "" else if (i + 1 == shown and rest == 0) " and " else ", ";
        _ = try text.format("{s}'{s}'", .{ separator, n });
    }
    if (rest > 0) _ = try text.format(" and {d} more", .{rest});
}

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
    return passedAsValue(self, name, own);
}

/// Whether code in the file names `name` without calling it, other than at `own`, the function's
/// own name: passing it to something, storing or returning it. Only identifiers count, so a
/// mention in a comment, a docstring or a string such as `__all__` doesn't.
fn passedAsValue(self: *File, name: []const u8, own: usize) bool {
    if (name.len == 0) assert.panic("searching for an empty name; skip unnamed functions first", .{});
    const reference = self.checker.compiled.id("reference.name") orelse return false;
    for (self.index.triples) |t| {
        if (t.id != reference or t.key.start == own) continue;
        const end = ts.ts_node_end_byte(t.node);
        if (end - t.key.start != name.len or !std.mem.eql(u8, self.source[t.key.start..end], name)) continue;
        if (t.key.start > 0 and self.source[t.key.start - 1] == '.') continue;
        const after = std.mem.trimStart(u8, self.source[end..], " \t");
        if (after.len > 0 and std.mem.indexOfScalar(u8, "(=:", after[0]) != null) continue;
        return true;
    }
    if (own >= self.source.len) assert.panic("{s}: '{s}' is named at byte {d} of a {d}-byte file; pass a function from this file", .{ self.work.facts.path, name, own, self.source.len });
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
