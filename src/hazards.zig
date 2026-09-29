//! Checks that trace to the engineering error catalogue: query-captured findings with their
//! `@unless` exceptions, and risky calls, secrets, nesting, unawaited calls and file length.
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
const rewrite = @import("rewrite.zig");

/// A string literal assigned to a name that ends in a secret's name, such as `db_password` or `apiKey`.
/// Test code and values shaped like an environment variable's name are left alone.
pub fn checkSecret(self: *File, node: ts.Node, lhs: ts.Node, assigned: ts.Node) !void {
    if (ts.ts_node_end_byte(lhs) > ts.ts_node_start_byte(assigned)) std.debug.panic("{s}: the assigned name {f} overlaps its value {f}; the query captured the wrong nodes", .{ self.work.facts.path, lhs.where(), assigned.where() });
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
    if (env_name) return;
    _ = try self.report(node, "hardcoded-secret", try self.say("'{s}' is set to a secret written into the source, so the secret is in version control and in every copy of the code.", .{target}));
    if (value.len == 0) std.debug.panic("{s}: reported the empty value of '{s}' as a secret", .{ self.work.facts.path, target });
}

/// Whether a node captured `@unless.<rule>` sits inside `node` and belongs to it rather than to
/// a nested finding of the same rule, like the default case of this switch and not an inner one.
pub fn cancelled(self: *File, node: ts.Node, rule: []const u8) !bool {
    if (rule.len == 0) std.debug.panic("{s}: asked whether {f} is excused from a rule with no name", .{ self.work.facts.path, node.where() });
    var name_buffer: [96]u8 = undefined;
    const unless = self.checker.compiled.id(try std.fmt.bufPrint(&name_buffer, "unless.{s}", .{rule})) orelse return false;
    const finding = self.checker.compiled.id(try std.fmt.bufPrint(&name_buffer, "finding.{s}", .{rule})) orelse std.debug.panic("{s}: {f} was reported as {s}, but the query has no @finding.{s}", .{ self.work.facts.path, node.where(), rule, rule });
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != unless or ts.ts_node_end_byte(t.node) > end) continue;
        var current = t.node.parent();
        const owner = while (current) |c| : (current = c.parent()) {
            if (self.index.marks(c, finding)) break c;
        } else null;
        if (owner) |o| if (o.eql(node)) return true;
    }
    if (first > self.index.triples.len) std.debug.panic("{s}: the captures inside {f} start at {d}, past the {d} recorded", .{ self.work.facts.path, node.where(), first, self.index.triples.len });
    return false;
}

/// Calls whose name alone makes them risky, or whose arguments do: weak hashes, unsafe
/// deserializers, shell command lines and SQL built at runtime, secrets written to logs, and
/// wall-clock reads used to time a duration.
pub fn checkRiskyCall(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) std.debug.panic("{s}: checking {f} as a risky call, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const t = self.tables;
    const at = ctx.callee orelse ctx.name.?;
    if (self.calleeIn(ctx, name, t.weak_hashes)) |m| {
        _ = try self.report(at, "weak-hash", try self.say("'{s}' is a broken hash: collisions can be forged, so it can't protect passwords, signatures or integrity.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.unsafe_deserializers)) |m| {
        _ = try self.report(at, "unsafe-deserialization", try self.say("'{s}' can run code chosen by whoever wrote the data it reads.", .{m}));
    }
    if (ctx.arguments[0]) |first| try checkRiskyArgument(self, ctx, name, first);
    if (self.calleeIn(ctx, name, t.wall_clocks)) |m| if (ctx.node.parent()) |parent| {
        if (self.index.marks(parent, self.v.arith_difference)) {
            _ = try self.report(ctx.node, "wall-clock-duration", try self.say("'{s}' reads the wall clock, which jumps when the clock is set, so this difference can be negative or wildly wrong.", .{m}));
        }
    };
    if (self.calleeIn(ctx, name, t.log_calls) != null or self.calleeIn(ctx, name, t.error_calls) != null) try checkLoggedSecret(self, ctx, at);
    if (name.len == 0) std.debug.panic("{s}: the call {f} has an empty name", .{ self.work.facts.path, ctx.node.where() });
}

/// A shell command line or SQL text built from values at runtime.
fn checkRiskyArgument(self: *File, ctx: Context, name: []const u8, first: ts.Node) !void {
    if (ts.ts_node_start_byte(first) < ts.ts_node_start_byte(ctx.node)) std.debug.panic("{s}: the argument {f} starts before its call {f}", .{ self.work.facts.path, first.where(), ctx.node.where() });
    const built = self.index.marks(first, self.v.string_built) or self.index.marks(first, self.v.string_format);
    const literal = self.index.marks(first, self.v.literal_string) and !self.index.marks(first, self.v.string_format);
    if (self.calleeIn(ctx, name, self.tables.shell_calls)) |m| if (!literal) {
        _ = try self.report(ctx.callee orelse ctx.name.?, "shell-command", try self.say("'{s}' runs '{s}' through a shell, so a crafted value in it can run other commands.", .{ m, header(first.text(self.source)) }));
    };
    if (ctx.receiver != null and contains(self.tables.sql_methods, name) and built) {
        _ = try self.report(first, "sql-built-from-strings", try self.say("This SQL is built from strings at runtime, so a value containing a quote can change the query: '{s}'.", .{header(first.text(self.source))}));
    }
    if (built and literal and !self.index.marks(first, self.v.string_format)) std.debug.panic("{s}: {f} is both a plain literal and built at runtime", .{ self.work.facts.path, first.where() });
}

/// Reports a logged value whose name says it is a secret, such as `token` or `db_password`.
pub fn checkLoggedSecret(self: *File, ctx: Context, callee: ts.Node) !void {
    const start = ts.ts_node_end_byte(callee);
    const end = ts.ts_node_end_byte(ctx.node);
    if (start > end) std.debug.panic("{s}: the callee {f} ends after its call {f}", .{ self.work.facts.path, callee.where(), ctx.node.where() });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != self.v.expression_path) continue;
        const text = t.node.text(self.source);
        if (!namesSecret(text)) continue;
        _ = try self.report(t.node, "secret-in-log", try self.say("'{s}' is written to a log or the console, where anyone who can read the output can read the secret.", .{text}));
        return;
    }
    if (first > self.index.triples.len) std.debug.panic("{s}: the arguments of {f} start at capture {d} of {d}", .{ self.work.facts.path, ctx.node.where(), first, self.index.triples.len });
}

/// Reports a branch or loop nested deeper than `rules.max_nesting`, once per function.
pub fn checkNesting(self: *File, node: ts.Node, chained: bool) !void {
    const items = self.s.contexts.items();
    if (items.len > self.s.contexts.buffer.len) std.debug.panic("{s}: {d} open constructs in room for {d}", .{ self.work.facts.path, items.len, self.s.contexts.buffer.len });
    var depth: u32 = @intFromBool(!chained);
    var i = items.len;
    const function = while (i > 0) {
        i -= 1;
        if (items[i].family == .function or items[i].family == .class or items[i].family == .@"test") break &items[i];
        if (items[i].family == .control and !items[i].chained) depth += 1;
    } else null;
    if (depth > items.len + 1) std.debug.panic("{s}: {f} counted {d} levels among {d} open constructs", .{ self.work.facts.path, node.where(), depth, items.len });
    const owner = function orelse return;
    if (depth <= rules.max_nesting or owner.nesting_reported) return;
    owner.nesting_reported = true;
    _ = try self.report(node, "deep-nesting", try self.say("'{s}' is nested {d} levels deep; past {d}, a reader has to hold every enclosing condition in mind at once.", .{ header(node.text(self.source)), depth, rules.max_nesting }));
}

/// Calls made as a statement to something asynchronous: this file's async functions, or the
/// language's own awaitables. Their result is dropped, so the work may never run.
pub fn checkUnawaited(self: *File) !void {
    const names = self.s.async_names.items();
    if (names.len > self.s.async_names.buffer.len) std.debug.panic("{s}: {d} async names in room for {d}", .{ self.work.facts.path, names.len, self.s.async_names.buffer.len });
    for (self.s.statement_calls.items()) |callee| {
        const text = callee.text(self.source);
        const last = text[if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| dot + 1 else 0..];
        if (!contains(names, last) and !contains(self.tables.async_calls, text)) continue;
        _ = try self.report(callee, "unawaited-call", try self.say("'{s}' is asynchronous and its result is dropped here, so the work may never run and its errors go unseen.", .{text}));
    }
    if (self.s.contexts.len != 0) std.debug.panic("{s}: checking unawaited calls with {d} constructs still open", .{ self.work.facts.path, self.s.contexts.len });
}

pub fn checkLength(self: *File, root: ts.Node) !void {
    var lines: u32 = 0;
    for (self.code_lines) |is_code| lines += @intFromBool(is_code);
    if (lines > self.code_lines.len) std.debug.panic("{s}: counted {d} code lines among {d}", .{ self.work.facts.path, lines, self.code_lines.len });
    if (lines <= rules.max_file_lines) return;
    _ = try self.report(root, "long-file", try self.say("This file has {d} lines of code; past {d}, it is hard to find things in or to hold in mind.", .{ lines, rules.max_file_lines }));
    if (lines == 0) std.debug.panic("{s}: reported a long file with no code", .{self.work.facts.path});
}

/// Reports a finding a query captured as `@finding.<rule>`, with the rule's message about the code.
pub fn patternFinding(self: *File, node: ts.Node, rule_name: []const u8) !void {
    const rule = rules.find(rule_name) orelse std.debug.panic("expected @finding.{s} to name a rule, got no such rule", .{rule_name});
    if (rule.pattern.len == 0) std.debug.panic("expected rule {s} to have a pattern message for @finding captures, got none", .{rule.name});
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
    if (message.len < rule.pattern.len - "$code".len) std.debug.panic("expected the message to hold the pattern, got '{s}' for '{s}'", .{ message, rule.pattern });
    _ = try self.report(node, rule.name, message);
}

/// The node inside `node` that spans all of it, such as the one value in a one-item list.
pub fn soleChild(node: ts.Node) ts.Node {
    if (node.id == null) std.debug.panic("looked inside a null node; pass the value node an assignment captured", .{});
    var current = node;
    for (0..8) |_| {
        if (ts.ts_node_named_child_count(current) != 1) break;
        const child = ts.ts_node_named_child(current, 0);
        if (ts.ts_node_start_byte(child) != ts.ts_node_start_byte(current) or ts.ts_node_end_byte(child) != ts.ts_node_end_byte(current)) break;
        current = child;
    }
    if (ts.ts_node_start_byte(current) != ts.ts_node_start_byte(node)) std.debug.panic("expected the sole child to start where its parent does, got {d} and {d}", .{ ts.ts_node_start_byte(current), ts.ts_node_start_byte(node) });
    return current;
}

/// Whether a name ends in a secret's name, such as `db_password`, `apiKey` or `self.token`.
pub fn namesSecret(name: []const u8) bool {
    if (name.len == 0) std.debug.panic("asked whether an empty name is a secret's", .{});
    const last = name[if (std.mem.lastIndexOfAny(u8, name, ".:>")) |at| at + 1 else 0..];
    var squeezed: [64]u8 = undefined;
    var len: usize = 0;
    for (last) |c| {
        if (c == '_' or c == '-') continue;
        if (len == squeezed.len) return false;
        squeezed[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (len > squeezed.len) std.debug.panic("squeezed '{s}' into {d} bytes of {d}", .{ name, len, squeezed.len });
    for (rules.secret_names) |word| {
        if (!std.mem.endsWith(u8, squeezed[0..len], word)) continue;
        // A bare `token` is as often a parser's token as a credential; `api_token` is not.
        if (std.mem.eql(u8, word, "token") and len == word.len) return false;
        return true;
    }
    return false;
}

pub fn startsBefore(start: u32, t: captures.Triple) std.math.Order {
    if (t.key.id == 0) std.debug.panic("a recorded capture at byte {d} has no node id", .{t.key.start});
    const order = std.math.order(start, t.key.start);
    if (order == .eq and start != t.key.start) std.debug.panic("byte {d} compared equal to byte {d}", .{ start, t.key.start });
    return order;
}
