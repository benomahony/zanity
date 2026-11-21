//! The tracing checks: a span named with text built at runtime, a span start that discards the
//! context it returns, a span a function starts and neither ends nor hands to code that does, and
//! a request handler that starts no span in a project that traces.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const header = check.header;

const TraceSpan = @import("spans.zig").TraceSpan;
const memory = @import("memory.zig");
const language = @import("language.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Definition = facts_module.Definition;

/// A tracing call from the language's tables: a span named with text built at runtime, a span
/// start that discards the context it returns, and the spans functions start and end, for
/// checkUnendedSpan when the function closes.
pub fn checkSpanCall(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} as a tracing call, but it is a {t}; call checkSpanCall() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    const t = self.tables;
    const has_receiver = ctx.receiver != null;
    if (ctx.receiver) |receiver| if (contains(t.span_end_methods, name)) try self.s.spans.end(receiver);
    if (unpaired(self, ctx, name)) return;
    if (spanName(self, ctx, name)) |span_name| {
        if (self.index.marks(span_name, self.v.string_built) or self.index.marks(span_name, self.v.string_format)) {
            _ = try self.report(span_name, "dynamic-span-name", try self.say("'{s}' names the span with text built at runtime, so each value makes a new span name and traces can't be grouped by operation.", .{header(span_name.text(self.source))}));
        }
    }
    const starts = self.calleeIn(ctx, name, t.span_start_calls) != null or (has_receiver and contains(t.span_start_methods, name));
    if (!starts) return;
    const at = ctx.callee orelse ctx.name.?;
    if (self.index.marks(ctx.node, self.checker.compiled.id("call.context_discarded"))) {
        _ = try self.report(at, "discarded-span-context", try self.say("'{s}' starts a span and throws away the context that carries it, so spans started from the old context are not its children and the trace splits apart.", .{at.text(self.source)}));
    }
    const f = self.enclosingFunction() orelse return;
    if (self.index.marks(ctx.node, self.checker.compiled.id("call.handed_off"))) return;
    try self.s.spans.start(.{ .owner = f.serial, .start = ctx.node, .at = at, .binding = spanBinding(self, ctx.node) });
}

/// The name a span start is bound to: the first parameter of the callback it passes, as
/// `startActiveSpan(name, (span) => ...)` does, or the name its result is assigned to, which
/// sits one level above the call, or two in Go's `ctx, span := tracer.Start(ctx, name)`.
fn spanBinding(self: *File, call: ts.Node) ?ts.Node {
    if (ts.ts_node_end_byte(call) > self.source.len) assert.panic("{s}: the span start {f} ends past the {d} bytes of source; pass a node from this file's tree", .{ self.work.facts.path, call.where(), self.source.len });
    const compiled = self.checker.compiled;
    if (!self.index.marks(call, compiled.id("binding.value"))) return null;
    const binding_name = compiled.id("binding.name");
    if (self.index.within(call, binding_name)) |name| return name;
    var node = call;
    for (0..2) |_| {
        node = self.parentOf(node) orelse return null;
        if (ts.ts_node_start_byte(node) > ts.ts_node_start_byte(call)) assert.panic("{s}: the parent {f} of the span start {f} starts after it; parentOf() must return an ancestor", .{ self.work.facts.path, node.where(), call.where() });
        const name = self.index.within(node, binding_name) orelse continue;
        if (ts.ts_node_end_byte(name) <= ts.ts_node_start_byte(call)) return name;
    }
    return null;
}

/// Whether span starts in this language return the context and the span together, as Go's
/// `tracer.Start(ctx, name)` does, and this call does not, so it is something else, such as
/// `cmd.Start()` or `srv, err := pool.Start(ctx, cfg)`.
fn unpaired(self: *File, ctx: Context, name: []const u8) bool {
    if (ctx.family != .call) assert.panic("{s}: checking whether {f} pairs a context and a span, but it is a {t}; call only from checkSpanCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking whether an unnamed call pairs a context and a span; capture @call.name in the language query", .{self.work.facts.path});
    if (!self.tables.span_start_pairs) return false;
    return !self.index.marks(ctx.node, self.checker.compiled.id("call.paired")) or spanName(self, ctx, name) == null;
}

/// The argument naming the span a tracing call starts, at the position its table gives.
fn spanName(self: *File, ctx: Context, name: []const u8) ?ts.Node {
    if (ctx.family != .call) assert.panic("{s}: finding the span name of {f}, which is a {t}; call only from checkSpanCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: finding the span name of an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const t = self.tables;
    const has_receiver = ctx.receiver != null;
    if (self.calleeIn(ctx, name, t.span_name_first_calls) != null or (has_receiver and contains(t.span_name_first_methods, name))) return ctx.arguments[0];
    if (has_receiver and contains(t.span_name_second_methods, name)) return ctx.arguments[1];
    return null;
}

/// A span the function starts and never ends, which the tracer never records or exports.
pub fn checkUnendedSpan(self: *File, ctx: Context) !void {
    if (ctx.family != .function) assert.panic("{s}: checking {f} for an unended span, but it is a {t}; call checkUnendedSpan() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    for (self.s.spans.starts()) |span| {
        if (span.owner != ctx.serial) continue;
        if (ts.ts_node_end_byte(span.start) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: the span start {f} ends after its function {f}; record only calls inside the enclosing function", .{ self.work.facts.path, span.start.where(), ctx.node.where() });
        if (spanSettled(self, ctx.node, span)) continue;
        _ = try self.report(span.at, "unended-span", try self.say("'{s}' starts a span this function never ends, so the span is never recorded or exported.", .{span.at.text(self.source)}));
    }
}

/// Whether the span is ended or handed to code that ends it. A span bound to a name is settled by
/// a later use of that name: the receiver of an end call, or handed off as an argument, a returned
/// value or a stored field. One bound to no name can only be ended by what it is passed to, so
/// only a start whose result is thrown away is unsettled.
fn spanSettled(self: *File, function: ts.Node, span: TraceSpan) bool {
    const compiled = self.checker.compiled;
    const binding = span.binding orelse return !self.index.marks(span.start, compiled.id("call.discarded"));
    if (ts.ts_node_start_byte(binding) < ts.ts_node_start_byte(function)) assert.panic("{s}: the span start {f} is bound to {f}, outside its function {f}; spanBinding() must find the name inside the function", .{ self.work.facts.path, span.start.where(), binding.where(), function.where() });
    const name = binding.text(self.source);
    if (name.len == 0) assert.panic("{s}: the span start {f} is bound to the empty {f}; capture a named node as @binding.name", .{ self.work.facts.path, span.start.where(), binding.where() });
    for (self.index.capturesWithin(function)) |t| {
        if (t.id != self.v.reference_name) continue;
        if (ts.ts_node_start_byte(t.node) < ts.ts_node_end_byte(binding)) continue;
        if (ts.ts_node_symbol(t.node) != ts.ts_node_symbol(binding) or !std.mem.eql(u8, t.node.text(self.source), name)) continue;
        if (self.s.spans.endsAt(t.node) or spanHandedOff(self, t.node)) return true;
    }
    return false;
}

/// Whether `use` hands a span to code that ends it: passed as an argument, returned, alone or
/// with the context as Go's `return ctx, span` does, or stored on an object.
fn spanHandedOff(self: *File, use: ts.Node) bool {
    if (ts.ts_node_end_byte(use) > self.source.len) assert.panic("{s}: the use {f} ends past the {d} bytes of source; pass a node from this file's tree", .{ self.work.facts.path, use.where(), self.source.len });
    if (ts.ts_node_end_byte(use) <= ts.ts_node_start_byte(use)) assert.panic("{s}: the use {f} is empty; @reference.name must capture a named node", .{ self.work.facts.path, use.where() });
    const compiled = self.checker.compiled;
    const returned = compiled.id("expression.returned");
    if (self.index.marks(use, compiled.id("call.argument")) or self.index.marks(use, returned) or self.index.marks(use, compiled.id("binding.handed_off"))) return true;
    const parent = self.parentOf(use) orelse return false;
    return self.index.marks(parent, returned);
}

/// A function a decorator such as `@app.get(...)` registers as a request handler, when neither it
/// nor its decorators start a span, for untraced-entry-point to report once every file shows
/// whether the project traces.
pub fn noteUntracedHandler(self: *File, ctx: Context, name_node: ts.Node, name: []const u8) !void {
    if (ctx.family != .function) assert.panic("{s}: noting {f} as a handler, but it is a {t}; call noteUntracedHandler() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: noting an unnamed handler at {f}; closeFunction() returns before unnamed ones", .{ self.work.facts.path, ctx.node.where() });
    const t = self.tables;
    if (t.entry_point_decorators.len == 0 or !self.checker.enabled.enabled("untraced-entry-point")) return;
    const from = ts.ts_node_start_byte(ctx.node);
    const body = ts.ts_node_start_byte(ctx.span);
    if (from >= body) return;
    var registered = false;
    const calls = self.s.calls.items();
    var i = calls.len;
    while (i > 0) {
        i -= 1;
        const call = calls[i];
        if (call.key.start < from) break;
        const callee = (call.name orelse continue).text(self.source);
        if (startsSpan(t, callee, call.receiver)) return;
        if (call.receiver and call.key.start < body and contains(t.entry_point_decorators, callee)) registered = true;
    }
    if (!registered) return;
    const at = ts.ts_node_start_point(name_node);
    try self.work.facts.untracedHandler(name, .{ at.row, at.column });
}

/// Whether a call to `callee` starts a span, scoped or not.
fn startsSpan(t: *const language.Tables, callee: []const u8, receiver: bool) bool {
    if (callee.len == 0) assert.panic("asking whether an unnamed call starts a span; @call.name captures the callee's identifier", .{});
    if (t.ecosystem.len == 0) assert.panic("asking whether '{s}' starts a span with tables for no ecosystem; every language's tables name one", .{callee});
    if (contains(t.span_start_calls, callee) or contains(t.span_name_first_calls, callee)) return true;
    return receiver and (contains(t.span_start_methods, callee) or contains(t.span_name_first_methods, callee) or contains(t.span_name_second_methods, callee));
}

/// Reports each request handler that starts no span, in a language some file of which imports a
/// tracing SDK and none of which imports an instrumentation that traces handlers by itself.
pub fn untracedHandlers(facts: *Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const handlers = facts.untraced.items();
    std.mem.sort(Definition, handlers, {}, Definition.sourceOrder);
    for (handlers) |h| {
        if (h.name.len == 0) assert.panic("{s}:{d}: a handler has no name; untracedHandler() records only named functions", .{ h.path, h.line + 1 });
        const adapter = language.named(h.language) orelse assert.panic("{s}: a handler was recorded in language '{s}', which zanity doesn't know; facts.language comes from the adapter that checked the file", .{ h.path, h.language });
        const t = adapter.tables;
        if (!imported(facts, h.language, t.tracing_modules) or imported(facts, h.language, t.instrumentation_modules)) continue;
        try findings.add(.{
            .path = h.path,
            .line = h.line,
            .column = h.column,
            .rule = "untraced-entry-point",
            .message = try facts.text.format("'{s}' handles requests and starts no span, though this project traces, so its requests are missing from every trace.", .{h.name}),
            .fix = try facts.text.format("Start a span at the top of '{s}', such as with tracer.start_as_current_span(\"{s}\"):, or instrument the framework once, such as FastAPIInstrumentor.instrument_app(app).", .{ h.name, h.name }),
        });
    }
    if (findings.len - before > handlers.len) assert.panic("untraced-entry-point reported {d} findings for {d} handlers; each can be reported once", .{ findings.len - before, handlers.len });
}

/// Whether a file in `lang` imports one of `modules` or a submodule of one.
fn imported(facts: *const Facts, lang: []const u8, modules: []const []const u8) bool {
    if (lang.len == 0) assert.panic("looking for imports in an unnamed language; facts.language comes from the adapter that checked the file", .{});
    for (facts.imports.items()) |i| {
        if (!std.mem.eql(u8, i.language, lang)) continue;
        for (modules) |m| {
            if (m.len == 0) assert.panic("{s} lists an empty module; every tracing or instrumentation module needs a name", .{lang});
            if (std.mem.startsWith(u8, i.spec, m) and (i.spec.len == m.len or i.spec[m.len] == '.')) return true;
        }
    }
    return false;
}
