//! Parsers that untrusted input can turn against the program: an XML parser that expands
//! external entities, and a regular expression whose nested quantifiers backtrack without bound.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const header = check.header;
const hazards = @import("hazards.zig");
const max_option_bytes = hazards.max_option_bytes;

pub fn checkNestedRegexQuantifier(self: *File, ctx: Context, name: []const u8, first: ts.Node) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a regex in {f}, which is a {t}; call only from checkRiskyArgument", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a regex for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    if (!self.index.marks(first, self.v.literal_string)) return;
    const matched = self.calleeIn(ctx, name, self.tables.regex_calls) orelse return;
    const pattern = first.text(self.source);
    if (!hasNestedRegexQuantifier(pattern)) return;
    _ = try self.report(first, "nested-regex-quantifier", try self.say("'{s}' compiles a pattern with an unbounded quantifier nested inside another, so crafted input can take exponential time: '{s}'.", .{ matched, header(pattern) }));
}

pub fn checkXmlEntityExpansion(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking XML options in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking XML options for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    var unsafe: ?ts.Node = null;
    if (self.calleeIn(ctx, name, self.tables.xml_entity_calls) != null) {
        for (ctx.arguments) |argument| if (argument) |node| {
            if (unsafeXmlEntityOption(node.text(self.source))) unsafe = node;
        };
    } else if (std.mem.eql(u8, name, "setExpandEntityReferences")) {
        if (ctx.arguments[0]) |enabled| {
            if (self.index.marks(enabled, self.v.literal_true)) unsafe = enabled;
        }
    } else if (std.mem.eql(u8, name, "setFeature")) {
        unsafe = insecureXmlFeature(self, ctx);
    }
    const option = unsafe orelse return;
    _ = try self.report(option, "xml-entity-expansion", try self.say("This XML parser enables DTD entity expansion, so untrusted XML can read local resources or expand recursively until resources are exhausted: '{s}'.", .{header(option.text(self.source))}));
}

fn unsafeXmlEntityOption(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text.len > max_option_bytes) return false;
    var normalized: [max_option_bytes]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        normalized[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (len > text.len) assert.panic("normalized {d} XML-option bytes from {d}; normalization only removes whitespace", .{ len, text.len });
    if (len > normalized.len) assert.panic("normalized {d} XML-option bytes into a {d}-byte buffer; reject oversized options first", .{ len, normalized.len });
    const option = normalized[0..len];
    return std.mem.indexOf(u8, option, "resolve_entities=true") != null or std.mem.indexOf(u8, option, "resolveentities:true") != null or std.mem.indexOf(u8, option, "noent:true") != null;
}

fn insecureXmlFeature(self: *File, ctx: Context) ?ts.Node {
    if (ctx.family != .call) assert.panic("{s}: checking an XML feature outside a call; checkXmlEntityExpansion passes a call", .{self.work.facts.path});
    const feature = ctx.arguments[0] orelse return null;
    const enabled = ctx.arguments[1] orelse return null;
    if (ts.ts_node_end_byte(feature) > ts.ts_node_start_byte(enabled)) assert.panic("{s}: XML feature name {f} overlaps its value {f}; @call.argument must capture sibling arguments", .{ self.work.facts.path, feature.where(), enabled.where() });
    const name = std.mem.trim(u8, feature.text(self.source), "\"'");
    const value = enabled.text(self.source);
    const external = std.mem.endsWith(u8, name, "/external-general-entities") or std.mem.endsWith(u8, name, "/external-parameter-entities") or std.mem.endsWith(u8, name, "/load-external-dtd");
    const false_word = [_]u8{ 'f', 'a', 'l', 's', 'e' };
    const allows_doctype = std.mem.endsWith(u8, name, "/disallow-doctype-decl") and std.mem.eql(u8, value, &false_word);
    if (external and self.index.marks(enabled, self.v.literal_true)) return enabled;
    return if (allows_doctype) enabled else null;
}

fn hasNestedRegexQuantifier(pattern: []const u8) bool {
    if (pattern.len == 0) assert.panic("checking an empty regex source; string literal captures include their quotes", .{});
    if (std.mem.indexOfAny(u8, pattern, "\r\n") != null) return false;
    var group: usize = 0;
    while (group + 4 < pattern.len) : (group += 1) {
        if (pattern[group] == '\\') {
            group += 1;
            continue;
        }
        if (pattern[group] != '(') continue;
        var atom = group + 1;
        if (std.mem.startsWith(u8, pattern[atom..], "?:")) atom += 2;
        const atom_end = regexAtomEnd(pattern, atom) orelse continue;
        if (atom_end + 2 >= pattern.len or (pattern[atom_end] != '+' and pattern[atom_end] != '*')) continue;
        if (pattern[atom_end + 1] != ')') continue;
        const outer = pattern[atom_end + 2];
        if (outer == '+' or outer == '*') return true;
    }
    if (group > pattern.len) assert.panic("regex scan advanced to {d} past a {d}-byte pattern; escaped bytes may skip only one byte", .{ group, pattern.len });
    return false;
}

fn regexAtomEnd(pattern: []const u8, start: usize) ?usize {
    if (start > pattern.len) assert.panic("regex atom starts at {d}, past a {d}-byte pattern", .{ start, pattern.len });
    if (std.mem.indexOfAny(u8, pattern, "\r\n") != null) assert.panic("finding an atom in a multiline regex; hasNestedRegexQuantifier rejects it first", .{});
    if (start >= pattern.len) return null;
    if (pattern[start] == '\\') return if (start + 1 < pattern.len) start + 2 else null;
    if (pattern[start] != '[') return start + 1;
    var at = start + 1;
    while (at < pattern.len) : (at += 1) {
        if (pattern[at] == '\\') {
            at += 1;
            continue;
        }
        if (pattern[at] == ']') return at + 1;
    }
    return null;
}
