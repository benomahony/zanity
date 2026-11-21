const std = @import("std");
const httpz = @import("httpz");
const tracer = @import("tracer.zig");

pub fn order(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.body = "order";
}

pub fn charge(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    const span = tracer.startSpan("charge");
    defer span.end();
    res.body = "charged";
}

pub fn price(map: std.StringHashMap(u32)) ?u32 {
    return map.get("small");
}
