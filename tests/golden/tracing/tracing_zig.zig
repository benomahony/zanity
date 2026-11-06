const std = @import("std");
const Tracer = @import("tracer.zig").Tracer;
const Span = @import("tracer.zig").Span;

fn charge(tracer: *Tracer, order: u64) u64 {
    const span = tracer.startSpan("charge");
    _ = span;
    return order;
}

fn refund(tracer: *Tracer, order: u64) u64 {
    const span = tracer.startSpan("refund");
    defer span.end();
    return order;
}

fn handedBack(tracer: *Tracer) Span {
    return tracer.startSpan("handedBack");
}

const Job = struct {
    span: ?Span = null,

    fn begin(job: *Job, tracer: *Tracer) void {
        job.span = tracer.startSpan("job");
    }
};

fn formatted(tracer: *Tracer, gpa: std.mem.Allocator, order: u64) !u64 {
    const span = tracer.startSpan(try std.fmt.allocPrint(gpa, "charge {d}", .{order}));
    defer span.end();
    return order;
}

fn firstOfTwo(tracer: *Tracer, order: u64) u64 {
    const first = tracer.startSpan("first");
    defer first.end();
    const second = tracer.startSpan("second");
    _ = second;
    return order;
}

fn otherEnded(tracer: *Tracer, timer: *Timer, order: u64) u64 {
    const span = tracer.startSpan("otherEnded");
    defer timer.end();
    _ = span;
    return order;
}

fn finished(tracer: *Tracer, order: u64) u64 {
    const span = tracer.startSpan("finished");
    finish(span);
    return order;
}

fn kept(job: *Job, tracer: *Tracer) void {
    const span = tracer.startSpan("kept");
    job.span = span;
}
