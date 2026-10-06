//! Checks that trace to the engineering error catalogue: query-captured findings with their
//! `@unless` exceptions, and risky calls, secrets, nesting, unawaited calls and file length.
const std = @import("std");
const assert = @import("assert.zig");
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
const rewrite = @import("rewrite.zig");
const strings = @import("strings.zig");

/// A string literal assigned to a name that ends in a secret's name, such as `db_password` or `apiKey`.
/// Test code and values shaped like an environment variable's name are left alone.
pub fn checkSecret(self: *File, node: ts.Node, lhs: ts.Node, assigned: ts.Node) !void {
    if (ts.ts_node_end_byte(lhs) > ts.ts_node_start_byte(assigned)) assert.panic("{s}: the assigned name {f} overlaps its value {f}; the query captured the wrong nodes", .{ self.work.facts.path, lhs.where(), assigned.where() });
    const rhs = soleChild(assigned);
    if (!self.index.marks(rhs, self.v.literal_string) or self.index.marks(rhs, self.v.string_format)) return;
    if (self.inTest() or self.inTestFile()) return;
    const target = lhs.text(self.source);
    if (!namesSecret(target)) return;
    const value = std.mem.trim(u8, std.mem.trimStart(u8, rhs.text(self.source), "rbufRBUF@"), "\"'`");
    if (value.len == 0) return;
    const env_name = for (value) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) break false;
    } else true;
    if (env_name or placeholder(value)) return;
    _ = try self.report(node, "hardcoded-secret", try self.say("'{s}' is set to a secret written into the source, so the secret is in version control and in every copy of the code.", .{target}));
    if (value.len == 0) assert.panic("{s}: reported the empty value of '{s}' as a secret; checkSecret() must return before reporting an empty value", .{ self.work.facts.path, target });
}

fn placeholder(value: []const u8) bool {
    if (value.len == 0) assert.panic("asked whether an empty value is a placeholder; checkSecret() returns before an empty value", .{});
    if (value[0] == '"' or value[0] == '\'' or value[0] == '`') assert.panic("'{s}' still starts with its quote; checkSecret() must strip the quotes before asking", .{value});
    const masked = std.mem.indexOfScalar(u8, rules.secret_masks, value[0]) != null and std.mem.indexOfNone(u8, value, value[0..1]) == null;
    if (masked) return true;
    for (rules.secret_placeholders) |p| {
        if (p.len > value.len) continue;
        const rest = value.len - p.len;
        const head = std.ascii.startsWithIgnoreCase(value, p) and (rest == 0 or std.mem.indexOfScalar(u8, "-_. ", value[p.len]) != null);
        const tail = std.ascii.endsWithIgnoreCase(value, p) and (rest == 0 or std.mem.indexOfScalar(u8, "-_. ", value[rest - 1]) != null);
        if (head or tail) return true;
    }
    return false;
}

/// Whether a node captured `@unless.<rule>` sits inside `node` and belongs to it rather than to
/// a nested finding of the same rule, like the default case of this switch and not an inner one.
pub fn cancelled(self: *File, node: ts.Node, rule: []const u8) !bool {
    if (rule.len == 0) assert.panic("{s}: asked whether {f} is excused from a rule with no name; pass the rule's name", .{ self.work.facts.path, node.where() });
    var name_buffer: [96]u8 = undefined;
    const unless = self.checker.compiled.id(try std.fmt.bufPrint(&name_buffer, "unless.{s}", .{rule})) orelse return false;
    const finding = self.checker.compiled.id(try std.fmt.bufPrint(&name_buffer, "finding.{s}", .{rule})) orelse assert.panic("{s}: {f} was reported as {s}, but the query has no @finding.{s}; add @finding.<rule> to the language's zanity.scm, or report the rule without cancelled()", .{ self.work.facts.path, node.where(), rule, rule });
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != unless or ts.ts_node_end_byte(t.node) > end) continue;
        var current = self.parentOf(t.node);
        const owner = while (current) |c| : (current = self.parentOf(c)) {
            if (self.index.marks(c, finding)) break c;
        } else null;
        if (owner) |o| if (o.eql(node)) return true;
    }
    if (first > self.index.triples.len) assert.panic("{s}: the captures inside {f} start at {d}, past the {d} recorded; take the start from lowerBound over the recorded captures", .{ self.work.facts.path, node.where(), first, self.index.triples.len });
    return false;
}

/// Calls whose name alone makes them risky, or whose arguments do: weak hashes, unsafe
/// deserializers, shell command lines and SQL built at runtime, secrets written to logs, and
/// wall-clock reads used to time a duration.
pub fn checkRiskyCall(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} as a risky call, but it is a {t}; call checkRiskyCall() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const t = self.tables;
    const at = ctx.callee orelse ctx.name.?;
    if (self.calleeIn(ctx, name, t.weak_hashes)) |m| {
        _ = try self.report(at, "weak-hash", try self.say("'{s}' is a broken hash: collisions can be forged, so it can't protect passwords, signatures or integrity.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.unsafe_deserializers)) |m| {
        _ = try self.report(at, "unsafe-deserialization", try self.say("'{s}' can run code chosen by whoever wrote the data it reads.", .{m}));
    }
    if (ctx.arguments[0]) |first| try checkRiskyArgument(self, ctx, name, first);
    if (self.calleeIn(ctx, name, t.wall_clocks)) |m| if (self.parentOf(ctx.node)) |parent| {
        if (self.index.marks(parent, self.v.arith_difference)) {
            _ = try self.report(ctx.node, "wall-clock-duration", try self.say("'{s}' reads the wall clock, which jumps when the clock is set, so this difference can be negative or wildly wrong.", .{m}));
        }
    };
    if (self.calleeIn(ctx, name, t.log_calls) != null or self.calleeIn(ctx, name, t.error_calls) != null) try checkLoggedSecret(self, ctx, at);
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
}

/// A call that runs code no one can review: a bare builtin such as Python's `compile(source, ...)`,
/// or a method that evaluates code on any receiver, such as `obj.eval()`. `re.compile` is neither,
/// and nor is `getattr(obj, 'name')`, whose attribute is named in the source.
pub fn checkForbiddenCall(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} for a forbidden call, but it is a {t}; call checkForbiddenCall() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    const forbidden = if (ctx.receiver == null) self.tables.forbidden_calls else self.tables.forbidden_methods;
    if (!contains(forbidden, name)) return;
    const attribute = ctx.receiver == null and contains(self.tables.attribute_calls, name);
    if (attribute and literalName(self, ctx.arguments[1])) return;
    if (!try self.report(ctx.callee orelse ctx.name.?, "forbidden-call", try self.say("Calling '{s}' runs code that can't be reviewed or checked before it runs.", .{name}))) return;
    self.s.diagnostics.last().?.fix = if (attribute)
        try self.say("The attribute's name here comes from a value; look it up in a dict of the attributes you allow, or call '{s}' with the name written out.", .{name})
    else if (std.mem.eql(u8, name, "globals") or std.mem.eql(u8, name, "locals"))
        try self.say("Pass the values the code needs explicitly instead of reading '{s}()'.", .{name})
    else
        try self.say("Parse the input as data, such as JSON, or map each allowed name to the code it runs, instead of running it with '{s}'.", .{name});
}

/// Whether `argument` is a string literal holding a plain name, such as `"headers"`.
fn literalName(self: *File, argument: ?ts.Node) bool {
    const node = argument orelse return false;
    const text = node.text(self.source);
    if (ts.ts_node_start_byte(node) > ts.ts_node_end_byte(node)) assert.panic("{s}: the argument {f} runs backwards; pass a node from a live tree", .{ self.work.facts.path, node.where() });
    if (text.len < 3) return false;
    const quote = text[0];
    if ((quote != '"' and quote != '\'') or text[text.len - 1] != quote) return false;
    for (text[1 .. text.len - 1]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: the argument {f} ends past the file; pass a node from this file", .{ self.work.facts.path, node.where() });
    return true;
}

/// A shell command line or SQL text built from values at runtime.
fn checkRiskyArgument(self: *File, ctx: Context, name: []const u8, first: ts.Node) !void {
    if (ts.ts_node_start_byte(first) < ts.ts_node_start_byte(ctx.node)) assert.panic("{s}: the argument {f} starts before the call {f} it belongs to, so the language's query linked it to the wrong call; in that language's zanity.scm, move the argument's capture (@call.argument) inside the pattern for the call itself (@call.outer)", .{ self.work.facts.path, first.where(), ctx.node.where() });
    const built = self.index.marks(first, self.v.string_built) or self.index.marks(first, self.v.string_format);
    const literal = self.index.marks(first, self.v.literal_string) and !self.index.marks(first, self.v.string_format);
    if (self.calleeIn(ctx, name, self.tables.shell_calls)) |m| if (!literal) {
        _ = try self.report(ctx.callee orelse ctx.name.?, "shell-command", try self.say("'{s}' runs '{s}' through a shell, so a crafted value in it can run other commands.", .{ m, header(first.text(self.source)) }));
    };
    if (ctx.receiver != null and contains(self.tables.sql_methods, name) and built) {
        _ = try self.report(first, "sql-built-from-strings", try self.say("This SQL is built from strings at runtime, so a value containing a quote can change the query: '{s}'.", .{header(first.text(self.source))}));
    }
    if (built and literal and !self.index.marks(first, self.v.string_format)) assert.panic("{s}: {f} is treated both as fixed text and as text put together at runtime, which can't both be true, so the language's query marks it twice; in that language's zanity.scm, keep only one of its two captures (@literal.string for fixed text, @string.built for text built at runtime)", .{ self.work.facts.path, first.where() });
}

/// Reports a logged value whose name says it is a secret, such as `token` or `db_password`.
pub fn checkLoggedSecret(self: *File, ctx: Context, callee: ts.Node) !void {
    const start = ts.ts_node_end_byte(callee);
    const end = ts.ts_node_end_byte(ctx.node);
    if (start > end) assert.panic("{s}: the callee {f} ends after its call {f}; capture @call.name inside @call.outer in the language's zanity.scm", .{ self.work.facts.path, callee.where(), ctx.node.where() });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != self.v.expression_path) continue;
        const text = t.node.text(self.source);
        if (!namesSecret(text)) continue;
        _ = try self.report(t.node, "secret-in-log", try self.say("'{s}' is written to a log or the console, where anyone who can read the output can read the secret.", .{text}));
        return;
    }
    if (first > self.index.triples.len) assert.panic("{s}: the arguments of {f} start at capture {d} of {d}; take the start from lowerBound over the recorded captures", .{ self.work.facts.path, ctx.node.where(), first, self.index.triples.len });
}

/// Reports a branch or loop nested deeper than `rules.max_nesting`, once per function.
pub fn checkNesting(self: *File, node: ts.Node, chained: bool) !void {
    const items = self.s.contexts.items();
    if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
    var depth: u32 = @intFromBool(!chained);
    var i = items.len;
    const function = while (i > 0) {
        i -= 1;
        const ctx = &items[i];
        if (ctx.family == .function or ctx.family == .class or ctx.family == .@"test") break ctx;
        if (ctx.family == .control and !ctx.chained) depth += 1;
    } else null;
    if (depth > items.len + 1) assert.panic("{s}: {f} counted {d} levels among {d} open constructs; checkNesting() must count at most one level per open construct", .{ self.work.facts.path, node.where(), depth, items.len });
    const owner = function orelse return;
    if (depth <= rules.max_nesting or owner.nesting_reported) return;
    owner.nesting_reported = true;
    _ = try self.report(node, "deep-nesting", try self.say("'{s}' is nested {d} levels deep; past {d}, a reader has to hold every enclosing condition in mind at once.", .{ header(node.text(self.source)), depth, rules.max_nesting }));
}

/// Calls made as a statement to something asynchronous: this file's async functions, called bare
/// or on `self`, or the language's own awaitables. Their result is dropped, so the work may never run.
pub fn checkUnawaited(self: *File) !void {
    const names = self.s.async_names.items();
    if (names.len > self.s.async_names.capacity()) assert.panic("{s}: {d} async names in room for {d}; raise memory.Limits.per_file, or split the file", .{ self.work.facts.path, names.len, self.s.async_names.capacity() });
    for (self.s.statement_calls.items()) |callee| {
        const text = callee.text(self.source);
        const dot = std.mem.lastIndexOfScalar(u8, text, '.');
        const own = if (dot) |d| contains(self.tables.self_receivers, text[0..d]) else true;
        const last = text[if (dot) |d| d + 1 else 0..];
        if (!(own and contains(names, last)) and !contains(self.tables.async_calls, text)) continue;
        _ = try self.report(callee, "unawaited-call", try self.say("'{s}' is asynchronous and its result is dropped here, so the work may never run and its errors go unseen.", .{text}));
    }
    if (self.s.contexts.len != 0) assert.panic("{s}: checking unawaited calls with {d} constructs still open; call checkUnawaited() after walk() has closed every construct", .{ self.work.facts.path, self.s.contexts.len });
}

pub fn checkLength(self: *File, root: ts.Node) !void {
    var lines: u32 = 0;
    for (self.code_lines) |is_code| lines += @intFromBool(is_code);
    if (lines > self.code_lines.len) assert.panic("{s}: counted {d} code lines among {d}; code_lines must hold one flag per line of this file", .{ self.work.facts.path, lines, self.code_lines.len });
    if (lines <= rules.max_file_lines) return;
    _ = try self.report(root, "long-file", try self.say("This file has {d} lines of code; past {d}, it is hard to find things in or to hold in mind.", .{ lines, rules.max_file_lines }));
    if (lines == 0) assert.panic("{s}: reported a long file with no code; checkLength() must report only past rules.max_file_lines", .{self.work.facts.path});
}

/// Reports a finding a query captured as `@finding.<rule>`, with the rule's message about the code.
pub fn patternFinding(self: *File, node: ts.Node, rule_name: []const u8) !void {
    const rule = rules.find(rule_name) orelse assert.panic("expected @finding.{s} to name a rule, got no such rule; add the rule to rules.all, or fix the capture's name in the language's zanity.scm", .{rule_name});
    if (rule.pattern.len == 0) assert.panic("expected rule {s} to have a pattern message for @finding captures, got none; give it a .pattern in rules.all, with $code where the code goes", .{rule.name});
    if (self.index.marks(node, self.v.comment)) return;
    if (try cancelled(self, node, rule.name)) return;
    const code = header(node.text(self.source));
    const text = self.work.text;
    const start = text.used;
    var parts = std.mem.splitSequence(u8, rule.pattern, "$code");
    _ = try text.copy(parts.first());
    while (parts.next()) |part| {
        _ = try text.copy(code);
        _ = try text.copy(part);
    }
    const message = text.buffer[start..text.used];
    if (message.len < rule.pattern.len - "$code".len) assert.panic("expected the message to hold the pattern, got '{s}' for '{s}'; patternFinding() must copy every part of the pattern, so check its loop", .{ message, rule.pattern });
    const reported = try self.report(node, rule.name, message);
    if (reported and std.mem.eql(u8, rule.name, "precedence-trap")) self.s.diagnostics.last().?.fix = try groupingFix(self, node);
}

const comparisons = [_][]const u8{ "==", "===", "!=", "!==", "<", ">", "<=", ">=" };
const bitwise = [_][]const u8{ "&", "|", "^" };

/// An operand of a binary or unary expression, and the operator text before it.
const Operand = struct { node: ts.Node, operator: []const u8 };

/// The operator and operands of `node` when it is a binary operation, read from the text between
/// its two named children.
fn binaryParts(self: *File, node: ts.Node) ?struct { left: ts.Node, operator: []const u8, right: ts.Node } {
    if (ts.ts_node_named_child_count(node) != 2) return null;
    const left = ts.ts_node_named_child(node, 0);
    const right = ts.ts_node_named_child(node, 1);
    if (ts.ts_node_end_byte(left) > ts.ts_node_start_byte(right)) assert.panic("{s}: the operands of {f} overlap, ending at {d} and starting at {d}; named children come in source order", .{ self.work.facts.path, node.where(), ts.ts_node_end_byte(left), ts.ts_node_start_byte(right) });
    const operator = std.mem.trim(u8, self.source[ts.ts_node_end_byte(left)..ts.ts_node_start_byte(right)], " \t\r\n");
    if (operator.len == 0 or operator.len > 3) return null;
    if (std.mem.indexOfAny(u8, operator, " \t\r\n") != null) assert.panic("{s}: read the operator of {f} as '{s}', with whitespace inside; trim only its ends", .{ self.work.facts.path, node.where(), operator });
    return .{ .left = left, .operator = operator, .right = right };
}

/// The operand of `node` when it is a prefix operation such as `!a`.
fn prefixPart(self: *File, node: ts.Node) ?Operand {
    if (ts.ts_node_named_child_count(node) != 1) return null;
    const operand = ts.ts_node_named_child(node, 0);
    if (ts.ts_node_start_byte(operand) < ts.ts_node_start_byte(node)) assert.panic("{s}: the operand of {f} starts before it; a child lies inside its parent", .{ self.work.facts.path, node.where() });
    const operator = std.mem.trim(u8, self.source[ts.ts_node_start_byte(node)..ts.ts_node_start_byte(operand)], " \t");
    if (operator.len == 0) return null;
    if (operator.len > 3) assert.panic("{s}: read a {d}-byte prefix operator '{s}' before the operand of {f}; a prefix operator is at most 3 bytes, so the operand must start right after it", .{ self.work.facts.path, operator.len, operator, node.where() });
    if (ts.ts_node_end_byte(operand) != ts.ts_node_end_byte(node)) return null;
    return .{ .node = operand, .operator = operator };
}

/// How a precedence trap actually groups, with parentheses, and the grouping it reads as, so the
/// reader can write whichever they meant: `!a == b` runs as `(!a) == b` and reads as `!(a == b)`;
/// `a & b == c` runs as `a & (b == c)` and reads as `(a & b) == c`.
fn groupingFix(self: *File, node: ts.Node) ![]const u8 {
    const parts = binaryParts(self, node) orelse return "";
    if (ts.ts_node_start_byte(parts.left) != ts.ts_node_start_byte(node)) assert.panic("{s}: the precedence trap {f} does not start with its left operand; the query captures the whole binary expression", .{ self.work.facts.path, node.where() });
    const left = parts.left.text(self.source);
    const right = parts.right.text(self.source);
    const op = parts.operator;
    if (strings.contains(&comparisons, op)) {
        const negated = prefixPart(self, parts.left) orelse return "";
        return self.say("It runs as `({s}) {s} {s}`; if you meant `{s}({s} {s} {s})`, write that, and otherwise write the parentheses it runs with.", .{ left, op, right, negated.operator, negated.node.text(self.source), op, right });
    }
    if (!strings.contains(&bitwise, op)) assert.panic("{s}: a precedence trap at {f} has the operator '{s}', which is neither a comparison nor a bitwise operator; the language's zanity.scm captures only those, so check binaryParts()", .{ self.work.facts.path, node.where(), op });
    const inner_right = binaryParts(self, parts.right);
    const inner_left = binaryParts(self, parts.left);
    const right_compares = if (inner_right) |r| strings.contains(&comparisons, r.operator) else false;
    const left_compares = if (inner_left) |l| strings.contains(&comparisons, l.operator) else false;
    if (right_compares and !left_compares) {
        const r = inner_right.?;
        return self.say("It runs as `{s} {s} ({s})`; if you meant `({s} {s} {s}) {s} {s}`, write that, and otherwise write the parentheses it runs with.", .{ left, op, right, left, op, r.left.text(self.source), r.operator, r.right.text(self.source) });
    }
    if (left_compares and !right_compares) {
        const l = inner_left.?;
        return self.say("It runs as `({s}) {s} {s}`; if you meant `{s} {s} ({s} {s} {s})`, write that, and otherwise write the parentheses it runs with.", .{ left, op, right, l.left.text(self.source), l.operator, l.right.text(self.source), op, right });
    }
    return self.say("It runs as `({s}) {s} ({s})`; write the parentheses it runs with, or the grouping you meant.", .{ left, op, right });
}

/// The node inside `node` that spans all of it, such as the one value in a one-item list.
pub fn soleChild(node: ts.Node) ts.Node {
    if (node.id == null) assert.panic("looked inside a null node; pass the value node an assignment captured", .{});
    var current = node;
    for (0..8) |_| {
        if (ts.ts_node_named_child_count(current) != 1) break;
        const child = ts.ts_node_named_child(current, 0);
        if (ts.ts_node_start_byte(child) != ts.ts_node_start_byte(current) or ts.ts_node_end_byte(child) != ts.ts_node_end_byte(current)) break;
        current = child;
    }
    if (ts.ts_node_start_byte(current) != ts.ts_node_start_byte(node)) assert.panic("expected the sole child to start where its parent does, got {d} and {d}; soleChild() must descend only into a child spanning the whole node", .{ ts.ts_node_start_byte(current), ts.ts_node_start_byte(node) });
    return current;
}

/// Whether a name ends in a secret's name, such as `db_password`, `apiKey` or `self.token`.
pub fn namesSecret(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is a secret's; skip empty names before calling namesSecret()", .{});
    const last = name[if (std.mem.lastIndexOfAny(u8, name, ".:>")) |at| at + 1 else 0..];
    var squeezed: [64]u8 = undefined;
    var len: usize = 0;
    for (last) |c| {
        if (c == '_' or c == '-') continue;
        if (len == squeezed.len) return false;
        squeezed[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (len > squeezed.len) assert.panic("squeezed '{s}' into {d} bytes of {d}; namesSecret() must stop at the buffer's end", .{ name, len, squeezed.len });
    for (rules.secret_names) |word| {
        if (!std.mem.endsWith(u8, squeezed[0..len], word)) continue;
        // A bare `token` is as often a parser's token as a credential; `api_token` is not.
        if (std.mem.eql(u8, word, "token") and len == word.len) return false;
        return true;
    }
    return false;
}

pub fn startsBefore(start: u32, t: captures.Triple) std.math.Order {
    if (t.key.id == 0) assert.panic("a recorded capture at byte {d} has no node id; index() must skip null nodes when it records captures", .{t.key.start});
    const order = std.math.order(start, t.key.start);
    if ((order == .lt) != (start < t.key.start)) assert.panic("ordered byte {d} {t} the capture at byte {d}; compare `start` with the capture's start byte, in that order", .{ start, order, t.key.start });
    return order;
}
