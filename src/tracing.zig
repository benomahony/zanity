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

/// Whether a function or its decorators start a span, kept on its fact for a route that names it,
/// and a function a decorator such as `@app.get(...)` registers as a request handler that starts
/// none, for untraced-entry-point to report once every file shows whether the project traces.
pub fn noteHandlerFunction(self: *File, ctx: Context, name_node: ts.Node, name: []const u8) !void {
    if (ctx.family != .function) assert.panic("{s}: noting {f} as a handler, but it is a {t}; call noteHandlerFunction() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: noting an unnamed handler at {f}; closeFunction() returns before unnamed ones", .{ self.work.facts.path, ctx.node.where() });
    if (!self.checker.enabled.enabled("untraced-entry-point")) return;
    const traced = self.s.spans.startsWithin(ts.ts_node_start_byte(ctx.node), ts.ts_node_end_byte(ctx.node));
    if (traced) if (ctx.fact) |id| self.work.facts.markTraced(id);
    if (traced or !decoratedAsRoute(self, ctx)) return;
    const at = ts.ts_node_start_point(name_node);
    try self.work.facts.untracedHandler("handler", name, .{ at.row, at.column });
}

/// Whether a decorator over the function registers it as a request handler, as `@app.get(...)` does.
fn decoratedAsRoute(self: *File, ctx: Context) bool {
    if (ctx.family != .function) assert.panic("{s}: looking for route decorators on {f}, a {t}; only functions have them", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const t = self.tables;
    const from = ts.ts_node_start_byte(ctx.node);
    const body = ts.ts_node_start_byte(ctx.span);
    if (t.route_decorators.len == 0 or from >= body) return false;
    const calls = self.s.calls.items();
    var i = calls.len;
    while (i > 0) {
        i -= 1;
        const call = calls[i];
        if (call.key.start < from) break;
        const callee = (call.name orelse continue).text(self.source);
        if (call.receiver and call.key.start < body and contains(t.route_decorators, callee)) return true;
    }
    if (i > calls.len) assert.panic("{s}: the decorator search stopped at call {d} of {d}", .{ self.work.facts.path, i, calls.len });
    return false;
}

/// A call showing the file traces or registers instrumentation, a span start for the handler
/// around it, or a route registering a handler, for untraced-entry-point.
pub fn noteTracingCall(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: noting {f} as a tracing call, but it is a {t}; call noteTracingCall() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    if (!self.checker.enabled.enabled("untraced-entry-point")) return;
    const t = self.tables;
    const receiver = ctx.receiver != null;
    const at = ctx.callee orelse ctx.name.?;
    if (startsSpan(t, name, receiver) and !unpaired(self, ctx, name)) {
        try self.s.spans.startsAt(ts.ts_node_start_byte(ctx.node));
        try tracingCall(self, "tracer", at);
    } else if (receiver and contains(t.tracer_methods, name)) try tracingCall(self, "tracer", at);
    if (self.calleeIn(ctx, name, t.instrumentation_calls) != null or (receiver and contains(t.instrumentation_methods, name))) try tracingCall(self, "instrumentation", at);
    if (receiver and contains(t.route_methods, name)) try noteRoute(self, ctx, name);
}

/// Records the file's first call of `kind`, "tracer" or "instrumentation".
fn tracingCall(self: *File, comptime kind: []const u8, at: ts.Node) !void {
    if (ts.ts_node_end_byte(at) > self.source.len) assert.panic("the {s} call at {f} ends past the {d} bytes of source; pass a node from this file's tree", .{ kind, at.where(), self.source.len });
    if (ts.ts_node_end_byte(at) <= ts.ts_node_start_byte(at)) assert.panic("{s}: the {s} call at {f} is empty; report it at its callee or name", .{ self.work.facts.path, kind, at.where() });
    const seen = if (comptime std.mem.eql(u8, kind, "tracer")) &self.s.spans.traces else &self.s.spans.instruments;
    if (seen.*) return;
    seen.* = true;
    const point = ts.ts_node_start_point(at);
    try self.work.facts.tracingCall(kind, header(at.text(self.source)), .{ point.row, point.column });
}

/// A call registering the handler it is passed last for the route its first argument names, as
/// `app.get("/orders", handler)` does: a function passed inline that starts no span is an
/// untraced handler, and one passed by name is looked up in every file once all are read.
fn noteRoute(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: noting {f} as a route, but it is a {t}; call noteRoute() only from noteTracingCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the route call {f} has an empty name; capture the callee as @call.name", .{ self.work.facts.path, ctx.node.where() });
    const route = ctx.arguments[0] orelse return;
    const path = route.text(self.source);
    if (path.len < 2 or std.mem.indexOfScalar(u8, "\"'`", path[0]) == null) return;
    const shown = std.mem.trim(u8, path, "\"'`");
    var i = @min(ctx.argument_count, ctx.arguments.len);
    while (i > 1) {
        i -= 1;
        const handler = ctx.arguments[i] orelse continue;
        const point = ts.ts_node_start_point(handler);
        if (self.index.marks(handler, self.checker.compiled.id("call.handler"))) {
            if (self.s.spans.startsWithin(ts.ts_node_start_byte(handler), ts.ts_node_end_byte(handler))) return;
            return self.work.facts.untracedHandler("route", shown, .{ point.row, point.column });
        }
        const text = handler.text(self.source);
        if (handlerName(text)) |named| return self.work.facts.route(named, .{ point.row, point.column });
    }
}

/// The function `text` names, the part after its last `.` or `:`, when it is a name or a path of
/// names, as `getOrder`, `handlers.getOrder` and `s.getOrder` are.
fn handlerName(text: []const u8) ?[]const u8 {
    if (text.len == 0) assert.panic("asked which function an empty argument names; captures always have text", .{});
    if (!(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return null;
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':')) return null;
    const last = std.mem.lastIndexOfAny(u8, text, ".:") orelse return text;
    if (last + 1 > text.len) assert.panic("the last separator of '{s}' is past its end", .{text});
    return if (last + 1 == text.len) null else text[last + 1 ..];
}

/// Whether a call to `callee` starts a span, scoped or not.
fn startsSpan(t: *const language.Tables, callee: []const u8, receiver: bool) bool {
    if (callee.len == 0) assert.panic("asking whether an unnamed call starts a span; @call.name captures the callee's identifier", .{});
    if (t.ecosystem.len == 0) assert.panic("asking whether '{s}' starts a span with tables for no ecosystem; every language's tables name one", .{callee});
    if (contains(t.span_start_calls, callee) or contains(t.span_name_first_calls, callee)) return true;
    return receiver and (contains(t.span_start_methods, callee) or contains(t.span_name_first_methods, callee) or contains(t.span_name_second_methods, callee));
}

/// Reports each request handler that starts no span, in a language some file of which traces and
/// none of which registers instrumentation that traces handlers by itself: the handlers a decorator
/// or a route passes inline, and the functions a route names that start no span.
pub fn untracedHandlers(facts: *Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const handlers = facts.untraced.items();
    std.mem.sort(Definition, handlers, {}, Definition.sourceOrder);
    for (handlers) |h| {
        if (h.name.len == 0) assert.panic("{s}:{d}: a handler has no name; untracedHandler() records only named handlers", .{ h.path, h.line + 1 });
        if (traces(facts, h.language)) try reportHandler(facts, findings, h, std.mem.eql(u8, h.kind, "route"));
    }
    const routes = facts.routes.items();
    if (routes.len == 0) return;
    std.mem.sort(Definition, routes, {}, byName);
    for (facts.functions.items()) |f| {
        if (f.traced or firstRoute(routes, f.name) == null) continue;
        const adapter = language.forPath(f.path) orelse continue;
        if (!routedIn(routes, f.name, adapter.name) or !traces(facts, adapter.name)) continue;
        try reportHandler(facts, findings, .{ .path = f.path, .language = adapter.name, .name = f.name, .kind = "handler", .line = f.line, .column = f.column }, false);
    }
    if (findings.len < before) assert.panic("untraced-entry-point dropped findings from {d} to {d}; it may only add", .{ before, findings.len });
}

/// Reports a handler, named by its function or, when passed inline, by its route.
fn reportHandler(facts: *Facts, findings: *memory.Bounded(Finding), h: Definition, inline_route: bool) error{LimitExceeded}!void {
    if (h.path.len == 0) assert.panic("reporting handler '{s}' with no path; facts always belong to a file", .{h.name});
    if (h.name.len == 0) assert.panic("reporting an unnamed handler in {s}; handlers are recorded by name or route", .{h.path});
    const message = if (inline_route)
        try facts.text.format("The handler for '{s}' starts no span, though this project traces, so its requests are missing from every trace.", .{h.name})
    else
        try facts.text.format("'{s}' handles requests and starts no span, though this project traces, so its requests are missing from every trace.", .{h.name});
    const fix = if (inline_route)
        try facts.text.format("Start a span at the top of the handler for '{s}', named for the operation, or register the framework's tracing instrumentation once so every handler gets one.", .{h.name})
    else
        try facts.text.format("Start a span at the top of '{s}', named for the operation, or register the framework's tracing instrumentation once so every handler gets one.", .{h.name});
    try findings.add(.{ .path = h.path, .line = h.line, .column = h.column, .rule = "untraced-entry-point", .message = message, .fix = fix });
}

/// Whether a file in `lang` traces and none registers instrumentation that traces its handlers.
fn traces(facts: *const Facts, lang: []const u8) bool {
    if (lang.len == 0) assert.panic("asking whether an unnamed language traces; facts.language comes from the adapter that checked the file", .{});
    var tracer = false;
    for (facts.tracing.items()) |call| {
        if (!std.mem.eql(u8, call.language, lang)) continue;
        if (std.mem.eql(u8, call.kind, "instrumentation")) return false;
        if (!std.mem.eql(u8, call.kind, "tracer")) assert.panic("{s}: a tracing call of kind '{s}'; tracingCall() records only tracer and instrumentation", .{ call.path, call.kind });
        tracer = true;
    }
    return tracer;
}

fn byName(_: void, a: Definition, b: Definition) bool {
    if (a.name.len == 0) assert.panic("{s}:{d}: ordering a route with an empty name; route() records only named handlers", .{ a.path, a.line + 1 });
    if (b.name.len == 0) assert.panic("{s}:{d}: ordering a route with an empty name; route() records only named handlers", .{ b.path, b.line + 1 });
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Where the routes for `name` start among `routes`, sorted by name, or null for none.
fn firstRoute(routes: []const Definition, name: []const u8) ?usize {
    if (name.len == 0) assert.panic("looking up the routes of an unnamed function; functions are recorded by name", .{});
    var low: usize = 0;
    var high = routes.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.mem.order(u8, routes[mid].name, name) == .lt) low = mid + 1 else high = mid;
    }
    if (low > routes.len) assert.panic("the route search for '{s}' ended at {d} of {d}", .{ name, low, routes.len });
    return if (low < routes.len and std.mem.eql(u8, routes[low].name, name)) low else null;
}

/// Whether a route in `lang` names `name`.
fn routedIn(routes: []const Definition, name: []const u8, lang: []const u8) bool {
    if (lang.len == 0) assert.panic("looking up routes for '{s}' in an unnamed language", .{name});
    if (name.len == 0) assert.panic("looking up the routes of an unnamed function in {s}; functions are recorded by name", .{lang});
    var i = firstRoute(routes, name) orelse return false;
    while (i < routes.len and std.mem.eql(u8, routes[i].name, name)) : (i += 1) {
        if (std.mem.eql(u8, routes[i].language, lang)) return true;
    }
    return false;
}
