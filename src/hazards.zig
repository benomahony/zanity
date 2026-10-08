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

/// Conventional defect markers in comments. These exact uppercase tokens are deliberately
/// narrower than prose containing words such as "debug" or "bugfix".
pub fn checkSuspiciousComments(self: *File) !void {
    if (!self.checker.enabled.enabled("suspicious-comment")) return;
    const comment = self.v.comment orelse return;
    if (comment >= self.checker.compiled.captureCount()) assert.panic("comment capture {d} is outside the query's {d} captures; build the vocabulary from this checker", .{ comment, self.checker.compiled.captureCount() });
    var inspected: usize = 0;
    for (self.index.triples) |t| {
        if (t.id != comment) continue;
        inspected += 1;
        const text = t.node.text(self.source);
        const marker = commentMarker(text) orelse continue;
        _ = try self.report(t.node, "suspicious-comment", try self.say("This comment contains the defect marker '{s}', saying the code is broken or unfinished.", .{marker}));
    }
    if (inspected > self.index.triples.len) assert.panic("inspected {d} comments among {d} captures; count only matching captures", .{ inspected, self.index.triples.len });
}

fn commentMarker(text: []const u8) ?[]const u8 {
    if (text.len == 0) assert.panic("checking an empty comment for a marker; comment nodes include their delimiter", .{});
    const markers = [_][]const u8{ "FIXME", "XXX", "BUG" };
    for (markers) |marker| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, marker)) |at| {
            const before_word = at > 0 and (std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_');
            const end = at + marker.len;
            const after_word = end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_');
            if (!before_word and !after_word) {
                if (marker.len == 0) assert.panic("matched an empty comment marker; every marker must name visible text", .{});
                return marker;
            }
            from = end;
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
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, startsBefore);
    const scoped_contract = cancellationIsScopeBound(rule);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != unless or ts.ts_node_end_byte(t.node) > end) continue;
        if (cancellationBelongs(self, .{ .finding_node = node, .unless_node = t.node, .finding = finding, .barrier = barrier, .scoped = scoped_contract })) return true;
    }
    if (first > self.index.triples.len) assert.panic("{s}: the captures inside {f} start at {d}, past the {d} recorded; take the start from lowerBound over the recorded captures", .{ self.work.facts.path, node.where(), first, self.index.triples.len });
    return false;
}

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

fn checkDirectParameterSinks(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking direct parameter sinks in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking direct parameter sinks for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const t = self.tables;
    try checkParameterFormatString(self, ctx, name);
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.redirect_first_calls, .third_calls = t.redirect_third_calls, .first_methods = t.redirect_first_methods },
        .rule = "parameter-redirect-target",
        .problem = "flows directly into a redirect destination, so a caller can send users to an untrusted site",
    });
    try checkParameterFilePath(self, ctx, name);
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.xpath_first_calls, .second_calls = t.xpath_second_calls, .first_methods = t.xpath_first_methods },
        .rule = "parameter-xpath-expression",
        .problem = "flows directly into an XPath expression, so its operators can change which data the query selects",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .second_methods = t.ldap_second_methods, .third_methods = t.ldap_third_methods },
        .rule = "parameter-ldap-filter",
        .problem = "flows directly into an LDAP filter, so its operators can change which directory entries the query selects",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .second_methods = t.header_second_methods },
        .rule = "parameter-header-value",
        .problem = "flows directly into an HTTP header value, so carriage returns or line feeds can create additional headers or a response body",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.template_first_calls, .first_methods = t.template_first_methods, .second_methods = t.template_second_methods },
        .rule = "parameter-template-source",
        .problem = "is compiled as template source, so template directives can execute or expose server-side data",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_methods = t.expression_first_methods },
        .rule = "parameter-expression-language",
        .problem = "is parsed as expression-language code, so its operators can access or invoke unintended application objects",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.raw_html_first_calls },
        .rule = "parameter-raw-html",
        .problem = "is marked as already-safe HTML, so markup and script in it bypass automatic output escaping",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.allocation_size_first_calls, .second_calls = t.allocation_size_second_calls },
        .rule = "parameter-allocation-size",
        .problem = "controls an allocation size without a visible bound, so a caller can exhaust memory",
    });
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

fn checkLiteralNetworkEndpoint(self: *File, first: ts.Node) !void {
    if (ts.ts_node_start_byte(first) > ts.ts_node_end_byte(first)) assert.panic("{s}: literal network endpoint {f} runs backwards; pass a node from the live tree", .{ self.work.facts.path, first.where() });
    if (ts.ts_node_end_byte(first) > self.source.len) assert.panic("{s}: literal network endpoint {f} ends past the {d}-byte source", .{ self.work.facts.path, first.where(), self.source.len });
    const endpoint = first.text(self.source);
    if (sensitiveQueryKey(endpoint)) |key| {
        _ = try self.report(first, "sensitive-query-string", try self.say("The URL puts secret parameter '{s}' in its query string, where logs, browser history and intermediaries can retain it.", .{key}));
    }
    if (!cleartextHttp(endpoint)) return;
    _ = try self.report(first, "cleartext-http", try self.say("This request uses plain HTTP to a non-local endpoint, so anyone on the network path can read or alter it.", .{}));
    if (cleartextCredentialUrl(endpoint)) _ = try self.report(first, "cleartext-credential-url", try self.say("This plain-HTTP URL contains a credential, so anyone on the network path can read it.", .{}));
}

fn checkConstantSeed(self: *File, ctx: Context, name: []const u8, first: ts.Node) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a fixed seed in {f}, which is a {t}; call only from checkRiskyArgument", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a fixed seed for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    if (self.inTest() or self.inTestFile() or !self.index.marks(first, self.v.literal_constant)) return;
    const matched = self.calleeIn(ctx, name, self.tables.seed_calls) orelse return;
    _ = try self.report(first, "constant-random-seed", try self.say("'{s}' uses the fixed seed '{s}', so it produces the same predictable sequence whenever it starts.", .{ matched, header(first.text(self.source)) }));
}

fn checkNestedRegexQuantifier(self: *File, ctx: Context, name: []const u8, first: ts.Node) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a regex in {f}, which is a {t}; call only from checkRiskyArgument", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a regex for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    if (!self.index.marks(first, self.v.literal_string)) return;
    const matched = self.calleeIn(ctx, name, self.tables.regex_calls) orelse return;
    const pattern = first.text(self.source);
    if (!hasNestedRegexQuantifier(pattern)) return;
    _ = try self.report(first, "nested-regex-quantifier", try self.say("'{s}' compiles a pattern with an unbounded quantifier nested inside another, so crafted input can take exponential time: '{s}'.", .{ matched, header(pattern) }));
}

fn checkConstantCbcIv(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking an IV in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking an IV for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const position: usize = if (self.calleeIn(ctx, name, self.tables.iv_first_calls) != null)
        0
    else if (self.calleeIn(ctx, name, self.tables.iv_second_calls) != null)
        1
    else if (self.calleeIn(ctx, name, self.tables.iv_third_calls) != null)
        2
    else
        return;
    if (position == 2 and !callAlgorithmContains(self, ctx, "cbc")) return;
    const iv = ctx.arguments[position] orelse return;
    if (!fixedByteValue(self, iv)) return;
    _ = try self.report(iv, "constant-cbc-iv", try self.say("This CBC initialization vector is fixed in source, so encrypting with the same key repeats it and reveals relationships between messages: '{s}'.", .{header(iv.text(self.source))}));
}

fn checkConstantAeadNonce(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking an AEAD nonce in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking an AEAD nonce for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    var nonce: ?ts.Node = null;
    if (self.calleeIn(ctx, name, self.tables.iv_third_calls) != null and (callAlgorithmContains(self, ctx, "gcm") or callAlgorithmContains(self, ctx, "chacha"))) {
        if (ctx.arguments[2]) |argument| {
            if (fixedByteValue(self, argument)) nonce = argument;
        }
    } else if (self.calleeIn(ctx, name, self.tables.aead_nonce_calls) != null) {
        for (ctx.arguments) |argument| if (argument) |node| {
            if (fixedNonceOption(node.text(self.source))) nonce = node;
        };
    }
    const fixed = nonce orelse return;
    _ = try self.report(fixed, "constant-aead-nonce", try self.say("This authenticated-encryption nonce is fixed in source, so reuse under the same key breaks confidentiality or authenticity: '{s}'.", .{header(fixed.text(self.source))}));
}

fn checkConstantPasswordSalt(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a password salt in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a password salt for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const position: usize = if (self.calleeIn(ctx, name, self.tables.password_salt_second_calls) != null)
        1
    else if (self.calleeIn(ctx, name, self.tables.password_salt_third_calls) != null)
        2
    else
        return;
    const salt = ctx.arguments[position] orelse return;
    if (!fixedByteValue(self, salt)) return;
    _ = try self.report(salt, "constant-password-salt", try self.say("This password salt is fixed in source, so equal passwords reuse it and produce equal derived hashes: '{s}'.", .{header(salt.text(self.source))}));
}

fn checkRsaWithoutOaep(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking RSA padding in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking RSA padding for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const unsafe = if (self.calleeIn(ctx, name, self.tables.rsa_pkcs1_calls) != null)
        ctx.callee orelse ctx.name.?
    else if (self.calleeIn(ctx, name, self.tables.rsa_transformation_calls) != null) transformation: {
        const argument = ctx.arguments[0] orelse return;
        const text = argument.text(self.source);
        var lowered: [128]u8 = undefined;
        if (text.len > lowered.len) return;
        const normalized = std.ascii.lowerString(lowered[0..text.len], text);
        if (std.mem.indexOf(u8, normalized, "pkcs1padding") == null) return;
        break :transformation argument;
    } else return;
    _ = try self.report(unsafe, "rsa-without-oaep", try self.say("This RSA operation selects PKCS#1 v1.5 padding, which is vulnerable to padding-oracle attacks when decryption failures are observable.", .{}));
}

fn checkMissingIntegerRadix(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking an integer radix in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking an integer radix for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const matched = self.calleeIn(ctx, name, self.tables.integer_parse_calls) orelse return;
    if (ctx.argument_count != 1) return;
    const input = ctx.arguments[0] orelse assert.panic("{s}: '{s}' counted one argument but did not retain it; @call.argument must capture the argument expression", .{ self.work.facts.path, matched });
    _ = try self.report(input, "missing-integer-radix", try self.say("'{s}' parses this text without an explicit radix, so prefixes can change how the number is interpreted.", .{matched}));
}

fn checkWindowOpener(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a browser opener in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a browser opener for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    _ = self.calleeIn(ctx, name, self.tables.window_open_calls) orelse return;
    const url = ctx.arguments[0] orelse return;
    if (!directFunctionParameter(self, url)) return;
    const target = ctx.arguments[1] orelse return;
    if (!self.index.marks(target, self.v.literal_string)) return;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, target.text(self.source), "\"'`"), "_blank")) return;
    if (ctx.arguments[2]) |features| {
        if (!self.index.marks(features, self.v.literal_string)) return;
        const text = features.text(self.source);
        var lowered: [256]u8 = undefined;
        if (text.len > lowered.len) return;
        const normalized = std.ascii.lowerString(lowered[0..text.len], text);
        if (std.mem.indexOf(u8, normalized, "noopener") != null or std.mem.indexOf(u8, normalized, "noreferrer") != null) return;
    }
    _ = try self.report(url, "parameter-window-opener", try self.say("Function parameter '{s}' opens in a new tab without noopener, so the opened site can navigate or replace the original page.", .{url.text(self.source)}));
}

fn callAlgorithmContains(self: *File, ctx: Context, needle: []const u8) bool {
    if (needle.len == 0) assert.panic("{s}: checking a cipher algorithm for an empty name", .{self.work.facts.path});
    const algorithm = ctx.arguments[0] orelse return false;
    if (ts.ts_node_end_byte(algorithm) > self.source.len) assert.panic("{s}: cipher algorithm {f} ends past the {d}-byte source", .{ self.work.facts.path, algorithm.where(), self.source.len });
    const algorithm_text = algorithm.text(self.source);
    var lowered: [128]u8 = undefined;
    if (algorithm_text.len > lowered.len) return false;
    return std.mem.indexOf(u8, std.ascii.lowerString(lowered[0..algorithm_text.len], algorithm_text), needle) != null;
}

fn fixedNonceOption(text: []const u8) bool {
    if (text.len == 0 or text.len > 512) return false;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return false;
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    if (equals >= text.len) assert.panic("nonce assignment separator at {d} lies past its {d} bytes", .{ equals, text.len });
    const name = std.mem.trim(u8, text[0..equals], " \t");
    if (!std.ascii.eqlIgnoreCase(name, "nonce")) return false;
    const value = std.mem.trim(u8, text[equals + 1 ..], " \t");
    if (value.len > text.len) assert.panic("trimmed a {d}-byte nonce from a {d}-byte option", .{ value.len, text.len });
    if (value.len < 2) return false;
    const quote_at: usize = if (value[0] == 'b' or value[0] == 'r') 1 else 0;
    if (quote_at >= value.len) assert.panic("nonce prefix at {d} lies past its {d}-byte value", .{ quote_at, value.len });
    const quote = value[quote_at];
    return (quote == '"' or quote == '\'') and value[value.len - 1] == quote;
}

fn checkParameterFormatString(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a format string in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a format string for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const position: usize = if (self.calleeIn(ctx, name, self.tables.format_first_calls) != null)
        0
    else if (self.calleeIn(ctx, name, self.tables.format_second_calls) != null)
        1
    else
        return;
    const format = ctx.arguments[position] orelse return;
    if (!directFunctionParameter(self, format)) return;
    _ = try self.report(format, "parameter-format-string", try self.say("Function parameter '{s}' is used as the format string, so its format directives control how later values are interpreted.", .{format.text(self.source)}));
}

fn checkParameterFilePath(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a file path in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a file path for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    if (self.inTest() or self.inTestFile()) return;
    const target = if (self.calleeIn(ctx, name, self.tables.filesystem_calls) != null)
        ctx.arguments[0]
    else if (ctx.receiver != null and contains(self.tables.filesystem_methods, name))
        ctx.receiver
    else
        null;
    const path = target orelse return;
    if (!directFunctionParameter(self, path)) return;
    _ = try self.report(path, "parameter-file-path", try self.say("Function parameter '{s}' flows directly into file access, so absolute paths, parent traversal or symlinks can escape the intended directory.", .{path.text(self.source)}));
}

const ParameterSink = struct {
    first_calls: []const []const u8 = &.{},
    second_calls: []const []const u8 = &.{},
    third_calls: []const []const u8 = &.{},
    first_methods: []const []const u8 = &.{},
    second_methods: []const []const u8 = &.{},
    third_methods: []const []const u8 = &.{},
};

const DirectParameterRule = struct {
    sink: ParameterSink,
    rule: []const u8,
    problem: []const u8,
};

fn checkDirectSinkParameter(self: *File, ctx: Context, name: []const u8, spec: DirectParameterRule) !void {
    if (spec.rule.len == 0) assert.panic("{s}: checking a direct sink parameter without a rule name", .{self.work.facts.path});
    if (spec.problem.len == 0) assert.panic("{s}: checking direct sink rule '{s}' without explaining the problem", .{ self.work.facts.path, spec.rule });
    const argument = directSinkParameter(self, ctx, name, spec.sink) orelse return;
    _ = try self.report(argument, spec.rule, try self.say("Function parameter '{s}' {s}.", .{ argument.text(self.source), spec.problem }));
}

fn directSinkParameter(self: *File, ctx: Context, name: []const u8, sink: ParameterSink) ?ts.Node {
    if (ctx.family != .call) assert.panic("{s}: checking a direct sink parameter in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a direct sink parameter for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const has_receiver = ctx.receiver != null;
    const position: usize = if (self.calleeIn(ctx, name, sink.first_calls) != null)
        0
    else if (self.calleeIn(ctx, name, sink.second_calls) != null)
        1
    else if (self.calleeIn(ctx, name, sink.third_calls) != null)
        2
    else if (has_receiver and contains(sink.first_methods, name))
        0
    else if (has_receiver and contains(sink.second_methods, name))
        1
    else if (has_receiver and contains(sink.third_methods, name))
        2
    else
        return null;
    const argument = ctx.arguments[position] orelse return null;
    return if (directFunctionParameter(self, argument)) argument else null;
}

fn directFunctionParameter(self: *File, node: ts.Node) bool {
    if (!self.index.marks(node, self.v.expression_path)) return false;
    const function = self.innermost(.function) orelse return false;
    const signature = self.s.signature.items();
    if (function.parameter_start + function.parameter_count > signature.len) assert.panic("{s}: function {f} owns parameters {d}..{d}, past the {d} recorded", .{ self.work.facts.path, function.node.where(), function.parameter_start, function.parameter_start + function.parameter_count, signature.len });
    const candidate = node.text(self.source);
    if (candidate.len == 0) assert.panic("{s}: direct parameter candidate {f} has no text; capture an expression path", .{ self.work.facts.path, node.where() });
    for (signature[function.parameter_start..][0..function.parameter_count]) |parameter| {
        if (std.mem.eql(u8, parameter.name.text(self.source), candidate)) return true;
    }
    return false;
}

fn fixedByteValue(self: *File, node: ts.Node) bool {
    if (ts.ts_node_start_byte(node) > ts.ts_node_end_byte(node)) assert.panic("{s}: fixed-byte candidate {f} runs backwards; pass a node from the live tree", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: fixed-byte candidate {f} ends past the {d}-byte source", .{ self.work.facts.path, node.where(), self.source.len });
    if (self.index.marks(node, self.v.literal_string) and !self.index.marks(node, self.v.string_format)) return true;
    const value = std.mem.trim(u8, node.text(self.source), " \t\r\n");
    if (quotedByteConversion(value)) return true;
    return fixedNumericByteArray(value);
}

fn quotedByteConversion(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "[]byte(") or !std.mem.endsWith(u8, value, ")")) return false;
    if (value.len < "[]byte()".len) assert.panic("a byte conversion matched both delimiters in only {d} bytes", .{value.len});
    const inner = std.mem.trim(u8, value["[]byte(".len .. value.len - 1], " \t");
    if (inner.len > value.len) assert.panic("trimmed a {d}-byte byte-conversion value from {d} bytes", .{ inner.len, value.len });
    if (inner.len < 2) return false;
    const quote = inner[0];
    return (quote == '"' or quote == '\'') and inner[inner.len - 1] == quote;
}

fn fixedNumericByteArray(value: []const u8) bool {
    const braces = std.mem.startsWith(u8, value, "[]byte{") and std.mem.endsWith(u8, value, "}");
    const brackets = std.mem.startsWith(u8, value, "[") and std.mem.endsWith(u8, value, "]");
    if (!braces and !brackets) return false;
    const start: usize = if (braces) "[]byte{".len else 1;
    if (start >= value.len) assert.panic("fixed byte elements start at {d} in a {d}-byte value", .{ start, value.len });
    if (value[value.len - 1] != '}' and value[value.len - 1] != ']') assert.panic("fixed byte array ends with '{c}' after a closing delimiter was matched in its {d} bytes", .{ value[value.len - 1], value.len });
    for (value[start .. value.len - 1]) |c| if (!std.ascii.isHex(c) and std.mem.indexOfScalar(u8, " \t\r\n,xX", c) == null) return false;
    return value.len > start + 1;
}

fn checkXmlEntityExpansion(self: *File, ctx: Context, name: []const u8) !void {
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
    if (text.len > 512) return false;
    var normalized: [512]u8 = undefined;
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

fn sensitiveQueryKey(literal: []const u8) ?[]const u8 {
    if (literal.len == 0) assert.panic("checking an empty string literal for a query parameter; literal nodes include their quotes", .{});
    const url = std.mem.trim(u8, literal, "\"'`");
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    if (query >= url.len) assert.panic("query marker at {d} lies past a {d}-byte URL", .{ query, url.len });
    var parameters = std.mem.splitScalar(u8, url[query + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const key = parameter[0..equals];
        if (queryKeyNamesSecret(key)) return key;
    }
    return null;
}

fn queryKeyNamesSecret(key: []const u8) bool {
    if (key.len == 0) return false;
    if (std.mem.indexOfAny(u8, key, "&=") != null) assert.panic("checking unsplit query key '{s}'; sensitiveQueryKey must remove separators first", .{key});
    var squeezed: [96]u8 = undefined;
    var len: usize = 0;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (len == squeezed.len) return false;
        squeezed[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (len > key.len) assert.panic("normalized a {d}-byte query key from {d} bytes; normalization can only remove bytes", .{ len, key.len });
    if (len == 0) return false;
    for (rules.secret_names) |word| if (std.mem.endsWith(u8, squeezed[0..len], word)) return true;
    return false;
}

fn cleartextHttp(literal: []const u8) bool {
    if (literal.len == 0) assert.panic("checking an empty string literal as a URL; literal nodes include their quotes", .{});
    const url = std.mem.trim(u8, literal, "\"'`");
    if (!std.ascii.startsWithIgnoreCase(url, "http://")) return false;
    const rest = url["http://".len..];
    if (std.mem.startsWith(u8, rest, "[::1]") and (rest.len == "[::1]".len or std.mem.indexOfScalar(u8, ":/?#", rest["[::1]".len]) != null)) return false;
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    const host = rest[0..end];
    if (host.len > rest.len) assert.panic("read a {d}-byte HTTP host from {d} bytes after the scheme", .{ host.len, rest.len });
    return !(std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "[::1]"));
}

fn cleartextCredentialUrl(literal: []const u8) bool {
    if (literal.len == 0) assert.panic("checking an empty URL literal for a credential; literal nodes include their quotes", .{});
    if (!cleartextHttp(literal)) return false;
    if (sensitiveQueryKey(literal) != null) return true;
    const url = std.mem.trim(u8, literal, "\"'`");
    const authority = url["http://".len .. std.mem.indexOfAnyPos(u8, url, "http://".len, "/?#") orelse url.len];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return false;
    if (at >= authority.len) assert.panic("userinfo separator at {d} lies past a {d}-byte URL authority", .{ at, authority.len });
    return std.mem.indexOfScalar(u8, authority[0..at], ':') != null;
}

/// Reports a logged value whose name says it is a secret, such as `token` or `db_password`.
pub fn checkLoggedSecret(self: *File, ctx: Context, callee: ts.Node) !void {
    const start = ts.ts_node_end_byte(callee);
    const end = ts.ts_node_end_byte(ctx.node);
    if (start > end) assert.panic("{s}: the callee {f} ends after its call {f}; capture @call.name inside @call.outer in the language's zanity.scm", .{ self.work.facts.path, callee.where(), ctx.node.where() });
    if (ctx.arguments[0]) |message| if (directFunctionParameter(self, message)) {
        _ = try self.report(message, "parameter-log-message", try self.say("Function parameter '{s}' is used as the whole log message, so line breaks or control characters can forge additional log entries.", .{message.text(self.source)}));
    };
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
