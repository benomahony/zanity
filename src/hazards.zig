//! Checks that trace to the engineering error catalogue: query-captured findings with their
//! `@unless` exceptions, risky calls, which checkRiskyCall also hands to crypto.zig,
//! parser_hazards.zig, parameter_sinks.zig and secrets.zig, and comments, nesting, unawaited
//! calls and file length.
const std = @import("std");
const secrets = @import("secrets.zig");
const checkLoggedSecret = secrets.checkLoggedSecret;
const checkLiteralNetworkEndpoint = secrets.checkLiteralNetworkEndpoint;
const parser_hazards = @import("parser_hazards.zig");
const checkXmlEntityExpansion = parser_hazards.checkXmlEntityExpansion;
const checkNestedRegexQuantifier = parser_hazards.checkNestedRegexQuantifier;
const crypto = @import("crypto.zig");
const checkConstantSeed = crypto.checkConstantSeed;
const checkConstantCbcIv = crypto.checkConstantCbcIv;
const checkConstantAeadNonce = crypto.checkConstantAeadNonce;
const checkConstantPasswordSalt = crypto.checkConstantPasswordSalt;
const checkRsaWithoutOaep = crypto.checkRsaWithoutOaep;
const parameter_sinks = @import("parameter_sinks.zig");
const checkDirectParameterSinks = parameter_sinks.checkDirectParameterSinks;
const directFunctionParameter = parameter_sinks.directFunctionParameter;
const checkWindowOpener = parameter_sinks.checkWindowOpener;
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const header = check.header;
const strings = @import("strings.zig");

/// Conventional defect markers in comments, and comments that turn another tool's check off on
/// their line, such as a linter's ignore marker from the language's tables. The defect markers are
/// exact uppercase tokens, deliberately narrower than prose containing words such as "debug".
pub fn checkComments(self: *File) !void {
    const defects: []const []const u8 = if (self.checker.enabled.enabled("suspicious-comment")) &defect_markers else &.{};
    const switches = if (self.checker.enabled.enabled("relaxed-check")) self.tables.suppression_markers else &.{};
    if (defects.len + switches.len == 0) return;
    const comment = self.v.comment orelse return;
    if (comment >= self.checker.compiled.captureCount()) assert.panic("comment capture {d} is outside the query's {d} captures; build the vocabulary from this checker", .{ comment, self.checker.compiled.captureCount() });
    var reported: usize = 0;
    for (self.index.triples) |t| {
        if (t.id != comment) continue;
        const text = t.node.text(self.source);
        if (markerIn(text, defects, false)) |marker| {
            reported += 1;
            _ = try self.report(t.node, "suspicious-comment", try self.say("This comment contains the defect marker '{s}', saying the code is broken or unfinished.", .{marker}));
        }
        const off = markerIn(text, switches, true) orelse continue;
        reported += 1;
        _ = try self.report(t.node, "relaxed-check", try self.say("This comment's '{s}' turns a check off here, so a problem it should catch passes.", .{off}));
    }
    if (reported > 2 * self.index.triples.len) assert.panic("reported {d} comment findings among {d} captures; each comment reports at most one of each rule", .{ reported, self.index.triples.len });
}

const defect_markers = [_][]const u8{ "FIXME", "XXX", "BUG" };

/// Bytes that join a marker into a longer name when they touch it: letters, digits and `_`.
const word_bytes = blk: {
    var set: std.StaticBitSet(256) = .empty;
    for (0..256) |c| if (std.ascii.isAlphanumeric(c) or c == '_') set.set(c);
    break :blk set;
};

/// The first of `markers` that `text` holds as a whole word, not inside a longer name.
fn markerIn(text: []const u8, markers: []const []const u8, ignore_case: bool) ?[]const u8 {
    if (text.len == 0) assert.panic("checking an empty comment for a marker; comment nodes include their delimiter", .{});
    for (markers) |marker| {
        if (marker.len == 0) assert.panic("looking for an empty comment marker; every marker must name visible text", .{});
        for (0..text.len) |at| {
            const rest = text[at..];
            const hit = if (ignore_case) std.ascii.startsWithIgnoreCase(rest, marker) else std.mem.startsWith(u8, rest, marker);
            if (!hit) continue;
            const end = at + marker.len;
            const joined_before = at > 0 and word_bytes.isSet(text[at - 1]) and word_bytes.isSet(marker[0]);
            const joined_after = end < text.len and word_bytes.isSet(text[end]) and word_bytes.isSet(marker[marker.len - 1]);
            if (!joined_before and !joined_after) return marker;
        }
    }
    return null;
}

/// Whether a node captured `@unless.<rule>` sits inside `node` and belongs to it rather than to
/// a nested finding of the same rule, like the default case of this switch and not an inner one.
pub fn cancelled(self: *File, node: ts.Node, rule: []const u8) !bool {
    if (rule.len == 0) assert.panic("{s}: asked whether {f} is excused from a rule with no name; pass the rule's name", .{ self.work.facts.path, node.where() });
    var name_buffer: [96]u8 = undefined;
    const unless = self.checker.compiled.id(try std.fmt.bufPrint(&name_buffer, "unless.{s}", .{rule})) orelse return false;
    const finding = self.checker.compiled.id(try std.fmt.bufPrint(&name_buffer, "finding.{s}", .{rule})) orelse assert.panic("{s}: {f} was reported as {s}, but the query has no @finding.{s}; add @finding.<rule> to the language's zanity.scm, or report the rule without cancelled()", .{ self.work.facts.path, node.where(), rule, rule });
    const barrier = self.checker.compiled.id("declaration.barrier");
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, captures.startsBefore);
    const scoped_contract = cancellationIsScopeBound(rule);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != unless or ts.ts_node_end_byte(t.node) > end) continue;
        if (cancellationBelongs(self, .{ .finding_node = node, .unless_node = t.node, .finding = finding, .barrier = barrier, .scoped = scoped_contract })) return true;
    }
    if (first > self.index.triples.len) assert.panic("{s}: the captures inside {f} start at {d}, past the {d} recorded; take the start from lowerBound over the recorded captures", .{ self.work.facts.path, node.where(), first, self.index.triples.len });
    return false;
}

/// Whether `rule` is a contract between methods, such as equals without hashCode, whose
/// `@unless` excuse counts only inside the finding's own declaration, up to a `@declaration.barrier`.
fn cancellationIsScopeBound(rule: []const u8) bool {
    if (rule.len == 0) assert.panic("checking cancellation scope for an empty rule; cancelled rejects it first", .{});
    const contracts = [_][]const u8{ "missing-super-finalizer", "missing-super-clone", "equals-without-hashcode", "hashcode-without-equals" };
    if (contracts.len == 0) assert.panic("no scope-bound contracts; remove this helper and its barrier walk", .{});
    return strings.contains(&contracts, rule);
}

const Cancellation = struct { finding_node: ts.Node, unless_node: ts.Node, finding: captures.Id, barrier: ?captures.Id, scoped: bool };

fn cancellationBelongs(self: *File, c: Cancellation) bool {
    if (ts.ts_node_start_byte(c.unless_node) < ts.ts_node_start_byte(c.finding_node)) assert.panic("cancellation {f} starts before its finding {f}; pass a descendant", .{ c.unless_node.where(), c.finding_node.where() });
    if (ts.ts_node_end_byte(c.unless_node) > ts.ts_node_end_byte(c.finding_node)) assert.panic("cancellation {f} ends after its finding {f}; pass a descendant", .{ c.unless_node.where(), c.finding_node.where() });
    var current = self.parentOf(c.unless_node);
    var first_barrier_parent: ?ts.Node = null;
    const owner = while (current) |candidate| : (current = self.parentOf(candidate)) {
        if (self.index.marks(candidate, c.finding)) break candidate;
        if (first_barrier_parent == null and self.index.marks(candidate, c.barrier)) first_barrier_parent = self.parentOf(candidate);
    } else return false;
    if (!owner.eql(c.finding_node)) return false;
    if (!c.scoped) return true;
    return if (first_barrier_parent) |parent| parent.eql(owner) else true;
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
    if (self.calleeIn(ctx, name, t.weak_randoms)) |m| {
        _ = try self.report(at, "weak-random", try self.say("'{s}' is a predictable pseudo-random generator, so its output cannot safely choose secrets, tokens, nonces or security outcomes.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.unsafe_deserializers)) |m| {
        _ = try self.report(at, "unsafe-deserialization", try self.say("'{s}' can run code chosen by whoever wrote the data it reads.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.insecure_temp_calls)) |m| {
        _ = try self.report(at, "insecure-temp-file", try self.say("'{s}' chooses a temporary name before opening it, so another process can create or replace the path first.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.process_exit_calls)) |m| {
        _ = try self.report(at, "process-exit", try self.say("'{s}' stops the whole process, so callers cannot recover or finish cleanup.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.obsolete_calls)) |m| {
        _ = try self.report(at, "obsolete-call", try self.say("'{s}' is an obsolete API retained only for compatibility and can disappear or preserve outdated behaviour.", .{m}));
    }
    if (ctx.receiver != null and contains(t.explicit_finalizer_methods, name)) {
        _ = try self.report(at, "explicit-finalizer", try self.say("'{s}' invokes a finalizer directly, so the runtime can finalize the object again or observe an invalid lifetime.", .{name}));
    }
    if (ctx.arguments[0]) |first| try checkRiskyArgument(self, ctx, name, first);
    try checkConstantCbcIv(self, ctx, name);
    try checkConstantAeadNonce(self, ctx, name);
    try checkConstantPasswordSalt(self, ctx, name);
    try checkRsaWithoutOaep(self, ctx, name);
    try checkXmlEntityExpansion(self, ctx, name);
    try checkMissingIntegerRadix(self, ctx, name);
    try checkWindowOpener(self, ctx, name);
    try checkDirectParameterSinks(self, ctx, name);
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
    const first_text = first.text(self.source);
    const first_shown = header(first_text);
    const built = self.index.marks(first, self.v.string_built) or self.index.marks(first, self.v.string_format);
    const literal = self.index.marks(first, self.v.literal_string) and !self.index.marks(first, self.v.string_format);
    try checkConstantSeed(self, ctx, name, first);
    try checkNestedRegexQuantifier(self, ctx, name, first);
    if (self.calleeIn(ctx, name, self.tables.shell_calls)) |m| if (!literal) {
        _ = try self.report(ctx.callee orelse ctx.name.?, "shell-command", try self.say("'{s}' runs '{s}' through a shell, so a crafted value in it can run other commands.", .{ m, first_shown }));
    };
    if (ctx.receiver != null and contains(self.tables.sql_methods, name) and built) {
        _ = try self.report(first, "sql-built-from-strings", try self.say("This SQL is built from strings at runtime, so a value containing a quote can change the query: '{s}'.", .{first_shown}));
    }
    const network = self.calleeIn(ctx, name, self.tables.network_calls) != null;
    if (network and directFunctionParameter(self, first)) {
        _ = try self.report(first, "parameter-network-target", try self.say("Function parameter '{s}' flows directly into a server-side network target, so a caller can choose the scheme, host or port.", .{first_text}));
    }
    if (literal and network) try checkLiteralNetworkEndpoint(self, first);
    if (built and literal and !self.index.marks(first, self.v.string_format)) assert.panic("{s}: {f} is treated both as fixed text and as text put together at runtime, which can't both be true, so the language's query marks it twice; in that language's zanity.scm, keep only one of its two captures (@literal.string for fixed text, @string.built for text built at runtime)", .{ self.work.facts.path, first.where() });
}

fn checkMissingIntegerRadix(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking an integer radix in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking an integer radix for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const matched = self.calleeIn(ctx, name, self.tables.integer_parse_calls) orelse return;
    if (ctx.argument_count != 1) return;
    const input = ctx.arguments[0] orelse assert.panic("{s}: '{s}' counted one argument but did not retain it; @call.argument must capture the argument expression", .{ self.work.facts.path, matched });
    _ = try self.report(input, "missing-integer-radix", try self.say("'{s}' parses this text without an explicit radix, so prefixes can change how the number is interpreted.", .{matched}));
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
    try recordFile(self, root);
    var lines: u32 = 0;
    for (self.code_lines) |is_code| lines += @intFromBool(is_code);
    if (lines > self.code_lines.len) assert.panic("{s}: counted {d} code lines among {d}; code_lines must hold one flag per line of this file", .{ self.work.facts.path, lines, self.code_lines.len });
    if (lines <= rules.max_file_lines) return;
    _ = try self.report(root, "long-file", try self.say("This file has {d} lines of code; past {d}, it is hard to find things in or to hold in mind.", .{ lines, rules.max_file_lines }));
    if (lines == 0) assert.panic("{s}: reported a long file with no code; checkLength() must report only past rules.max_file_lines", .{self.work.facts.path});
}

/// Records the whole file as a unit for --infer, for questions no single function shows, such as
/// what a module imports or how it is laid out.
pub fn recordFile(self: *File, root: ts.Node) !void {
    const facts = self.work.facts;
    if (!facts.collect_units or self.source.len == 0) return;
    const last = ts.ts_node_end_point(root).row;
    if (ts.ts_node_end_byte(root) > self.source.len) assert.panic("{s}: the tree ends at byte {d} of {d}", .{ facts.path, ts.ts_node_end_byte(root), self.source.len });
    if (facts.path.len == 0) assert.panic("recording a file with no path; set facts.path before walking it", .{});
    try facts.unit(std.fs.path.basename(facts.path), self.source, .{ .kind = .file, .reports_error = false, .at = .{ 0, 0, last } });
}

/// Reports a finding a query captured as `@finding.<rule>`, with the rule's message about the code.
pub fn patternFinding(self: *File, node: ts.Node, rule_name: []const u8) !void {
    const rule = rules.find(rule_name) orelse assert.panic("expected @finding.{s} to name a rule, got no such rule; add the rule to rules.all, or fix the capture's name in the language's zanity.scm", .{rule_name});
    if (rule.pattern.len == 0) assert.panic("expected rule {s} to have a pattern message for @finding captures, got none; give it a .pattern in rules.all, with $code where the code goes", .{rule.name});
    if (self.index.marks(node, self.v.comment)) return;
    if (try cancelled(self, node, rule.name)) return;
    const specific = if (std.mem.eql(u8, rule.name, "opaque-check")) (try specificCheck(self, node)) orelse return else null;
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
    if (reported) if (specific) |fix| {
        self.s.diagnostics.last().?.fix = fix;
    };
}

/// The specific check the language offers for a yes/no check of a comparison or method, written
/// out with its two sides, or null when it offers none, so the yes/no check is the best there is.
fn specificCheck(self: *File, node: ts.Node) !?[]const u8 {
    const key = self.index.within(node, self.v.opaque_key) orelse return null;
    const left = self.index.within(node, self.v.opaque_left) orelse return null;
    const right = self.index.within(node, self.v.opaque_right) orelse return null;
    if (ts.ts_node_start_byte(left) >= ts.ts_node_start_byte(right)) assert.panic("{s}: the left side {f} of the check {f} starts after its right side {f}; capture @opaque.left before @opaque.right in the language's zanity.scm", .{ self.work.facts.path, left.where(), node.where(), right.where() });
    const negated = self.index.marks(node, self.v.opaque_negated);
    const when = key.text(self.source);
    if (when.len == 0) assert.panic("{s}: @opaque.key matched the empty {f}; capture the operator or method name of the check {f}", .{ self.work.facts.path, key.where(), node.where() });
    for (self.tables.specific_checks) |specific| {
        if (!std.mem.eql(u8, specific.when, when)) continue;
        const template = if (negated) specific.negated else specific.check;
        if (template.len == 0) return null;
        return try writeCheck(self, template, left.text(self.source), right.text(self.source));
    }
    return null;
}

/// "Write it as `<check>`", with the template's `$1` and `$2` replaced by the two sides.
fn writeCheck(self: *File, template: []const u8, left: []const u8, right: []const u8) ![]const u8 {
    const text = self.work.text;
    const start = text.used;
    _ = try text.copy("Write it as `");
    var rest = template;
    for (0..template.len) |_| {
        const at = std.mem.indexOfScalar(u8, rest, '$') orelse break;
        if (at + 1 >= rest.len or (rest[at + 1] != '1' and rest[at + 1] != '2')) assert.panic("the specific check '{s}' has a '$' not followed by 1 or 2; write the sides as $1 and $2 in languages/tables.zon", .{template});
        _ = try text.copy(rest[0..at]);
        _ = try text.copy(if (rest[at + 1] == '1') left else right);
        rest = rest[at + 2 ..];
    }
    _ = try text.copy(rest);
    _ = try text.copy("`, which shows both values when it fails.");
    const fix = text.buffer[start..text.used];
    if (fix.len < template.len) assert.panic("the fix '{s}' is shorter than its template '{s}'; writeCheck() must copy every part of the template", .{ fix, template });
    return fix;
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
