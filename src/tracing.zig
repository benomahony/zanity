//! The tracing checks: a span named with text built at runtime, a span start that discards the
//! context it returns, and a span a function starts and neither ends nor hands to code that does.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const memory = @import("memory.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const header = check.header;

/// A span a function starts and must end itself, and the name its start is bound to, if any.
pub const TraceSpan = struct { owner: u32, start: ts.Node, at: ts.Node, binding: ?ts.Node };

/// The spans a file's functions start, and the receivers of the calls that end one, such as
/// `span` in `span.end()`, for checkUnendedSpan to match when each function closes.
pub const Spans = struct {
    started: memory.Bounded(TraceSpan),
    ends: memory.Bounded(ts.Node),

    pub fn initSpans(gpa: std.mem.Allocator, room: usize) std.mem.Allocator.Error!Spans {
        if (room == 0) assert.panic("memory.Limits.per_file is 0, so no span could be recorded; set it above 0", .{});
        const spans: Spans = .{ .started = try .initBounded(gpa, room, "tracing spans started in one file"), .ends = try .initBounded(gpa, room, "tracing span ends in one file") };
        if (spans.started.len != 0 or spans.ends.len != 0) assert.panic("new span lists hold {d} starts and {d} ends; initBounded() must start them empty", .{ spans.started.len, spans.ends.len });
        return spans;
    }

    pub fn start(self: *Spans, span: TraceSpan) error{LimitExceeded}!void {
        if (ts.ts_node_start_byte(span.at) < ts.ts_node_start_byte(span.start)) assert.panic("the span start {f} is reported at {f}, before it; report it at its callee or name", .{ span.start.where(), span.at.where() });
        if (ts.ts_node_end_byte(span.at) > ts.ts_node_end_byte(span.start)) assert.panic("the span start {f} is reported at {f}, past its end; report it at its callee or name", .{ span.start.where(), span.at.where() });
        try self.started.add(span);
    }

    pub fn end(self: *Spans, receiver: ts.Node) error{LimitExceeded}!void {
        if (ts.ts_node_end_byte(receiver) <= ts.ts_node_start_byte(receiver)) assert.panic("the span end receiver {f} is empty; @call.receiver must capture a named node", .{receiver.where()});
        const before = self.ends.len;
        try self.ends.add(receiver);
        if (self.ends.len != before + 1) assert.panic("recording a span end took the list from {d} to {d}; add() must add one", .{ before, self.ends.len });
    }

    /// Every span the file's functions have started so far.
    pub fn starts(self: *const Spans) []const TraceSpan {
        if (self.started.len > self.started.buffer.len) assert.panic("{d} span starts in {d} slots; add() must refuse the extra", .{ self.started.len, self.started.buffer.len });
        const all = self.started.items();
        if (all.len != self.started.len) assert.panic("the span starts list holds {d} but items() gave {d}", .{ self.started.len, all.len });
        return all;
    }

    /// Whether `use` is the receiver of a call that ends a span, as `span` is in `span.end()`.
    pub fn endsAt(self: *const Spans, use: ts.Node) bool {
        if (ts.ts_node_end_byte(use) <= ts.ts_node_start_byte(use)) assert.panic("the use {f} is empty; @reference.name must capture a named node", .{use.where()});
        if (self.ends.len > self.ends.buffer.len) assert.panic("{d} span ends in {d} slots; add() must refuse the extra", .{ self.ends.len, self.ends.buffer.len });
        for (self.ends.items()) |receiver| if (receiver.eql(use)) return true;
        return false;
    }

    pub fn clear(self: *Spans) void {
        self.started.clear();
        self.ends.clear();
        if (self.started.len != 0) assert.panic("clearing the span lists left {d} starts; clear() must empty both lists", .{self.started.len});
        if (self.ends.len != 0) assert.panic("clearing the span lists left {d} ends; clear() must empty both lists", .{self.ends.len});
    }
};

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
    for (self.index.inside(function)) |t| {
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
