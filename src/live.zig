//! A progress line redrawn in place on an interactive terminal, so a long run shows how far it
//! has got and how long is left. Off when stderr is not a terminal or `-q` is given.
const std = @import("std");
const Io = std.Io;
const zrich = @import("zrich");

/// The fastest the line is redrawn; faster only flickers.
const redraw_ns = 100 * std.time.ns_per_ms;

pub const Live = struct {
    console: zrich.Console,
    io: Io,
    enabled: bool,
    started: Io.Timestamp,
    shown: ?Io.Timestamp = null,
    label: [160]u8 = undefined,
    remaining: [32]u8 = undefined,

    pub fn initLive(console: zrich.Console, io: Io, enabled: bool) Live {
        const live: Live = .{ .console = console, .io = io, .enabled = enabled and console.options.interactive, .started = Io.Timestamp.now(io, .awake) };
        if (live.enabled and !console.options.interactive) std.debug.panic("live progress enabled on a stream that is not a terminal", .{});
        if (live.shown != null) std.debug.panic("a new progress line claims it was already drawn", .{});
        return live;
    }

    /// Redraws `what` at `done` of `total`, at most every 100 ms, and always when it finishes.
    pub fn update(self: *Live, what: []const u8, done: usize, total: usize) void {
        if (!self.enabled or total == 0) return;
        if (done > total) std.debug.panic("progress of '{s}' is {d} of {d}; the caller must count finished work only up to the total it passes", .{ what, done, total });
        const now = Io.Timestamp.now(self.io, .awake);
        const finished = done == total;
        if (self.shown) |shown| {
            if (!finished and shown.durationTo(now).toNanoseconds() < redraw_ns) return;
        }
        const elapsed = self.started.durationTo(now).toSeconds();
        if (elapsed < 0) std.debug.panic("progress of '{s}' started {d} seconds in the future; take started from the same .awake clock that update() reads", .{ what, -elapsed });
        const left = if (done == 0 or finished) 0 else @divTrunc(elapsed * @as(i64, @intCast(total - done)), @as(i64, @intCast(done)));
        const label = std.fmt.bufPrint(&self.label, "{s} {d}/{d}  {d}:{d:0>2}{s}", .{
            what,
            done,
            total,
            @divTrunc(elapsed, 60),
            @as(u64, @intCast(@mod(elapsed, 60))),
            if (left > 0) self.eta(left) else "",
        }) catch what;
        self.console.updateProgress(.{ .label = label, .completed = done, .total = total }, finished) catch return;
        self.shown = if (finished) null else now;
    }

    /// Resets the clock, so the next stage's estimate is its own.
    pub fn restart(self: *Live) void {
        const before = self.started;
        self.started = Io.Timestamp.now(self.io, .awake);
        if (before.durationTo(self.started).toNanoseconds() < 0) std.debug.panic("the monotonic clock ran backwards between progress stages; read both timestamps from the .awake clock", .{});
        self.shown = null;
        if (self.shown != null) std.debug.panic("restarting progress left it marked as drawn; restart() must clear shown", .{});
    }

    fn eta(self: *Live, seconds: i64) []const u8 {
        if (seconds <= 0) std.debug.panic("estimating {d} seconds left; only positive estimates are shown; update() must call eta() only when time is left", .{seconds});
        const text = std.fmt.bufPrint(&self.remaining, ", ~{d}:{d:0>2} left", .{ @divTrunc(seconds, 60), @as(u64, @intCast(@mod(seconds, 60))) }) catch return "";
        if (text.len > self.remaining.len) std.debug.panic("the estimate took {d} bytes of a {d}-byte buffer; enlarge the remaining buffer to fit the longest estimate", .{ text.len, self.remaining.len });
        return text;
    }
};
