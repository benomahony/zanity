//! A wrapper that only forwards: a function whose body is one call that passes its own
//! parameters on unchanged, so callers could call the target themselves. A wrapper that fixes an
//! argument, transforms one or is a method is giving a name to a decision, and isn't reported.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const strings = @import("strings.zig");
const File = check.File;
const Context = check.Context;

/// Arguments a forwarded call is read with; a longer call isn't treated as forwarding.
const max_arguments = 16;

/// Reports `ctx` when it only forwards its parameters, naming the call to make instead.
pub fn checkPassthrough(self: *File, ctx: Context, name_node: ts.Node, name: []const u8) !void {
    if (name.len == 0) assert.panic("{s}: checking an unnamed function for forwarding; closeFunction() returns before unnamed ones", .{self.work.facts.path});
    if (ctx.family != .function) assert.panic("{s}: checking the {t} '{s}' for forwarding; only functions forward", .{ self.work.facts.path, ctx.family, name });
    const callee = forwardedTo(self, ctx, name) orelse return;
    if (!try self.report(name_node, "passthrough-wrapper", try self.say("'{s}' only forwards its parameters to {s}, so it adds a name without adding behaviour.", .{ name, callee }))) return;
    self.s.diagnostics.last().?.fix = try self.say("Use {s} directly wherever '{s}' is used, then delete '{s}'.", .{ callee, name, name });
}

/// The callee `ctx`'s body forwards its parameters to, unchanged and in order, or null when the
/// body adds, fixes or transforms anything, `ctx` is decorated or a name the language calls, or it
/// is a method that delegates to another object, as a wrapper class must.
fn forwardedTo(self: *File, ctx: Context, name: []const u8) ?[]const u8 {
    if (ctx.body_start == std.math.maxInt(u32)) return null;
    const fact = ctx.fact orelse return null;
    if (check.contains(self.tables.protocol_names, name) or strings.dunder(name)) return null;
    if (strings.decoratedAt(self.source, ts.ts_node_start_byte(ctx.node))) return null;
    const call = soleCall(self.source[ctx.body_start..ts.ts_node_end_byte(ctx.span)]) orelse return null;
    const facts = self.work.facts;
    if (facts.functions.items()[fact].method and !ownMethod(self.tables.self_receivers, call.callee)) return null;
    const params = self.s.signature.items()[ctx.parameter_start..][0..ctx.parameter_count];
    var arguments = Arguments{ .text = call.arguments };
    var used: usize = 0;
    for (0..max_arguments + 1) |_| {
        const argument = arguments.next() orelse break;
        if (used == params.len) return null;
        const param = bare(params[used].name.text(self.source));
        if (!std.mem.eql(u8, bare(keywordValue(argument)), param)) return null;
        used += 1;
    } else return null;
    if (used != params.len) return null;
    if (used > max_arguments) assert.panic("{s}: matched {d} arguments of '{s}', past the {d} read; the loop stops at max_arguments", .{ self.work.facts.path, used, name, max_arguments });
    if (call.callee.len == 0) assert.panic("{s}: read a call with no callee in '{s}'; soleCall() requires text before the parenthesis", .{ self.work.facts.path, name });
    return call.callee;
}

/// Whether a method's callee is another method of the same object, `g`, `self.g` or `this.g`,
/// rather than another object's, as in `self.wrapped.g`.
fn ownMethod(receivers: []const []const u8, callee: []const u8) bool {
    if (callee.len == 0) assert.panic("asked whose method an empty callee is; soleCall() requires a callee", .{});
    const dot = std.mem.indexOfScalar(u8, callee, '.') orelse return true;
    if (dot == 0) assert.panic("the callee '{s}' starts with a dot; plainName() lets through only names and dotted paths", .{callee});
    const rest = callee[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '.') != null) return false;
    return check.contains(receivers, callee[0..dot]) and rest.len > 0;
}

/// A name without the spread or reference marks around it, such as `*args`, `**kw`, `...rest`
/// or `&x`.
fn bare(text: []const u8) []const u8 {
    if (text.len == 0) assert.panic("stripping the marks from an empty name; arguments and parameters always have text", .{});
    const name = std.mem.trim(u8, text, " \t\r\n*.&");
    if (name.len > text.len) assert.panic("'{s}' came out longer than '{s}'; trimming only shortens", .{ name, text });
    return name;
}

/// The value of a keyword argument such as `name=name`, or the argument itself.
fn keywordValue(argument: []const u8) []const u8 {
    if (argument.len == 0) assert.panic("reading the value of an empty argument; Arguments.next() skips empty ones", .{});
    const eq = std.mem.indexOfScalar(u8, argument, '=') orelse return argument;
    if (eq + 1 < argument.len and argument[eq + 1] == '=') return argument;
    if (eq + 1 > argument.len) assert.panic("the '=' of '{s}' is past its end", .{argument});
    return argument[eq + 1 ..];
}

const Call = struct { callee: []const u8, arguments: []const u8 };

/// The callee and argument text of a body that is a single call, after `return`, `await` or
/// `try` and before a closing `;` or `}`.
fn soleCall(body: []const u8) ?Call {
    if (body.len == 0) assert.panic("reading the call of an empty body; forwardedTo() passes a body with its first statement", .{});
    var text = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.endsWith(u8, text, "}")) text = std.mem.trimEnd(u8, text[0 .. text.len - 1], " \t\r\n");
    text = std.mem.trimEnd(u8, text, "; \t\r\n");
    for ([_][]const u8{ "return ", "await ", "try " }) |word| {
        if (std.mem.startsWith(u8, text, word)) text = std.mem.trimStart(u8, text[word.len..], " \t");
    }
    if (std.mem.startsWith(u8, text, "await ")) text = text["await ".len..];
    if (!std.mem.endsWith(u8, text, ")")) return null;
    const open = matchingOpen(text) orelse return null;
    const callee = std.mem.trim(u8, text[0..open], " \t");
    if (callee.len == 0 or !plainName(callee)) return null;
    if (open + 1 > text.len - 1) assert.panic("the call '{s}' opens at {d}, after it closes; matchingOpen() returns a parenthesis before the last", .{ text, open });
    return .{ .callee = callee, .arguments = text[open + 1 .. text.len - 1] };
}

/// Whether `callee` is a name or a dotted path to one, such as `g`, `mod.g` or `pkg::g`, and not
/// a keyword and a call such as `yield g`, which changes what the function is, or a Zig
/// declaration literal such as `.fromType`, whose type comes from where it is used.
fn plainName(callee: []const u8) bool {
    if (callee.len == 0) assert.panic("asked whether an empty callee is a plain name; soleCall() checks the length first", .{});
    for (callee) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':' or c == '$')) return false;
    if (std.mem.indexOfAny(u8, callee, " \t") != null) assert.panic("'{s}' passed as a plain name with a space in it; the loop above rejects spaces", .{callee});
    const lead = callee[0];
    return std.ascii.isAlphabetic(lead) or lead == '_' or lead == '$';
}

/// The parenthesis that opens the call ending at the last byte of `text`.
fn matchingOpen(text: []const u8) ?usize {
    if (text.len == 0 or text[text.len - 1] != ')') assert.panic("matching the parenthesis of '{s}', which doesn't end with one; soleCall() checks first", .{text});
    var depth: usize = 0;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        switch (text[i]) {
            ')', ']', '}' => depth += 1,
            '(', '[', '{' => {
                depth -= 1;
                if (depth == 0) return if (text[i] == '(') i else null;
            },
            else => {},
        }
    }
    if (depth == 0) assert.panic("ran out of '{s}' with nothing open; the closing parenthesis at its end opens a level", .{text});
    return null;
}

/// The top-level arguments of a call, split at commas outside brackets and strings.
const Arguments = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Arguments) ?[]const u8 {
        for (0..self.text.len + 1) |_| {
            if (self.at >= self.text.len) return null;
            const start = self.at;
            self.at = argumentEnd(self.text, start);
            if (self.at < start or self.at > self.text.len) assert.panic("an argument of '{s}' from {d} ended at {d}; argumentEnd() stays between its start and the end", .{ self.text, start, self.at });
            const argument = std.mem.trim(u8, self.text[start..self.at], " \t\r\n");
            if (std.mem.indexOfScalar(u8, argument, ',') != null and std.mem.indexOfAny(u8, argument, "([{\"'`") == null) assert.panic("the argument '{s}' holds a top-level comma; argumentEnd() stops at the first one", .{argument});
            self.at += 1;
            if (argument.len > 0) return argument;
        }
        assert.panic("read past every argument of '{s}' without finishing; each pass moves past at least a comma", .{self.text});
    }
};

/// Where the argument from `start` ends: the next comma outside brackets and strings, or the end.
fn argumentEnd(text: []const u8, start: usize) usize {
    if (start >= text.len) assert.panic("reading an argument from byte {d} of '{s}'; next() stops at the end", .{ start, text });
    var depth: usize = 0;
    var quote: u8 = 0;
    var at = start;
    while (at < text.len) : (at += 1) {
        const c = text[at];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'', '`' => quote = c,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) return at,
            else => {},
        }
    }
    if (at != text.len) assert.panic("an argument of '{s}' ran to {d}, past its end", .{ text, at });
    return at;
}

test "a call that passes the parameters on unchanged is read as forwarding" {
    const call = soleCall("return unicodedata.normalize('NFKC', name)\n").?;
    try std.testing.expectEqualStrings("unicodedata.normalize", call.callee);
    var arguments = Arguments{ .text = call.arguments };
    try std.testing.expectEqualStrings("'NFKC'", arguments.next().?);
    try std.testing.expectEqualStrings("name", arguments.next().?);
    try std.testing.expect(arguments.next() == null);
    try std.testing.expectEqualStrings("g", soleCall("  return try g(a, b);\n}").?.callee);
    try std.testing.expect(soleCall("x = g(a)\nreturn x") == null);
    try std.testing.expect(soleCall("yield object(a)") == null);
    try std.testing.expect(strings.decoratedAt("x = 1\n@agent.system_prompt\ndef f():\n", 27));
    try std.testing.expect(!strings.decoratedAt("x = 1\n\ndef f():\n", 7));
}
