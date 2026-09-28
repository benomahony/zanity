//! Rewrites an assertion without a message into the language's explaining form, naming the
//! values its condition reads, for the advice and for `check --fix`.
const std = @import("std");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const header = check.header;
const messages = @import("messages.zig");
const hazards = @import("hazards.zig");

/// The values an assertion condition reads, outermost first, without callees: at most `out.len`.
pub fn conditionValues(self: *File, condition: ts.Node, out: *[4][]const u8) []const []const u8 {
    const start = ts.ts_node_start_byte(condition);
    const end = ts.ts_node_end_byte(condition);
    if (start > end or end > self.source.len) std.debug.panic("{s}: the condition spans bytes {d}..{d} of a {d}-byte file", .{ self.work.facts.path, start, end, self.source.len });
    var widest: [8]ts.Node = undefined;
    const found = widestPaths(self, start, end, &widest);
    var count: usize = 0;
    for (widest[0..found]) |node| {
        const after = std.mem.trimStart(u8, self.source[ts.ts_node_end_byte(node)..end], " \t");
        if (after.len > 0 and after[0] == '(') continue;
        const text = node.text(self.source);
        if (!(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) continue;
        if (count == out.len or contains(out[0..count], text)) continue;
        out[count] = text;
        count += 1;
    }
    if (count > found) std.debug.panic("{s}: kept {d} values from only {d} candidates", .{ self.work.facts.path, count, found });
    return out[0..count];
}

/// The outermost names and field accesses between `start` and `end`, in order: `a.len`, not `a`.
fn widestPaths(self: *File, start: u32, end: u32, widest: *[8]ts.Node) usize {
    if (start > end) std.debug.panic("{s}: looking for values in bytes {d}..{d}, which run backwards", .{ self.work.facts.path, start, end });
    var found: usize = 0;
    for (self.index.triples) |t| {
        if (t.id != self.v.expression_path or t.key.start < start or ts.ts_node_end_byte(t.node) > end) continue;
        if (found > 0 and t.key.start < ts.ts_node_end_byte(widest[found - 1])) {
            const last = widest[found - 1];
            if (t.key.start == ts.ts_node_start_byte(last) and ts.ts_node_end_byte(t.node) > ts.ts_node_end_byte(last)) widest[found - 1] = t.node;
            continue;
        }
        if (found == widest.len) break;
        widest[found] = t.node;
        found += 1;
    }
    if (found > widest.len) std.debug.panic("{s}: kept {d} values in room for {d}", .{ self.work.facts.path, found, widest.len });
    return found;
}

/// The assertion rewritten in the language's explaining form, naming the values that broke it.
pub fn assertionRewrite(self: *File, condition: ts.Node) ![]const u8 {
    const t = self.tables;
    if (t.assertion_form.len == 0) return "";
    var buffer: [4][]const u8 = undefined;
    const values = conditionValues(self, condition, &buffer);
    if (values.len > buffer.len) std.debug.panic("{s}: conditionValues returned {d} values into room for {d}", .{ self.work.facts.path, values.len, buffer.len });
    const form = if (values.len > 0) t.assertion_form else t.assertion_form_bare;
    const text = self.work.text;
    const start = text.used;
    var rest = form;
    while (std.mem.indexOfScalar(u8, rest, '$')) |at| {
        _ = try text.copy(rest[0..at]);
        rest = rest[at..];
        const placeholder = for ([_][]const u8{ "$condition", "$message", "$shown", "$values" }) |p| {
            if (std.mem.startsWith(u8, rest, p)) break p;
        } else "$";
        rest = rest[placeholder.len..];
        try writePlaceholder(self, placeholder, condition.text(self.source), values);
    }
    _ = try text.copy(rest);
    const code = text.buffer[start..text.used];
    if (std.mem.indexOf(u8, code, condition.text(self.source)) == null) std.debug.panic("expected the rewrite to contain the condition '{s}', got: {s}", .{ condition.text(self.source), code });
    return code;
}

/// Advises the explaining form of an assertion and, where the language has
/// line comments, the edit that writes it with a TODO for the reason only a person knows.
pub fn explainAssertion(self: *File, node: ts.Node, condition: ts.Node) !void {
    const diagnostic = self.s.diagnostics.last() orelse unreachable;
    if (!std.mem.eql(u8, diagnostic.rule, "assertion-message")) std.debug.panic("expected the assertion-message finding, got {s}", .{diagnostic.rule});
    const code = try assertionRewrite(self, condition);
    if (code.len == 0) return;
    diagnostic.fix = try self.say("Write it as `{s}`, so a failure says what broke and with which values.", .{code});
    const comment = self.tables.line_comment;
    if (comment.len == 0) return;
    const start = ts.ts_node_start_byte(node);
    var end = ts.ts_node_end_byte(node);
    if (end < self.source.len and self.source[end] == code[code.len - 1] and std.ascii.isPunctuation(self.source[end])) end += 1;
    const line_start = if (std.mem.lastIndexOfScalar(u8, self.source[0..start], '\n')) |newline| newline + 1 else 0;
    const before = self.source[line_start..start];
    const indent = before[0 .. before.len - std.mem.trimStart(u8, before, " \t").len];
    const replacement = try self.work.text.format("{s}{s} TODO: say why this must hold and what to look at when it fails.\n{s}{s}", .{ indent, comment, before, code });
    diagnostic.edit = .{ .start = @intCast(line_start), .end = end, .replacement = replacement };
    if (!(line_start <= start and start < end)) std.debug.panic("expected the edit to cover the assertion, got {d}..{d} around {d}", .{ line_start, end, start });
}

pub fn writePlaceholder(self: *File, placeholder: []const u8, condition: []const u8, values: []const []const u8) !void {
    const t = self.tables;
    const text = self.work.text;
    if (placeholder.len == 0 or placeholder[0] != '$') std.debug.panic("expected a placeholder starting with '$', got '{s}'", .{placeholder});
    if (std.mem.eql(u8, placeholder, "$condition")) {
        _ = try text.copy(condition);
    } else if (std.mem.eql(u8, placeholder, "$message")) {
        try quote(text, condition, t.assertion_braces_doubled and values.len > 0);
    } else if (std.mem.eql(u8, placeholder, "$shown")) {
        for (values, 0..) |v, i| {
            if (i > 0) _ = try text.copy(", ");
            var parts = std.mem.splitSequence(u8, t.assertion_value, "$name");
            _ = try text.copy(parts.first());
            var shown_name = true;
            while (parts.next()) |part| : (shown_name = false) {
                if (shown_name) try quote(text, v, t.assertion_braces_doubled) else _ = try text.copy(v);
                _ = try text.copy(part);
            }
        }
    } else if (std.mem.eql(u8, placeholder, "$values")) {
        for (values, 0..) |v, i| _ = try text.format("{s}{s}", .{ if (i > 0) ", " else "", v });
    } else {
        _ = try text.copy(placeholder);
    }
    if (text.used > text.buffer.len) std.debug.panic("expected the text buffer to hold {d} bytes, got {d}", .{ text.buffer.len, text.used });
}

/// Copies `code` into a string literal: quotes become apostrophes, whitespace runs one space,
/// and braces double when the string is a format string.
pub fn quote(text: *memory.Text, code: []const u8, doubled: bool) !void {
    const before = text.used;
    if (before > text.buffer.len) std.debug.panic("expected the text buffer to hold its {d} used bytes, got {d} bytes of room", .{ before, text.buffer.len });
    var spaced = false;
    for (code) |c| {
        const space = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        defer spaced = space;
        if (space and spaced) continue;
        _ = try text.copy(switch (c) {
            '"' => "'",
            '{' => if (doubled) "{{" else "{",
            '}' => if (doubled) "}}" else "}",
            '\n', '\r', '\t' => " ",
            else => &.{c},
        });
    }
    if (text.used - before > 2 * code.len) std.debug.panic("expected at most {d} quoted bytes for {d} of code, got {d}", .{ 2 * code.len, code.len, text.used - before });
}
