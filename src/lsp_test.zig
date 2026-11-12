//! End-to-end test of `zanity lsp`: the diagnostics it publishes and the code actions it offers.
const std = @import("std");
const assert = @import("assert.zig");
const paths = @import("paths");
const golden = @import("golden_test.zig");
const expectOutput = golden.expectOutput;

const Io = std.Io;

/// One LSP message, framed as the protocol sends it.
fn frame(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    if (body.len == 0 or body[0] != '{') assert.panic("framing '{s}', which is not a JSON object; pass an LSP request object", .{body});
    const framed = try std.fmt.allocPrint(arena, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    if (!std.mem.endsWith(u8, framed, body)) assert.panic("the frame of '{s}' does not end with it; fix frame() to append the body after its header", .{body});
    return framed;
}

/// What `argv`, a zanity lsp command, writes to stdout given `messages`, after it exits cleanly.
fn serve(arena: std.mem.Allocator, io: Io, argv: []const []const u8, messages: []const []const u8) ![]const u8 {
    if (messages.len == 0) assert.panic("serving {s} with no messages; send at least initialize and exit", .{argv[0]});
    var input: std.ArrayList(u8) = .empty;
    for (messages) |m| try input.appendSlice(arena, try frame(arena, m));
    var environ = std.process.Environ.Map.init(arena);
    try environ.put("OTEL_SDK_DISABLED", "true");
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .environ_map = &environ });
    try child.stdin.?.writeStreamingAll(io, input.items);
    child.stdin.?.close(io);
    child.stdin = null;
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const output = try reader.interface.allocRemaining(arena, .unlimited);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    if (output.len == 0) assert.panic("{s} wrote nothing for {d} messages; initialize always has a reply", .{ argv[0], messages.len });
    return output;
}

test "zanity lsp publishes findings and offers their fixes and a false-positive flag as code actions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "checks.py", .data = "def f(x):\n    assert x is not None\n    assert isinstance(x, int)\n    return x\n" });
    const work = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const uri = try std.fmt.allocPrint(arena, "file://{s}/checks.py", .{work});
    const messages = [_][]const u8{
        try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"file://{s}\",\"capabilities\":{{}}}}}}", .{work}),
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeAction\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":1,\"character\":0}},\"end\":{{\"line\":1,\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}}}", .{uri}),
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    };
    const output = try serve(arena, io, &.{ zanity, "lsp" }, &messages);
    try expectOutput(output, &.{ "\"method\":\"textDocument/publishDiagnostics\"", "\"code\":\"redundant-null-check\"", "\"title\":\"zanity: fix redundant-null-check\"", "\"command\":\"zanity.flagFalsePositive\"", "\"id\":3,\"result\":null" }, &.{});
}

test "zanity lsp --production publishes the findings of every rule, as zanity check --production does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "checks.py", .data = "def f(x):\n    assert x is not None\n    return x\n" });
    // The nearest zanity.toml is read, so an empty one keeps the repository's own selection out.
    try tmp.dir.writeFile(io, .{ .sub_path = "zanity.toml", .data = "" });
    const work = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const messages = [_][]const u8{
        try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"file://{s}\",\"capabilities\":{{}}}}}}", .{work}),
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    };
    try expectOutput(try serve(arena, io, &.{ zanity, "lsp" }, &messages), &.{"\"method\":\"textDocument/publishDiagnostics\""}, &.{"\"code\":\"assertion-message\""});
    try expectOutput(try serve(arena, io, &.{ zanity, "lsp", "--production" }, &messages), &.{"\"code\":\"assertion-message\""}, &.{});
}
