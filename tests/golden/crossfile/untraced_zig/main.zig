const httpz = @import("httpz");
const handlers = @import("handlers.zig");

pub fn main() !void {
    var server = try httpz.Server(void).init(.{}, {});
    var router = try server.router(.{});
    router.get("/orders", handlers.order, .{});
    router.post("/charges", handlers.charge, .{});
    try server.listen();
}
