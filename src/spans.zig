//! The spans a file's functions start and the calls that end them, for unended-span, and where
//! any span starts, for untraced-entry-point.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const memory = @import("memory.zig");

/// A span a function starts and must end itself, and the name its start is bound to, if any.
pub const TraceSpan = struct { owner: u32, start: ts.Node, at: ts.Node, binding: ?ts.Node };

/// The spans a file's functions start, and the receivers of the calls that end one, such as
/// `span` in `span.end()`, for checkUnendedSpan to match when each function closes.
pub const Spans = struct {
    started: memory.Bounded(TraceSpan),
    ends: memory.Bounded(ts.Node),
    /// Where each call starting a span, scoped or not, starts, in the order the calls close.
    traced_at: memory.Bounded(u32),
    /// Whether the file has recorded a call that traces, or one that registers instrumentation.
    traces: bool = false,
    instruments: bool = false,

    pub fn initSpans(gpa: std.mem.Allocator, room: usize) std.mem.Allocator.Error!Spans {
        if (room == 0) assert.panic("memory.Limits.per_file is 0, so no span could be recorded; set it above 0", .{});
        const spans: Spans = .{ .started = try .initBounded(gpa, room, "tracing spans started in one file"), .ends = try .initBounded(gpa, room, "tracing span ends in one file"), .traced_at = try .initBounded(gpa, room, "calls starting a span in one file") };
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

    /// Records that a call starting a span, scoped or not, starts at byte `at`.
    pub fn startsAt(self: *Spans, at: u32) error{LimitExceeded}!void {
        const before = self.traced_at.len;
        if (before > 0 and self.traced_at.items()[before - 1] == at) assert.panic("recorded the span start at byte {d} twice; closeCall() closes each call once", .{at});
        try self.traced_at.add(at);
        if (self.traced_at.len != before + 1) assert.panic("recording a span start took the list from {d} to {d}; add() must add one", .{ before, self.traced_at.len });
    }

    /// Whether a span starts within bytes `from..to`, counting only calls that closed after one
    /// starting before `from`, so a node's own calls close last.
    pub fn startsWithin(self: *const Spans, from: u32, to: u32) bool {
        if (to < from) assert.panic("looking for spans in bytes {d}..{d}, which end before they start", .{ from, to });
        if (self.traced_at.len > self.traced_at.buffer.len) assert.panic("{d} span starts in {d} slots; add() must refuse the extra", .{ self.traced_at.len, self.traced_at.buffer.len });
        const at = self.traced_at.items();
        var i = at.len;
        while (i > 0) {
            i -= 1;
            if (at[i] < from) return false;
            if (at[i] < to) return true;
        }
        return false;
    }

    pub fn clear(self: *Spans) void {
        self.started.clear();
        self.ends.clear();
        self.traced_at.clear();
        self.traces = false;
        self.instruments = false;
        if (self.started.len != 0) assert.panic("clearing the span lists left {d} starts; clear() must empty both lists", .{self.started.len});
        if (self.ends.len != 0) assert.panic("clearing the span lists left {d} ends; clear() must empty both lists", .{self.ends.len});
    }
};
