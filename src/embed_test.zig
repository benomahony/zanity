const std = @import("std");
const assert = @import("assert.zig");
const golden = @import("golden_test.zig");
const expectOutput = golden.expectOutput;
const exited = golden.exited;
const paths = @import("paths");

const Io = std.Io;

const orders =
    \\def fetch_order(order_id):
    \\    return order_id
    \\
    \\
    \\def order_lines(order):
    \\    return order.lines
    \\
    \\
    \\def order_lines_fetch(order):
    \\    """Send a charge to a card."""
    \\    lines = order.lines
    \\    fetched = lines.fetch()
    \\    return fetched
    \\
    \\
    \\def charge_card(card):
    \\    return card
    \\
    \\
    \\def send_invoice(invoice):
    \\    """Charge the customer's card for the invoice and mark it paid."""
    \\    total = invoice.total
    \\    card = invoice.card
    \\    card.charge(total)
    \\    invoice.paid = True
    \\    return invoice
    \\
;

const purchases =
    \\def retrieve_purchase(purchase_id):
    \\    return purchase_id
    \\
    \\
    \\def bill_card(card):
    \\    return card
    \\
    \\
    \\def charge_invoice(invoice):
    \\    total = invoice.total
    \\    card = invoice.card
    \\    card.charge(total)
    \\    invoice.paid = True
    \\    return invoice
    \\
;

const EmbedRun = struct {
    tmp: std.testing.TmpDir,
    child: std.process.Child,
    env: std.process.Environ.Map,
    work: []const u8,
    zanity: []const u8,

    fn initEmbedRun(arena: std.mem.Allocator, io: Io, reachable: bool) !EmbedRun {
        var tmp = std.testing.tmpDir(.{});
        const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        const dir = try Io.Dir.cwd().realPathFileAlloc(io, work, arena);
        var env = std.process.Environ.Map.init(arena);
        try env.put("MOCK_EMBED_LOG", try std.fs.path.join(arena, &.{ dir, "requests.log" }));
        try env.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
        var child = try std.process.spawn(io, .{ .argv = &.{ "python3", "tests/embed/mock_embeddings.py" }, .stdin = .pipe, .stdout = .pipe, .environ_map = &env });
        var buffer: [64]u8 = undefined;
        var reader = child.stdout.?.reader(io, &buffer);
        const port = try reader.interface.takeDelimiterExclusive('\n');
        if (port.len == 0 or port.len > 5) assert.panic("the mock embeddings server printed '{s}' instead of a port; check tests/embed/mock_embeddings.py prints its port first", .{port});
        const url = if (reachable) try std.fmt.allocPrint(arena, "http://127.0.0.1:{s}", .{port}) else "http://127.0.0.1:9";
        try tmp.dir.writeFile(io, .{ .sub_path = "zanity.toml", .data = try std.fmt.allocPrint(arena, "[semantic]\nurl = \"{s}\"\n\n[contexts.billing]\ninclude = [\"src/billing/**\"]\n\n[contexts.core]\ninclude = [\"src/core/**\"]\n", .{url}) });
        try tmp.dir.createDirPath(io, "src/core");
        try tmp.dir.createDirPath(io, "src/billing");
        try tmp.dir.writeFile(io, .{ .sub_path = "src/core/orders.py", .data = orders });
        try tmp.dir.writeFile(io, .{ .sub_path = "src/billing/purchases.py", .data = purchases });
        const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
        if (!std.fs.path.isAbsolute(zanity)) assert.panic("zanity resolved to the relative path '{s}'; the project runs it from another directory", .{zanity});
        return .{ .tmp = tmp, .child = child, .env = env, .work = work, .zanity = zanity };
    }

    fn run(self: *EmbedRun, arena: std.mem.Allocator, io: Io, argv: []const []const u8) !std.process.RunResult {
        if (argv.len == 0) assert.panic("running zanity with no command", .{});
        if (self.work.len == 0) assert.panic("running zanity in no directory; initEmbedRun() sets it", .{});
        const full = try std.mem.concat(arena, []const u8, &.{ &.{self.zanity}, argv });
        return exited(try std.process.run(arena, io, .{ .argv = full, .cwd = .{ .path = self.work }, .environ_map = &self.env }), argv[0]);
    }
};

test "--semantic reports names that mean the same, names in the wrong context and bodies doing one job, then reuses every vector" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try EmbedRun.initEmbedRun(arena, io, true);
    defer project.tmp.cleanup();
    defer project.child.kill(io);
    const first = try project.run(arena, io, &.{ "check", ".", "--semantic", "--plain" });
    try expectOutput(first.stdout, &.{ "'retrieve_purchase' and 'fetch_order' name the same idea in unrelated words", "'retrieve_purchase' reads like core vocabulary but lives in billing", "'charge_card' reads like billing vocabulary but lives in core", "'charge_invoice' does what 'send_invoice' in src/core/orders.py:20 does", "'order_lines_fetch': its docstring disagrees with its body and name" }, &.{});
    try expectOutput(first.stderr, &.{"0 from the store, 18 embedded by google/embeddinggemma-2"}, &.{});
    const second = try project.run(arena, io, &.{ "check", ".", "--semantic", "--plain" });
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
    try expectOutput(second.stderr, &.{"18 from the store, 0 embedded"}, &.{});
}

test "zanity search lists the function closest to the query as path:line:col: text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try EmbedRun.initEmbedRun(arena, io, true);
    defer project.tmp.cleanup();
    defer project.child.kill(io);
    const found = try project.run(arena, io, &.{ "search", "charge", "the", "card", "--limit", "1" });
    try std.testing.expectEqualStrings("src/core/orders.py:20:5: def send_invoice(invoice):\n", found.stdout);
    const names = try project.run(arena, io, &.{ "search", "retrieve", "order", "--names", "--json" });
    try expectOutput(names.stdout, &.{"\"text\":\"function retrieve_purchase\""}, &.{});
}

test "--semantic with no server listening says how to start one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try EmbedRun.initEmbedRun(arena, io, false);
    defer project.tmp.cleanup();
    defer project.child.kill(io);
    const failed = try project.run(arena, io, &.{ "check", ".", "--semantic", "--plain" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 74 }, failed.term);
    try expectOutput(failed.stderr, &.{ "ConnectionFailed", "Start an OpenAI-compatible embeddings server" }, &.{});
}
