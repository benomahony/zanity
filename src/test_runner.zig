//! The test runner `zig build test-integration` uses: Zig's own terminal runner, with each
//! test's wall time on its line and the slowest tests listed at the end, so a CI log shows
//! where the time went.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

/// The slowest tests listed after the run.
const slowest_shown = 10;

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const tests = builtin.test_functions;
    const elapsed = try std.heap.page_allocator.alloc(u64, tests.len);
    defer std.heap.page_allocator.free(elapsed);
    const order = try std.heap.page_allocator.alloc(usize, tests.len);
    defer std.heap.page_allocator.free(order);
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaks: usize = 0;
    for (tests, elapsed, 0..) |test_fn, *ms, i| {
        testing.allocator_instance = .init(std.heap.page_allocator, .{ .canary = 0xc3a701ba, .check_write_after_free = true });
        testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
        testing.log_level = .warn;
        testing.environ = init.environ;
        std.debug.print("{d}/{d} {s}...", .{ i + 1, tests.len, test_fn.name });
        const started = Io.Timestamp.now(io, .awake);
        const outcome = test_fn.func();
        const taken = started.untilNow(io, .awake).toMilliseconds();
        if (taken < 0) std.debug.panic("{s} took {d}ms; the awake clock never runs backwards, so main() must read it before and after the test", .{ test_fn.name, taken });
        ms.* = @intCast(taken);
        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() != 0) leaks += 1;
        if (outcome) |_| {
            passed += 1;
            std.debug.print("OK {d}ms\n", .{ms.*});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                std.debug.print("SKIP {d}ms\n", .{ms.*});
            },
            else => {
                failed += 1;
                std.debug.print("FAIL ({t}) {d}ms\n", .{ err, ms.* });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }
    if (passed + skipped + failed != tests.len) std.debug.panic("counted {d} outcomes for {d} tests; main() must count each test once", .{ passed + skipped + failed, tests.len });
    printSlowest(tests, elapsed, order);
    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ passed, skipped, failed });
    if (log_err_count != 0) std.debug.print("{d} errors were logged.\n", .{log_err_count});
    if (leaks != 0) std.debug.print("{d} tests leaked memory.\n", .{leaks});
    if (leaks != 0 or log_err_count != 0 or failed != 0) std.process.exit(1);
}

/// Lists the slowest tests, longest first, picking each in turn into the front of `order`.
fn printSlowest(tests: []const std.builtin.TestFn, elapsed: []const u64, order: []usize) void {
    if (tests.len != elapsed.len) std.debug.panic("{d} tests but {d} timings; main() times every test", .{ tests.len, elapsed.len });
    if (order.len != tests.len) std.debug.panic("{d} order slots for {d} tests; main() allocates one per test", .{ order.len, tests.len });
    for (order, 0..) |*slot, i| slot.* = i;
    std.debug.print("Slowest tests:\n", .{});
    for (0..@min(slowest_shown, order.len)) |rank| {
        var slowest = rank;
        for (order[rank..], rank..) |test_index, at| {
            if (elapsed[test_index] > elapsed[order[slowest]]) slowest = at;
        }
        std.mem.swap(usize, &order[rank], &order[slowest]);
        const shown = order[rank];
        std.debug.print("{d:>8}ms {s}\n", .{ elapsed[shown], tests[shown].name });
    }
}

/// Counts every error logged, so a test that logs one fails the run, as Zig's own runner does.
pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (format.len == 0) @compileError("an empty " ++ @tagName(level) ++ " message was logged in scope " ++ @tagName(scope) ++ "; say what happened");
    if (comptime std.mem.endsWith(u8, format, "\n")) @compileError("the log message '" ++ format ++ "' ends in a newline; log() adds one, so remove it");
    if (@backingInt(level) <= @backingInt(std.log.Level.err)) log_err_count +|= 1;
    if (@backingInt(level) <= @backingInt(testing.log_level)) std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
}
