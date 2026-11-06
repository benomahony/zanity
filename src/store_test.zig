//! Tests of the store against a real SQLite file: digests that stay stable, answers and source
//! analyses found again, and observations and runs kept as they should be.
const std = @import("std");
const assert = @import("assert.zig");
const sqlite = @import("sqlite.zig");
const store_module = @import("store.zig");
const Observation = store_module.Observation;
const Store = store_module.Store;
const digest = store_module.digest;

test "digests stay the same, so answers already in a store keep matching" {
    const unit = digest(&.{ "lang-a", "def f():\n    return 1\n" });
    try std.testing.expectEqualStrings("307f739720f5a61cf9920d8646b0f444", &unit);
    const question = digest(&.{"Does the function raise, assert, return or log an error message too vague to identify the problem, for example \"something went wrong\" or \"invalid input\" without saying which input, which value or what was expected?"});
    try std.testing.expectEqualStrings("11cea346266196eca9ef54648779f8fb", &question);
}

test "an answer kept in the store is found again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
    const store = try Store.initStore(std.heap.page_allocator, std.testing.io, &environ, 8 << 20);
    const unit = digest(&.{ "lang-a", "fn f() void {}" });
    const question = digest(&.{"Is it fine?"});
    try std.testing.expectEqual(@as(?f64, null), try store.cached("jev-1", question, unit));
    try store.keepAnswer(.{ .model = "jev-1", .question = question, .unit = unit, .language = "lang-a", .source = "fn f() void {}", .probability = 0.25 });
    try std.testing.expectEqual(@as(?f64, 0.25), try store.cached("jev-1", question, unit));
    try std.testing.expectEqual(@as(?f64, null), try store.cached("jev-2", question, unit));
}

test "a source analysis is queryable JSON and records cache hits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
    const store = try Store.initStore(std.heap.page_allocator, std.testing.io, &environ, 8 << 20);
    const key = digest(&.{"analysis"});
    const source = digest(&.{"source"});
    try store.keepAnalysis(.{ .key = key, .source = source, .path = "src/a.py", .language = "lang-a", .result = "{\"findings\":[{\"rule\":\"unbounded-loop\"}]}" });
    var buffer: [1024]u8 = undefined;
    const result = (try store.cachedAnalysis(&buffer, key, source)).?;
    try std.testing.expectEqualStrings("{\"findings\":[{\"rule\":\"unbounded-loop\"}]}", result);
    try std.testing.expectEqual(null, try store.cachedAnalysis(&buffer, key, digest(&.{"changed"})));
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT json_array_length(result, '$.findings') FROM source_analyses"));
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT hits FROM source_analyses"));
}

/// The first column of the first row `sql` returns, for reading back what a test kept.
fn scalar(db: *sqlite.sqlite3, comptime sql: []const u8) !f64 {
    if (!std.mem.startsWith(u8, sql, "SELECT ")) assert.panic("'{s}' is not a query; scalar() only reads back what a test kept", .{sql});
    const stmt = try sqlite.prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_reset(stmt);
    if (sqlite.sqlite3_step(stmt) != sqlite.row) return sqlite.captureDatabaseFailure(db);
    const value = sqlite.sqlite3_column_double(stmt, 0);
    if (std.math.isNan(value)) assert.panic("'{s}' read back NaN; SQLite reads NULL as 0, so check the column holds numbers", .{sql});
    return value;
}

test "every observation is kept, the latest per place, and each run adds a row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
    const store = try Store.initStore(std.heap.page_allocator, std.testing.io, &environ, 8 << 20);
    const seen: Observation = .{ .path = "a.py", .rule = "hollow-test", .unit = digest(&.{"u"}), .unit_name = "test_a", .line = 3, .language = "lang-a", .model = "jev-1", .question = digest(&.{"q"}), .probability = 0.4, .threshold = 0.8, .fired = false };
    try store.observe(seen);
    var again = seen;
    again.probability = 0.9;
    again.fired = true;
    try store.observe(again);
    try store.keepRun(.{ .path = dir, .units = 2, .asked = 1, .cached = 1, .input_tokens = 300, .output_tokens = 30 });
    try store.keepRun(.{ .path = dir, .units = 2, .asked = 0, .cached = 2, .input_tokens = 0, .output_tokens = 0 });
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT count(*) FROM observations"));
    try std.testing.expectEqual(@as(f64, 0.9), try scalar(store.db, "SELECT probability FROM observations WHERE fired = 1"));
    try std.testing.expectEqual(@as(f64, 300), try scalar(store.db, "SELECT sum(input_tokens) FROM runs"));
}
